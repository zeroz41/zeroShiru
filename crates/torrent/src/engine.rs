//! librqbit-backed TorrentEngine (migration phase 8). The engine choice is
//! deliberately hidden behind the trait — nothing outside this module may name
//! librqbit types (migration report section 13).

use crate::gateway::Gateway;
use crate::{
    TorrentEngine, TorrentError, TorrentFileInfo, TorrentMetadata, TorrentState, TorrentStatus,
};
use async_trait::async_trait;
use librqbit::api::TorrentIdOrHash;
use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent, Session};
use shiru_domain::{parse_hash, PlaybackSource};
use std::path::PathBuf;
use std::sync::Arc;

pub struct RqbitEngine {
    session: Arc<Session>,
    gateway: Gateway,
}

impl RqbitEngine {
    /// Starts the engine with its download/cache directory and the loopback media
    /// gateway (127.0.0.1, ephemeral port, random session token — media only).
    pub async fn new(download_dir: PathBuf) -> Result<Self, TorrentError> {
        let session = Session::new(download_dir)
            .await
            .map_err(|error| TorrentError::Engine(format!("session: {error:#}")))?;
        Self::with_session(session).await
    }

    /// Starts the engine configured from the application's torrent settings.
    pub async fn with_settings(
        download_dir: PathBuf,
        settings: &crate::SessionSettings,
    ) -> Result<Self, TorrentError> {
        use librqbit::limits::LimitsConfig;
        use librqbit::{DhtSessionConfig, ListenerOptions, SessionOptions};
        let bps = |limit: u64| u32::try_from(limit).ok().and_then(std::num::NonZeroU32::new);
        let options = SessionOptions {
            dht: settings.dht.then(|| DhtSessionConfig {
                port: (settings.dht_port > 0).then_some(settings.dht_port),
                ..Default::default()
            }),
            fastresume: true,
            listen: Some(ListenerOptions {
                listen_addr: (
                    std::net::Ipv4Addr::UNSPECIFIED,
                    settings.torrent_port, // 0 = ephemeral
                )
                    .into(),
                enable_upnp_port_forwarding: true,
                ..Default::default()
            }),
            ratelimits: LimitsConfig {
                download_bps: bps(settings.download_limit),
                upload_bps: bps(settings.upload_limit),
            },
            trackers: settings
                .trackers
                .iter()
                .filter_map(|tracker| tracker.parse().ok())
                .collect(),
            peer_limit: settings.max_conns.map(|conns| conns as usize),
            ..Default::default()
        };
        let session = Session::new_with_opts(download_dir, options)
            .await
            .map_err(|error| TorrentError::Engine(format!("session: {error:#}")))?;
        Self::with_session(session).await
    }

    async fn with_session(session: Arc<Session>) -> Result<Self, TorrentError> {
        let gateway = Gateway::spawn(session.clone())
            .await
            .map_err(|error| TorrentError::Engine(format!("gateway: {error:#}")))?;
        Ok(RqbitEngine { session, gateway })
    }

    /// Applies transfer speed limits live (0 = unlimited).
    pub fn set_rate_limits(&self, download: u64, upload: u64) {
        let bps = |limit: u64| u32::try_from(limit).ok().and_then(std::num::NonZeroU32::new);
        self.session.ratelimits.set_download_bps(bps(download));
        self.session.ratelimits.set_upload_bps(bps(upload));
    }

    pub(crate) fn rqbit_session(&self) -> &Arc<Session> {
        &self.session
    }

    pub(crate) fn media_gateway(&self) -> &Gateway {
        &self.gateway
    }

    fn handle(&self, info_hash: &str) -> Result<Arc<ManagedTorrent>, TorrentError> {
        let id = TorrentIdOrHash::parse(info_hash)
            .map_err(|_| TorrentError::InvalidId(info_hash.to_string()))?;
        self.session
            .get(id)
            .ok_or_else(|| TorrentError::NotFound(info_hash.to_string()))
    }
}

#[async_trait]
impl TorrentEngine for RqbitEngine {
    async fn add(&self, id: &str) -> Result<String, TorrentError> {
        // magnet and .torrent URLs pass through; a bare hash becomes a magnet
        let add = if id.starts_with("magnet:") || id.starts_with("http://") || id.starts_with("https://") {
            AddTorrent::from_url(id.to_string())
        } else if let Some(hash) = parse_hash(id) {
            AddTorrent::from_url(format!("magnet:?xt=urn:btih:{hash}"))
        } else {
            return Err(TorrentError::InvalidId(id.to_string()));
        };
        let response = self
            .session
            .add_torrent(
                add,
                Some(AddTorrentOptions { overwrite: true, ..Default::default() }),
            )
            .await
            .map_err(|error| TorrentError::Engine(format!("add: {error:#}")))?;
        let handle = response
            .into_handle()
            .ok_or_else(|| TorrentError::Engine("torrent was not added".into()))?;
        Ok(handle.info_hash().as_string())
    }

    async fn metadata(&self, info_hash: &str) -> Result<TorrentMetadata, TorrentError> {
        let handle = self.handle(info_hash)?;
        handle
            .wait_until_initialized()
            .await
            .map_err(|error| TorrentError::Engine(format!("initialize: {error:#}")))?;
        let files = handle
            .with_metadata(|metadata| {
                metadata
                    .info
                    .iter_file_details()
                    .enumerate()
                    .map(|(index, details)| TorrentFileInfo {
                        index: index as u32,
                        path: format!("/{}", details.filename.to_vec().join("/")),
                        size: details.len,
                    })
                    .collect::<Vec<_>>()
            })
            .map_err(|error| TorrentError::Engine(format!("metadata: {error:#}")))?;
        Ok(TorrentMetadata {
            info_hash: handle.info_hash().as_string(),
            name: handle.name().unwrap_or_default(),
            files,
        })
    }

    async fn select_files(&self, info_hash: &str, indexes: &[u32]) -> Result<(), TorrentError> {
        let handle = self.handle(info_hash)?;
        let indexes = indexes.iter().map(|index| *index as usize).collect();
        self.session
            .update_only_files(&handle, &indexes)
            .await
            .map_err(|error| TorrentError::Engine(format!("select: {error:#}")))
    }

    async fn playback_source(&self, info_hash: &str, index: u32) -> Result<PlaybackSource, TorrentError> {
        let handle = self.handle(info_hash)?;
        let hash = handle.info_hash().as_string();
        Ok(PlaybackSource::Torrent { url: self.gateway.url_for(&hash, index), info_hash: hash })
    }

    async fn pause(&self, info_hash: &str) -> Result<(), TorrentError> {
        let handle = self.handle(info_hash)?;
        self.session
            .pause(&handle)
            .await
            .map_err(|error| TorrentError::Engine(format!("pause: {error:#}")))
    }

    async fn resume(&self, info_hash: &str) -> Result<(), TorrentError> {
        let handle = self.handle(info_hash)?;
        self.session
            .unpause(&handle)
            .await
            .map_err(|error| TorrentError::Engine(format!("resume: {error:#}")))
    }

    async fn remove(&self, info_hash: &str) -> Result<(), TorrentError> {
        let id = TorrentIdOrHash::parse(info_hash)
            .map_err(|_| TorrentError::InvalidId(info_hash.to_string()))?;
        // data stays on disk: the torrent cache has its own cleanup policy
        // TODO(cache): port the JS cache-size management before desktop parity
        self.session
            .delete(id, false)
            .await
            .map_err(|error| TorrentError::Engine(format!("remove: {error:#}")))
    }

    async fn status(&self, info_hash: &str) -> Result<TorrentStatus, TorrentError> {
        let handle = self.handle(info_hash)?;
        let stats = handle.stats();
        let progress = if stats.total_bytes == 0 {
            0.0
        } else {
            stats.progress_bytes as f32 / stats.total_bytes as f32
        };
        use librqbit::TorrentStatsState as S;
        let state = match stats.state {
            S::Initializing { .. } => TorrentState::Fetching,
            S::Live if stats.finished => TorrentState::Seeding,
            S::Live => TorrentState::Downloading,
            S::Paused => TorrentState::Paused,
            S::Error => TorrentState::Errored,
        };
        let live = stats.live.as_ref();
        let mbps_to_bytes = |mbps: f64| (mbps * 125_000.0) as u64;
        Ok(TorrentStatus {
            info_hash: handle.info_hash().as_string(),
            progress,
            peers: live.map(|l| l.snapshot.peer_stats.live).unwrap_or(0),
            download_rate: live.map(|l| mbps_to_bytes(l.download_speed.mbps)).unwrap_or(0),
            upload_rate: live.map(|l| mbps_to_bytes(l.upload_speed.mbps)).unwrap_or(0),
            state,
        })
    }
}
