//! The torrent session the application talks to: it owns which torrents exist,
//! what role each plays (current / staging / seeding / completed), persists that
//! registry itself, and pushes state at the UI. The frontend renders; it never
//! bookkeeps. Field names here are the wire protocol with the Svelte stores.
//! `fileHash` is sha1(`${infoHash}:${name}:${size}`) — the watch-progress key
//! shared with debrid playback (common/modules/debrid/identity.js).

use crate::gateway::Gateway;
use crate::{RqbitEngine, TorrentEngine, TorrentError, TorrentMetadata};
use librqbit::api::TorrentIdOrHash;
use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent, Session};
use serde::{Deserialize, Serialize};
use shiru_domain::{parse_hash, to_magnet};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};
use tokio::sync::Mutex;

/// Torrent settings as the renderer sends them. The dht/utp/pex booleans arrive
/// as "enabled" flags.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct SessionSettings {
    pub dht: bool,
    #[serde(rename = "torrentUTP")]
    pub torrent_utp: bool,
    #[serde(rename = "torrentPeX")]
    pub torrent_pex: bool,
    #[serde(rename = "maxConns")]
    pub max_conns: Option<u32>,
    #[serde(rename = "downloadLimit")]
    pub download_limit: u64,
    #[serde(rename = "uploadLimit")]
    pub upload_limit: u64,
    #[serde(rename = "torrentPort")]
    pub torrent_port: u16,
    #[serde(rename = "dhtPort")]
    pub dht_port: u16,
    #[serde(rename = "torrentPersist")]
    pub torrent_persist: bool,
    #[serde(rename = "torrentStreamedDownload")]
    pub torrent_streamed_download: bool,
    #[serde(rename = "torrentPathNew")]
    pub torrent_path_new: Option<String>,
    #[serde(rename = "playerPath")]
    pub player_path: Option<String>,
    #[serde(rename = "seedingLimit")]
    pub seeding_limit: Option<u32>,
    #[serde(rename = "disableStartupTorrent")]
    pub disable_startup_torrent: bool,
    pub trackers: Vec<String>,
}

/// One torrent as the stats snapshot reports it.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ActivityTorrent {
    pub info_hash: String,
    pub name: String,
    pub size: u64,
    pub progress: f64,
    pub incomplete: bool,
    pub num_seeders: u32,
    pub total_seeders: u32,
    pub num_leechers: u32,
    pub total_leechers: u32,
    pub num_peers: u32,
    pub download_speed: u64,
    pub upload_speed: u64,
    #[serde(rename = "magnetURI")]
    pub magnet_uri: String,
    pub date: String,
    pub eta: u64,
    pub ratio: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompletedTorrent {
    pub info_hash: String,
    pub name: String,
    pub size: u64,
    pub progress: f64,
    pub incomplete: bool,
    #[serde(rename = "magnetURI")]
    pub magnet_uri: String,
    pub date: String,
}

/// The whole session state, pushed after every mutation and on a slow tick.
/// The UI's four torrent stores are projections of this one object.
#[derive(Debug, Clone, Serialize, Default, PartialEq)]
pub struct Snapshot {
    pub current: Option<ActivityTorrent>,
    pub staging: Vec<ActivityTorrent>,
    pub seeding: Vec<ActivityTorrent>,
    pub completed: Vec<CompletedTorrent>,
}

#[derive(Debug, Clone, Serialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CurrentStats {
    pub num_peers: u32,
    pub upload_speed: u64,
    pub download_speed: u64,
}

/// A playable file as the renderer's `files` store expects it — the same shape
/// debrid's toPlayerFile produces, so both lanes share players and watch keys.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PlayerFile {
    #[serde(rename = "infoHash")]
    pub info_hash: String,
    #[serde(rename = "fileHash")]
    pub file_hash: String,
    pub torrent_name: String,
    pub name: String,
    #[serde(rename = "type")]
    pub mime: String,
    pub size: u64,
    pub path: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ScrapeEntry {
    pub hash: String,
    pub complete: u32,
    pub downloaded: u32,
    pub incomplete: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadedTorrent {
    pub info_hash: String,
    pub name: String,
    pub magnet: String,
}

/// Everything the session pushes at the frontend.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Stats(Snapshot),
    CurrentStats(CurrentStats),
    /// Download progress of the file being played, 0..1.
    Progress(f64),
    Files(Vec<PlayerFile>),
    /// What just became the playing torrent (None when playback was unloaded).
    Loaded(Option<LoadedTorrent>),
    Notify { level: String, message: String },
    ExternalReady,
    ExternalWatched(u64),
}

impl SessionEvent {
    /// (bridge channel, payload) — the names the injected bridge script fans out on.
    pub fn wire(&self) -> (&'static str, serde_json::Value) {
        use serde_json::json;
        match self {
            SessionEvent::Stats(s) => ("stats", serde_json::to_value(s).unwrap_or_default()),
            SessionEvent::CurrentStats(s) => ("currentStats", serde_json::to_value(s).unwrap_or_default()),
            SessionEvent::Progress(p) => ("progress", json!(p)),
            SessionEvent::Files(f) => ("files", serde_json::to_value(f).unwrap_or_default()),
            SessionEvent::Loaded(Some(l)) => ("loaded", serde_json::to_value(l).unwrap_or_default()),
            SessionEvent::Loaded(None) => ("loaded", json!(null)),
            SessionEvent::Notify { level, message } => ("notify", json!({ "type": level, "message": message })),
            SessionEvent::ExternalReady => ("externalReady", json!(null)),
            SessionEvent::ExternalWatched(s) => ("externalWatched", json!(s)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Current,
    Staging,
    Seeding,
    Completed,
}

/// A registry record — survives restarts via the sidecar file, so names and
/// sizes are known without touching the network.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tracked {
    pub name: String,
    pub size: u64,
    pub magnet: String,
    pub date: String,
    pub role: Role,
    pub incomplete: bool,
}

struct SessionState {
    settings: SessionSettings,
    tracked: HashMap<String, Tracked>,
    /// info hash + file index of what the player is streaming.
    playing: Option<(String, u32)>,
}

pub struct TorrentSession {
    engine: Arc<RqbitEngine>,
    state: Mutex<SessionState>,
    /// Command handlers run concurrently; registry writes must not truncate each other.
    registry_write: Mutex<()>,
    events: UnboundedSender<SessionEvent>,
    registry_path: PathBuf,
    http: reqwest::Client,
}

impl TorrentSession {
    /// Starts the engine, restores the previous session from the sidecar, and
    /// returns the session plus its event stream. `dir` is the fallback download
    /// dir when settings name no torrent path.
    pub async fn start(
        dir: PathBuf,
        settings: SessionSettings,
    ) -> Result<(Arc<Self>, UnboundedReceiver<SessionEvent>), TorrentError> {
        let download_dir = settings
            .torrent_path_new
            .clone()
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .unwrap_or(dir);
        let _ = tokio::fs::create_dir_all(&download_dir).await;
        let engine = Arc::new(RqbitEngine::with_settings(download_dir.clone(), &settings).await?);
        let (events, receiver) = unbounded_channel();
        let session = Arc::new(TorrentSession {
            engine,
            registry_path: download_dir.join("shiru-session.json"),
            state: Mutex::new(SessionState { settings, tracked: HashMap::new(), playing: None }),
            registry_write: Mutex::new(()),
            events,
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(8))
                .build()
                .map_err(|error| TorrentError::Engine(format!("http: {error}")))?,
        });
        session.load_registry().await;
        let restorer = session.clone();
        tokio::spawn(async move { restorer.restore().await });
        session.clone().spawn_loops();
        Ok((session, receiver))
    }

    pub fn engine(&self) -> Arc<RqbitEngine> {
        self.engine.clone()
    }

    fn emit(&self, event: SessionEvent) {
        let _ = self.events.send(event);
    }

    fn notify(&self, level: &str, message: impl Into<String>) {
        // into the log as well as onto the screen: a toast the user dismissed used to be
        // the only record a torrent operation failed at all
        let message = message.into();
        match level {
            "error" => tracing::warn!(target: "torrent", "{message}"),
            _ => tracing::info!(target: "torrent", "{message}"),
        }
        return self.notify_inner(level, message);
    }

    fn notify_inner(&self, level: &str, message: String) {
        self.emit(SessionEvent::Notify { level: level.into(), message: message.into() });
    }

    // ---- registry sidecar ------------------------------------------------------

    async fn load_registry(&self) {
        let Ok(bytes) = tokio::fs::read(&self.registry_path).await else { return };
        if let Ok(tracked) = serde_json::from_slice::<HashMap<String, Tracked>>(&bytes) {
            self.state.lock().await.tracked = tracked;
        }
    }

    async fn save_registry(&self) {
        let _writer = self.registry_write.lock().await;
        let tracked = self.state.lock().await.tracked.clone();
        if let Ok(json) = serde_json::to_vec_pretty(&tracked) {
            let _ = tokio::fs::write(&self.registry_path, json).await;
        }
    }

    /// Re-adopt what the previous run tracked: background torrents rejoin the
    /// swarm, the playing torrent reloads unless startup resume is disabled.
    async fn restore(self: &Arc<Self>) {
        let (records, disable_startup, persist) = {
            let state = self.state.lock().await;
            (
                state.tracked.clone(),
                state.settings.disable_startup_torrent,
                state.settings.torrent_persist,
            )
        };
        for (hash, tracked) in &records {
            match tracked.role {
                Role::Staging | Role::Seeding => {
                    if self.add_id(&tracked.magnet, false).await.is_err() {
                        self.state.lock().await.tracked.remove(hash);
                    }
                }
                Role::Current => {
                    if disable_startup {
                        let mut state = self.state.lock().await;
                        if let Some(entry) = state.tracked.get_mut(hash) {
                            if entry.incomplete && !persist {
                                state.tracked.remove(hash);
                            } else {
                                entry.role = Role::Completed;
                            }
                        }
                    } else {
                        self.stream(tracked.magnet.clone(), false).await;
                    }
                }
                Role::Completed => {}
            }
        }
        self.emit_snapshot().await;
        self.save_registry().await;
    }

    // ---- op surface --------------------------------------------------------------

    /// Load a torrent for playback. Accepts magnets, bare hashes, .torrent URLs,
    /// or base64 .torrent bytes.
    pub async fn stream(self: &Arc<Self>, id: String, base64: bool) {
        self.demote_current().await;
        let added = if base64 {
            match base64_decode(&id) {
                Some(bytes) => self.add_bytes(bytes).await,
                None => Err(TorrentError::InvalidId("unreadable .torrent data".into())),
            }
        } else {
            self.add_id(&id, false).await
        };
        let hash = match added {
            Ok(hash) => hash,
            Err(error) => return self.notify("error", format!("Failed to load torrent: {error}")),
        };
        match self.track(&hash, Role::Current).await {
            Ok(tracked) => {
                tracing::info!(target: "torrent", %hash, name = %tracked.name, "streaming");
                self.emit(SessionEvent::Loaded(Some(LoadedTorrent {
                    info_hash: hash.clone(),
                    name: tracked.name.clone(),
                    magnet: tracked.magnet.clone(),
                })));
                match self.player_files(&hash).await {
                    Ok(files) => self.emit(SessionEvent::Files(files)),
                    Err(error) => self.notify("error", format!("Failed to read torrent files: {error}")),
                }
            }
            Err(error) => self.notify("error", format!("Failed to load torrent metadata: {error}")),
        }
        self.emit_snapshot().await;
        self.save_registry().await;
    }

    /// Pre-download in the background without touching playback.
    pub async fn stage(self: &Arc<Self>, id: String, base64: bool) {
        let added = if base64 {
            match base64_decode(&id) {
                Some(bytes) => self.add_bytes(bytes).await,
                None => Err(TorrentError::InvalidId("unreadable .torrent data".into())),
            }
        } else {
            self.add_id(&id, false).await
        };
        match added {
            Ok(hash) => {
                if let Err(error) = self.track(&hash, Role::Staging).await {
                    return self.notify("error", format!("Failed to stage torrent: {error}"));
                }
                tracing::info!(target: "torrent", %hash, "staged for pre-download");
                self.emit_snapshot().await;
                self.save_registry().await;
            }
            Err(error) => self.notify("error", format!("Failed to stage torrent: {error}")),
        }
    }

    /// Stop playback. Finished torrents move to seeding; unfinished ones are
    /// dropped (files kept only with persist on).
    pub async fn unload(self: &Arc<Self>) {
        if let Some(hash) = self.current_hash().await {
            tracing::info!(target: "torrent", %hash, "unloading playback");
            self.demote_hash(&hash).await;
        }
        self.state.lock().await.playing = None;
        self.emit(SessionEvent::Loaded(None));
        self.emit_snapshot().await;
        self.save_registry().await;
    }

    /// Forget a torrent completely, data included.
    pub async fn untrack(self: &Arc<Self>, hash: String) {
        tracing::info!(target: "torrent", %hash, "forgetting torrent and its data");
        self.delete(&hash, true).await;
        {
            let mut state = self.state.lock().await;
            state.tracked.remove(&hash);
            if state.playing.as_ref().map(|(playing, _)| playing == &hash).unwrap_or(false) {
                state.playing = None;
            }
        }
        self.emit_snapshot().await;
        self.save_registry().await;
    }

    /// Stop seeding but keep the files and the record.
    pub async fn complete(self: &Arc<Self>, hash: String) {
        tracing::info!(target: "torrent", %hash, "seeding stopped, files kept");
        self.delete(&hash, false).await;
        {
            let mut state = self.state.lock().await;
            if let Some(tracked) = state.tracked.get_mut(&hash) {
                tracked.role = Role::Completed;
            }
        }
        self.emit_snapshot().await;
        self.save_registry().await;
    }

    /// Re-emit the registry — the engine re-verifies data on add, so a rescan is
    /// just a state refresh.
    pub async fn rescan(self: &Arc<Self>) {
        self.emit_snapshot().await;
    }

    /// Focus the engine on the file the player opened. A debrid file clears
    /// torrent playback so its peers/speeds stop being reported.
    pub async fn set_playback(self: &Arc<Self>, current: serde_json::Value, external: bool) {
        let debrid = current.get("debrid").and_then(|value| value.as_bool()).unwrap_or(false);
        if debrid {
            self.state.lock().await.playing = None;
            if external {
                self.emit(SessionEvent::ExternalReady);
            }
            return;
        }
        let (Some(hash), Some(path)) = (
            current.get("infoHash").and_then(|value| value.as_str()),
            current.get("path").and_then(|value| value.as_str()),
        ) else {
            return;
        };
        let Ok(metadata) = self.engine.metadata(hash).await else { return };
        let Some(file) = metadata
            .files
            .iter()
            .find(|file| file.path.trim_start_matches('/') == path.trim_start_matches('/'))
        else {
            return self.notify("error", format!("File not found in torrent: {path}"));
        };
        let streamed = self.state.lock().await.settings.torrent_streamed_download;
        if let Err(error) = select_playback_files(self.engine.as_ref(), hash, &metadata, file.index, streamed).await {
            return self.notify("error", format!("Failed to select torrent files: {error}"));
        }
        self.state.lock().await.playing = Some((hash.to_string(), file.index));
        if external {
            self.emit(SessionEvent::ExternalReady);
        }
    }

    /// Hand the stream URL to the configured external player and report watch
    /// time when it exits.
    pub async fn launch_external(self: &Arc<Self>, current: serde_json::Value) {
        let Some(url) = current.get("url").and_then(|value| value.as_str()).map(String::from) else {
            return self.notify("error", "External playback failed: no stream URL");
        };
        let player = self.state.lock().await.settings.player_path.clone().unwrap_or_default();
        if player.is_empty() {
            return self.notify("error", "External playback failed: no player configured");
        }
        let session = self.clone();
        tokio::spawn(async move {
            let started = std::time::Instant::now();
            match tokio::process::Command::new(&player).arg(&url).spawn() {
                Ok(mut child) => {
                    session.emit(SessionEvent::ExternalReady);
                    let _ = child.wait().await;
                    session.emit(SessionEvent::ExternalWatched(started.elapsed().as_secs()));
                }
                Err(error) => session.notify("error", format!("Failed to launch external player: {error}")),
            }
        });
    }

    /// Apply what can change live (rate limits and the policy fields the session
    /// reads on demand); the rest needs a restart.
    pub async fn update_settings(self: &Arc<Self>, settings: SessionSettings) {
        self.engine.set_rate_limits(settings.download_limit, settings.upload_limit);
        let restart_needed = {
            let mut state = self.state.lock().await;
            let old = &state.settings;
            let restart = old.torrent_port != settings.torrent_port
                || old.dht != settings.dht
                || old.torrent_path_new != settings.torrent_path_new
                || old.trackers != settings.trackers;
            state.settings = settings;
            restart
        };
        if restart_needed {
            self.notify("info", "Some torrent settings apply after the app restarts");
        }
    }

    /// Seeder/leecher counts from the configured HTTP(S) trackers.
    pub async fn scrape(self: &Arc<Self>, hashes: Vec<String>) -> Vec<ScrapeEntry> {
        let trackers = self.state.lock().await.settings.trackers.clone();
        let mut totals: HashMap<String, ScrapeEntry> = hashes
            .iter()
            .filter_map(|hash| parse_hash(hash))
            .map(|hash| {
                (hash.clone(), ScrapeEntry { hash, complete: 0, downloaded: 0, incomplete: 0 })
            })
            .collect();
        let valid: Vec<String> = totals.keys().cloned().collect();
        if valid.is_empty() {
            return Vec::new();
        }
        for tracker in trackers {
            let Some(scrape_url) = scrape_url(&tracker) else { continue };
            let query: String = valid
                .iter()
                .filter_map(|hash| hex::decode(hash).ok())
                .map(|bytes| format!("info_hash={}", percent_bytes(&bytes)))
                .collect::<Vec<_>>()
                .join("&");
            let url = format!("{scrape_url}?{query}");
            let Ok(response) = self.http.get(&url).send().await else { continue };
            let Ok(body) = response.bytes().await else { continue };
            for (hash, entry) in parse_scrape_response(&body) {
                if let Some(total) = totals.get_mut(&hash) {
                    // report the best-informed tracker
                    if entry.complete >= total.complete {
                        *total = entry;
                    }
                }
            }
        }
        valid.into_iter().filter_map(|hash| totals.remove(&hash)).collect()
    }

    // ---- internals ---------------------------------------------------------------

    async fn current_hash(&self) -> Option<String> {
        let state = self.state.lock().await;
        state
            .tracked
            .iter()
            .find(|(_, tracked)| tracked.role == Role::Current)
            .map(|(hash, _)| hash.clone())
    }

    /// What happens to the playing torrent when another takes its place.
    async fn demote_current(self: &Arc<Self>) {
        if let Some(hash) = self.current_hash().await {
            self.demote_hash(&hash).await;
        }
    }

    async fn demote_hash(self: &Arc<Self>, hash: &str) {
        let (incomplete, persist) = {
            let state = self.state.lock().await;
            (
                state.tracked.get(hash).map(|tracked| tracked.incomplete).unwrap_or(true),
                state.settings.torrent_persist,
            )
        };
        let finished = !incomplete || self.is_finished(hash);
        if finished {
            let mut state = self.state.lock().await;
            if let Some(tracked) = state.tracked.get_mut(hash) {
                tracked.role = Role::Seeding;
                tracked.incomplete = false;
            }
            drop(state);
            self.enforce_seeding_limit().await;
        } else if persist {
            let mut state = self.state.lock().await;
            if let Some(tracked) = state.tracked.get_mut(hash) {
                tracked.role = Role::Staging;
            }
        } else {
            self.delete(hash, true).await;
            self.state.lock().await.tracked.remove(hash);
        }
    }

    /// "When the seeding limit is reached, the highest ratio torrent is
    /// completed" — the settings-page contract.
    async fn enforce_seeding_limit(self: &Arc<Self>) {
        let (limit, seeding) = {
            let state = self.state.lock().await;
            let limit = state.settings.seeding_limit.unwrap_or(u32::MAX).max(1) as usize;
            let seeding: Vec<String> = state
                .tracked
                .iter()
                .filter(|(_, tracked)| tracked.role == Role::Seeding)
                .map(|(hash, _)| hash.clone())
                .collect();
            (limit, seeding)
        };
        if seeding.len() <= limit {
            return;
        }
        let mut best: Option<(String, f64)> = None;
        for hash in seeding {
            let ratio = self.ratio(&hash);
            if best.as_ref().map(|(_, top)| ratio >= *top).unwrap_or(true) {
                best = Some((hash, ratio));
            }
        }
        if let Some((hash, _)) = best {
            self.complete(hash).await;
        }
    }

    fn handle(&self, hash: &str) -> Option<Arc<ManagedTorrent>> {
        let id = TorrentIdOrHash::parse(hash).ok()?;
        self.rqbit().get(id)
    }

    fn is_finished(&self, hash: &str) -> bool {
        self.handle(hash).map(|handle| handle.stats().finished).unwrap_or(false)
    }

    fn ratio(&self, hash: &str) -> f64 {
        self.handle(hash)
            .map(|handle| {
                let stats = handle.stats();
                stats.uploaded_bytes as f64 / stats.progress_bytes.max(1) as f64
            })
            .unwrap_or(0.0)
    }

    fn rqbit(&self) -> &Arc<Session> {
        self.engine.rqbit_session()
    }

    fn gateway(&self) -> &Gateway {
        self.engine.media_gateway()
    }

    async fn delete(&self, hash: &str, delete_files: bool) {
        if let Ok(id) = TorrentIdOrHash::parse(hash) {
            let _ = self.rqbit().delete(id, delete_files).await;
        }
    }

    async fn add_id(&self, id: &str, paused: bool) -> Result<String, TorrentError> {
        let add = if id.starts_with("magnet:") || id.starts_with("http://") || id.starts_with("https://") {
            AddTorrent::from_url(id.to_string())
        } else if let Some(hash) = parse_hash(id) {
            AddTorrent::from_url(to_magnet(&hash).unwrap_or_default())
        } else {
            return Err(TorrentError::InvalidId(id.to_string()));
        };
        self.add(add, paused).await
    }

    async fn add_bytes(&self, bytes: Vec<u8>) -> Result<String, TorrentError> {
        self.add(AddTorrent::from_bytes(bytes), false).await
    }

    async fn add(&self, add: AddTorrent<'static>, paused: bool) -> Result<String, TorrentError> {
        let response = self
            .rqbit()
            .add_torrent(
                add,
                Some(AddTorrentOptions { overwrite: true, paused, ..Default::default() }),
            )
            .await
            .map_err(|error| TorrentError::Engine(format!("add: {error:#}")))?;
        let handle = response
            .into_handle()
            .ok_or_else(|| TorrentError::Engine("torrent was not added".into()))?;
        Ok(handle.info_hash().as_string())
    }

    /// Waits for metadata and records the torrent under `role`, keeping the
    /// original added-date when re-adopting a known one.
    async fn track(&self, hash: &str, role: Role) -> Result<Tracked, TorrentError> {
        let metadata = self.engine.metadata(hash).await?;
        let size = metadata.files.iter().map(|file| file.size).sum();
        let finished = self.is_finished(hash);
        let tracked = Tracked {
            name: metadata.name.clone(),
            size,
            magnet: to_magnet(hash).unwrap_or_default(),
            date: iso_now(),
            role,
            incomplete: !finished,
        };
        let mut state = self.state.lock().await;
        let entry = state
            .tracked
            .entry(hash.to_string())
            .and_modify(|existing| {
                existing.role = role;
                existing.name = tracked.name.clone();
                existing.size = size;
                existing.incomplete = !finished;
            })
            .or_insert(tracked);
        Ok(entry.clone())
    }

    /// The renderer's `files` array for a torrent, gateway URLs included.
    pub async fn player_files(&self, hash: &str) -> Result<Vec<PlayerFile>, TorrentError> {
        let metadata = self.engine.metadata(hash).await?;
        Ok(metadata
            .files
            .iter()
            .map(|file| {
                shape_player_file(
                    &metadata.info_hash,
                    &metadata.name,
                    &file.path,
                    file.size,
                    self.gateway().url_for(&metadata.info_hash, file.index),
                )
            })
            .collect())
    }

    fn activity_shape(&self, hash: &str, tracked: &Tracked) -> ActivityTorrent {
        let stats = self.handle(hash).map(|handle| handle.stats());
        let (progress, num_peers, download_speed, upload_speed, eta, ratio) = match &stats {
            Some(stats) => {
                let progress = if stats.total_bytes == 0 {
                    0.0
                } else {
                    stats.progress_bytes as f64 / stats.total_bytes as f64
                };
                let live = stats.live.as_ref();
                let mbps_to_bytes = |mbps: f64| (mbps * 125_000.0) as u64;
                let download = live.map(|live| mbps_to_bytes(live.download_speed.mbps)).unwrap_or(0);
                let upload = live.map(|live| mbps_to_bytes(live.upload_speed.mbps)).unwrap_or(0);
                let remaining = stats.total_bytes.saturating_sub(stats.progress_bytes);
                let eta = if download > 0 { remaining * 1000 / download } else { 0 };
                let ratio = stats.uploaded_bytes as f64 / stats.progress_bytes.max(1) as f64;
                (
                    progress,
                    live.map(|live| live.snapshot.peer_stats.live).unwrap_or(0),
                    download,
                    upload,
                    eta,
                    ratio,
                )
            }
            None => (if tracked.incomplete { 0.0 } else { 1.0 }, 0, 0, 0, 0, 0.0),
        };
        ActivityTorrent {
            info_hash: hash.to_string(),
            name: tracked.name.clone(),
            size: tracked.size,
            progress,
            incomplete: tracked.incomplete && progress < 1.0,
            // librqbit does not split connected peers into seeders/leechers; the
            // totals come from scrape when the UI asks for them
            num_seeders: num_peers,
            total_seeders: 0,
            num_leechers: 0,
            total_leechers: 0,
            num_peers,
            download_speed,
            upload_speed,
            magnet_uri: tracked.magnet.clone(),
            date: tracked.date.clone(),
            eta,
            ratio,
        }
    }

    async fn emit_snapshot(self: &Arc<Self>) {
        let state = self.state.lock().await;
        let mut snapshot = Snapshot::default();
        for (hash, tracked) in state.tracked.iter() {
            match tracked.role {
                Role::Current => snapshot.current = Some(self.activity_shape(hash, tracked)),
                Role::Staging => snapshot.staging.push(self.activity_shape(hash, tracked)),
                Role::Seeding => snapshot.seeding.push(self.activity_shape(hash, tracked)),
                Role::Completed => snapshot.completed.push(CompletedTorrent {
                    info_hash: hash.clone(),
                    name: tracked.name.clone(),
                    size: tracked.size,
                    progress: if tracked.incomplete { 0.0 } else { 1.0 },
                    incomplete: tracked.incomplete,
                    magnet_uri: tracked.magnet.clone(),
                    date: tracked.date.clone(),
                }),
            }
        }
        drop(state);
        self.emit(SessionEvent::Stats(snapshot));
    }

    fn spawn_loops(self: Arc<Self>) {
        let fast = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_millis(200));
            loop {
                tick.tick().await;
                if fast.events.is_closed() {
                    break;
                }
                let playing = fast.state.lock().await.playing.clone();
                let Some((hash, _)) = playing else { continue };
                let Some(handle) = fast.handle(&hash) else { continue };
                let stats = handle.stats();
                let live = stats.live.as_ref();
                let mbps_to_bytes = |mbps: f64| (mbps * 125_000.0) as u64;
                fast.emit(SessionEvent::CurrentStats(CurrentStats {
                    num_peers: live.map(|live| live.snapshot.peer_stats.live).unwrap_or(0),
                    upload_speed: live.map(|live| mbps_to_bytes(live.upload_speed.mbps)).unwrap_or(0),
                    download_speed: live.map(|live| mbps_to_bytes(live.download_speed.mbps)).unwrap_or(0),
                }));
            }
        });
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(5));
            loop {
                tick.tick().await;
                if self.events.is_closed() {
                    break;
                }
                let playing = self.state.lock().await.playing.clone();
                let mut completed = false;
                if let Some((hash, index)) = playing {
                    if let Some(handle) = self.handle(&hash) {
                        let stats = handle.stats();
                        let done = stats.file_progress.get(index as usize).copied().unwrap_or(0);
                        let size = handle
                            .with_metadata(|metadata| {
                                metadata
                                    .info
                                    .iter_file_details()
                                    .nth(index as usize)
                                    .map(|details| details.len)
                            })
                            .ok()
                            .flatten()
                            .unwrap_or(0);
                        if size > 0 {
                            self.emit(SessionEvent::Progress(done as f64 / size as f64));
                        }
                        // finishing the download flips the record for the UI lists
                        if stats.finished {
                            let mut state = self.state.lock().await;
                            if let Some(tracked) = state.tracked.get_mut(&hash) {
                                if tracked.incomplete {
                                    tracked.incomplete = false;
                                    completed = true;
                                }
                            }
                        }
                    }
                }
                // Persist the transition once, so a restart does not re-adopt a torrent that
                // had already completed. Snapshot after the transition so the UI sees it now.
                if completed {
                    self.save_registry().await;
                }
                self.emit_snapshot().await;
            }
        });
    }
}

fn shape_player_file(info_hash: &str, torrent_name: &str, path: &str, size: u64, url: String) -> PlayerFile {
    let relative = path.trim_start_matches('/');
    let name = relative.rsplit('/').next().unwrap_or(relative).to_string();
    PlayerFile {
        info_hash: info_hash.to_string(),
        // one implementation for both lanes, so a debrid play and a torrent play of the
        // same file can never end up under different watch keys
        file_hash: shiru_domain::watch_key(info_hash, &name, size),
        torrent_name: torrent_name.to_string(),
        mime: mime_for(&name),
        name,
        size,
        path: relative.to_string(),
        url,
    }
}

fn playback_selection(metadata: &TorrentMetadata, wanted: u32, streamed: bool) -> Vec<u32> {
    if streamed {
        vec![wanted]
    } else {
        metadata.files.iter().map(|file| file.index).collect()
    }
}

async fn select_playback_files<E: TorrentEngine + ?Sized>(
    engine: &E,
    info_hash: &str,
    metadata: &TorrentMetadata,
    wanted: u32,
    streamed: bool,
) -> Result<(), TorrentError> {
    let selection = playback_selection(metadata, wanted, streamed);
    engine.select_files(info_hash, &selection).await
}

fn mime_for(name: &str) -> String {
    let extension = name.rsplit('.').next().unwrap_or_default().to_ascii_lowercase();
    match extension.as_str() {
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "mp4" | "m4v" => "video/mp4",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "ts" | "m2ts" => "video/mp2t",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
        "ogg" | "oga" => "audio/ogg",
        "srt" => "application/x-subrip",
        "ass" | "ssa" => "text/x-ssa",
        "vtt" => "text/vtt",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Seconds-since-epoch as an ISO-8601 UTC string. The renderer only ever hands
/// this to `new Date(...)`.
fn iso_now() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    iso_from_epoch(seconds as i64)
}

fn iso_from_epoch(seconds: i64) -> String {
    // Howard Hinnant's civil_from_days
    let days = seconds.div_euclid(86_400);
    let remainder = seconds.rem_euclid(86_400);
    let (hour, minute, second) = (remainder / 3600, (remainder % 3600) / 60, remainder % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    // standard alphabet with optional padding — what the renderer produces
    let compact: Vec<u8> = text.bytes().filter(|byte| !byte.is_ascii_whitespace()).collect();
    let padding = compact.iter().rev().take_while(|byte| **byte == b'=').count();
    if compact.is_empty()
        || padding > 2
        || compact[..compact.len() - padding].contains(&b'=')
        || (padding > 0 && compact.len() % 4 != 0)
    {
        return None;
    }
    let cleaned = &compact[..compact.len() - padding];
    if cleaned.is_empty()
        || cleaned.len() % 4 == 1
        || (padding == 1 && cleaned.len() % 4 != 3)
        || (padding == 2 && cleaned.len() % 4 != 2)
    {
        return None;
    }
    let value = |byte: u8| -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some((byte - b'A') as u32),
            b'a'..=b'z' => Some((byte - b'a' + 26) as u32),
            b'0'..=b'9' => Some((byte - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let mut out = Vec::with_capacity(cleaned.len() * 3 / 4);
    for chunk in cleaned.chunks(4) {
        let mut buffer = 0u32;
        for (position, byte) in chunk.iter().enumerate() {
            buffer |= value(*byte)? << (18 - 6 * position);
        }
        let bytes = [(buffer >> 16) as u8, (buffer >> 8) as u8, buffer as u8];
        out.extend_from_slice(&bytes[..chunk.len().saturating_sub(1)]);
    }
    Some(out)
}

/// announce URL → scrape URL, per the BEP 48 convention. None when the tracker
/// does not scrape (no /announce path segment) or is not HTTP.
fn scrape_url(tracker: &str) -> Option<String> {
    if !tracker.starts_with("http://") && !tracker.starts_with("https://") {
        return None;
    }
    let (base, _query) = tracker.split_once('?').unwrap_or((tracker, ""));
    let position = base.rfind("/announce")?;
    let mut scrape = String::with_capacity(base.len() + 7);
    scrape.push_str(&base[..position]);
    scrape.push_str("/scrape");
    scrape.push_str(&base[position + "/announce".len()..]);
    Some(scrape)
}

fn percent_bytes(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("%{byte:02x}")).collect()
}

/// Minimal bencode walk over a scrape response: `d5:filesd<20-byte hash>d…ee`.
/// Returns (hex hash, counts) for every entry it can read; garbage is skipped.
fn parse_scrape_response(body: &[u8]) -> Vec<(String, ScrapeEntry)> {
    fn parse_int(body: &[u8], at: &mut usize) -> Option<i64> {
        if body.get(*at) != Some(&b'i') {
            return None;
        }
        *at += 1;
        let end = body[*at..].iter().position(|byte| *byte == b'e')? + *at;
        let number = std::str::from_utf8(&body[*at..end]).ok()?.parse().ok()?;
        *at = end + 1;
        Some(number)
    }
    fn parse_bytes<'a>(body: &'a [u8], at: &mut usize) -> Option<&'a [u8]> {
        let colon = body[*at..].iter().position(|byte| *byte == b':')? + *at;
        let length: usize = std::str::from_utf8(&body[*at..colon]).ok()?.parse().ok()?;
        let start = colon + 1;
        let end = start.checked_add(length)?;
        if end > body.len() {
            return None;
        }
        *at = end;
        Some(&body[start..end])
    }
    fn skip_value(body: &[u8], at: &mut usize) -> Option<()> {
        match body.get(*at)? {
            b'i' => {
                parse_int(body, at)?;
            }
            b'l' | b'd' => {
                *at += 1;
                while body.get(*at) != Some(&b'e') {
                    skip_value(body, at)?;
                }
                *at += 1;
            }
            _ => {
                parse_bytes(body, at)?;
            }
        }
        Some(())
    }

    let mut entries = Vec::new();
    let mut at = 0usize;
    if body.get(at) != Some(&b'd') {
        return entries;
    }
    at += 1;
    while body.get(at).is_some() && body[at] != b'e' {
        let Some(key) = parse_bytes(body, &mut at) else { return entries };
        if key != b"files" {
            if skip_value(body, &mut at).is_none() {
                return entries;
            }
            continue;
        }
        if body.get(at) != Some(&b'd') {
            return entries;
        }
        at += 1;
        while body.get(at).is_some() && body[at] != b'e' {
            let Some(hash) = parse_bytes(body, &mut at) else { return entries };
            if body.get(at) != Some(&b'd') {
                return entries;
            }
            at += 1;
            let mut entry = ScrapeEntry {
                hash: hex::encode(hash),
                complete: 0,
                downloaded: 0,
                incomplete: 0,
            };
            while body.get(at).is_some() && body[at] != b'e' {
                let Some(field) = parse_bytes(body, &mut at) else { return entries };
                if let Some(number) = parse_int(body, &mut at) {
                    match field {
                        b"complete" => entry.complete = number.max(0) as u32,
                        b"downloaded" => entry.downloaded = number.max(0) as u32,
                        b"incomplete" => entry.incomplete = number.max(0) as u32,
                        _ => {}
                    }
                } else if skip_value(body, &mut at).is_none() {
                    return entries;
                }
            }
            at += 1;
            if hash.len() == 20 {
                entries.push((entry.hash.clone(), entry));
            }
        }
        return entries;
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn player_file_shape_matches_the_debrid_identity_contract() {
        let file = shape_player_file(
            "cab1a8cd6ea5d193fd4ea88b8e02b3e5e53e0dcb",
            "Some Release",
            "/Season 1/Episode 1.mkv",
            123_456,
            "http://127.0.0.1:1/t/x/0".into(),
        );
        assert_eq!(file.name, "Episode 1.mkv");
        assert_eq!(file.path, "Season 1/Episode 1.mkv");
        assert_eq!(file.mime, "video/x-matroska");
        // pinned so watch progress keys never drift; the debrid lane calls the same
        // shiru_domain::watch_key, and crates/domain pins this exact vector too
        assert_eq!(
            file.file_hash,
            shiru_domain::watch_key("cab1a8cd6ea5d193fd4ea88b8e02b3e5e53e0dcb", "Episode 1.mkv", 123_456)
        );
        let json = serde_json::to_value(&file).unwrap();
        for key in ["infoHash", "fileHash", "torrent_name", "name", "type", "size", "path", "url"] {
            assert!(json.get(key).is_some(), "missing wire field {key}");
        }
    }

    #[test]
    fn snapshot_wire_names_match_the_svelte_stores() {
        let torrent = ActivityTorrent {
            info_hash: "aa".into(),
            name: "n".into(),
            size: 1,
            progress: 0.5,
            incomplete: true,
            num_seeders: 1,
            total_seeders: 2,
            num_leechers: 3,
            total_leechers: 4,
            num_peers: 5,
            download_speed: 6,
            upload_speed: 7,
            magnet_uri: "magnet:?xt=urn:btih:aa".into(),
            date: "2026-08-19T00:00:00Z".into(),
            eta: 1000,
            ratio: 0.1,
        };
        let json = serde_json::to_value(&torrent).unwrap();
        for key in [
            "infoHash", "name", "size", "progress", "incomplete", "numSeeders", "totalSeeders",
            "numLeechers", "totalLeechers", "numPeers", "downloadSpeed", "uploadSpeed",
            "magnetURI", "date", "eta", "ratio",
        ] {
            assert!(json.get(key).is_some(), "missing wire field {key}");
        }
    }

    #[test]
    fn iso_from_epoch_matches_known_dates() {
        assert_eq!(iso_from_epoch(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso_from_epoch(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(iso_from_epoch(1_787_097_600), "2026-08-19T00:00:00Z");
    }

    #[test]
    fn base64_round_trips_torrent_bytes() {
        assert_eq!(base64_decode("ZDg6YW5ub3VuY2Vl").unwrap(), b"d8:announcee");
        assert_eq!(base64_decode("YQ==").unwrap(), b"a");
        assert_eq!(base64_decode("YWI=").unwrap(), b"ab");
        assert_eq!(base64_decode("!!!"), None);
        assert_eq!(base64_decode(""), None);
        assert_eq!(base64_decode("A"), None, "a one-symbol tail cannot encode a byte");
        assert_eq!(base64_decode("Y=Q="), None, "padding is only valid at the end");
        assert_eq!(base64_decode("YQ==="), None, "at most two padding bytes are valid");
    }

    #[derive(Default)]
    struct SelectionSpy {
        calls: std::sync::Mutex<Vec<(String, Vec<u32>)>>,
    }

    #[async_trait::async_trait]
    impl TorrentEngine for SelectionSpy {
        async fn add(&self, _id: &str) -> Result<String, TorrentError> {
            unreachable!()
        }

        async fn metadata(&self, _info_hash: &str) -> Result<TorrentMetadata, TorrentError> {
            unreachable!()
        }

        async fn select_files(&self, info_hash: &str, indexes: &[u32]) -> Result<(), TorrentError> {
            self.calls.lock().unwrap().push((info_hash.to_string(), indexes.to_vec()));
            Ok(())
        }

        async fn playback_source(
            &self,
            _info_hash: &str,
            _index: u32,
        ) -> Result<shiru_domain::PlaybackSource, TorrentError> {
            unreachable!()
        }

        async fn pause(&self, _info_hash: &str) -> Result<(), TorrentError> {
            unreachable!()
        }

        async fn resume(&self, _info_hash: &str) -> Result<(), TorrentError> {
            unreachable!()
        }

        async fn remove(&self, _info_hash: &str) -> Result<(), TorrentError> {
            unreachable!()
        }

        async fn status(&self, _info_hash: &str) -> Result<crate::TorrentStatus, TorrentError> {
            unreachable!()
        }
    }

    #[tokio::test]
    async fn streamed_playback_selects_one_file_and_full_download_selects_the_set_once() {
        let metadata = TorrentMetadata {
            info_hash: "a".repeat(40),
            name: "Season pack".into(),
            files: vec![
                crate::TorrentFileInfo { index: 0, path: "/Show - 01.mkv".into(), size: 100 },
                crate::TorrentFileInfo { index: 1, path: "/Show - 02.mkv".into(), size: 100 },
                crate::TorrentFileInfo { index: 2, path: "/Show - 03.mkv".into(), size: 100 },
            ],
        };
        let engine = SelectionSpy::default();
        select_playback_files(&engine, &metadata.info_hash, &metadata, 1, true).await.unwrap();
        select_playback_files(&engine, &metadata.info_hash, &metadata, 1, false).await.unwrap();

        assert_eq!(
            *engine.calls.lock().unwrap(),
            vec![(metadata.info_hash.clone(), vec![1]), (metadata.info_hash, vec![0, 1, 2])],
            "rqbit replaces its selection on every call, so the full set must arrive together"
        );
    }

    #[test]
    fn scrape_urls_follow_the_announce_convention() {
        assert_eq!(
            scrape_url("https://tracker.example/announce").as_deref(),
            Some("https://tracker.example/scrape")
        );
        assert_eq!(
            scrape_url("http://tracker.example/announce?key=abc").as_deref(),
            Some("http://tracker.example/scrape")
        );
        assert_eq!(scrape_url("udp://tracker.example:80/announce"), None);
        assert_eq!(scrape_url("https://tracker.example/other"), None);
    }

    #[test]
    fn scrape_responses_parse_and_garbage_is_skipped() {
        let hash = [0xabu8; 20];
        let mut body = Vec::new();
        body.extend_from_slice(b"d5:filesd20:");
        body.extend_from_slice(&hash);
        body.extend_from_slice(b"d8:completei12e10:downloadedi34e10:incompletei56e4:junki9eee");
        body.extend_from_slice(b"5:extrai1ee");
        let entries = parse_scrape_response(&body);
        assert_eq!(entries.len(), 1);
        let (hex_hash, entry) = &entries[0];
        assert_eq!(hex_hash, &hex::encode(hash));
        assert_eq!((entry.complete, entry.downloaded, entry.incomplete), (12, 34, 56));
        assert!(parse_scrape_response(b"garbage").is_empty());
        assert!(parse_scrape_response(b"d5:filesdee").is_empty());
    }

    #[test]
    fn settings_deserialize_from_the_renderer_shape() {
        let settings: SessionSettings = serde_json::from_str(
            r#"{
                "userID": "u", "dht": true, "torrentUTP": false, "torrentPeX": false,
                "maxConns": 64, "downloadLimit": 1048576, "uploadLimit": 0,
                "torrentPort": 0, "dhtPort": 0, "torrentPersist": false,
                "torrentStreamedDownload": true, "torrentPathNew": null,
                "playerPath": "", "seedingLimit": 3, "disableStartupTorrent": false,
                "trackers": ["https://tracker.example/announce"], "debug": ""
            }"#,
        )
        .unwrap();
        assert!(settings.dht);
        assert_eq!(settings.max_conns, Some(64));
        assert_eq!(settings.download_limit, 1_048_576);
        assert_eq!(settings.seeding_limit, Some(3));
        assert_eq!(settings.trackers.len(), 1);
        assert!(settings.torrent_path_new.is_none());
    }
}
