//! The torrent engine interface the application depends on. Implementations are
//! swappable (migration phase 8 provides the first native one); nothing outside
//! this trait may leak engine internals to the UI.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use shiru_domain::PlaybackSource;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TorrentState {
    Fetching,
    Downloading,
    Seeding,
    Paused,
    Errored,
}

/// The only thing the UI receives about a torrent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TorrentStatus {
    pub info_hash: String,
    pub progress: f32,
    pub peers: u32,
    pub download_rate: u64,
    pub upload_rate: u64,
    pub state: TorrentState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TorrentFileInfo {
    pub index: u32,
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TorrentMetadata {
    pub info_hash: String,
    pub name: String,
    pub files: Vec<TorrentFileInfo>,
}

#[derive(Debug, thiserror::Error)]
pub enum TorrentError {
    #[error("invalid torrent id: {0}")]
    InvalidId(String),
    #[error("torrent not found: {0}")]
    NotFound(String),
    #[error("{0}")]
    Engine(String),
}

#[async_trait]
pub trait TorrentEngine: Send + Sync {
    /// Adds a magnet or .torrent and begins fetching metadata.
    async fn add(&self, id: &str) -> Result<String, TorrentError>;
    /// Metadata for an added torrent, waiting for it if necessary.
    async fn metadata(&self, info_hash: &str) -> Result<TorrentMetadata, TorrentError>;
    /// Selects the complete set of files the engine should download. This is one operation:
    /// engines such as rqbit replace their previous selection on every call.
    async fn select_files(&self, info_hash: &str, indexes: &[u32]) -> Result<(), TorrentError>;
    /// Focuses the engine on one file for streaming.
    async fn select_file(&self, info_hash: &str, index: u32) -> Result<(), TorrentError> {
        self.select_files(info_hash, &[index]).await
    }
    /// A playback source for the selected file (loopback gateway or custom protocol).
    async fn playback_source(&self, info_hash: &str, index: u32) -> Result<PlaybackSource, TorrentError>;
    async fn pause(&self, info_hash: &str) -> Result<(), TorrentError>;
    async fn resume(&self, info_hash: &str) -> Result<(), TorrentError>;
    async fn remove(&self, info_hash: &str) -> Result<(), TorrentError>;
    async fn status(&self, info_hash: &str) -> Result<TorrentStatus, TorrentError>;
}

#[cfg(feature = "native")]
mod engine;
#[cfg(feature = "native")]
mod gateway;
#[cfg(feature = "native")]
mod session;
#[cfg(feature = "native")]
pub use engine::RqbitEngine;
#[cfg(feature = "native")]
pub use session::{
    ActivityTorrent, CompletedTorrent, CurrentStats, LoadedTorrent, PlayerFile, Role, ScrapeEntry,
    SessionEvent, SessionSettings, Snapshot, TorrentSession, Tracked,
};
