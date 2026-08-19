//! Torrent IPC adapters over the shared engine. The engine starts lazily on the
//! first torrent action so a debrid-only session never opens a listen socket.

use shiru_torrent::{RqbitEngine, TorrentEngine, TorrentError, TorrentMetadata, TorrentStatus};
use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::OnceCell;

#[derive(Default)]
pub struct TorrentState {
    engine: OnceCell<Arc<RqbitEngine>>,
}

impl TorrentState {
    async fn engine(&self, app: &tauri::AppHandle) -> Result<Arc<RqbitEngine>, String> {
        self.engine
            .get_or_try_init(|| async {
                let dir = app
                    .path()
                    .app_cache_dir()
                    .map_err(|error| error.to_string())?
                    .join("torrents");
                RqbitEngine::new(dir).await.map(Arc::new).map_err(|error| error.to_string())
            })
            .await
            .cloned()
    }
}

fn fail(error: TorrentError) -> String {
    error.to_string()
}

#[tauri::command]
pub async fn torrent_add(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    id: String,
) -> Result<String, String> {
    let engine = state.engine(&app).await?;
    let hash = engine.add(&id).await.map_err(fail)?;
    // push status instead of making the frontend poll (report section 46);
    // the loop ends itself when the torrent is removed
    let emitter = app.clone();
    let watched = hash.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            match engine.status(&watched).await {
                Ok(status) => {
                    let _ = emitter.emit("shiru://torrent-status", &status);
                }
                Err(_) => break,
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    });
    Ok(hash)
}

#[tauri::command]
pub async fn torrent_metadata(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
) -> Result<TorrentMetadata, String> {
    state.engine(&app).await?.metadata(&info_hash).await.map_err(fail)
}

#[tauri::command]
pub async fn torrent_select_file(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
    index: u32,
) -> Result<(), String> {
    state.engine(&app).await?.select_file(&info_hash, index).await.map_err(fail)
}

#[tauri::command]
pub async fn torrent_playback_source(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
    index: u32,
) -> Result<shiru_domain::PlaybackSource, String> {
    state.engine(&app).await?.playback_source(&info_hash, index).await.map_err(fail)
}

#[tauri::command]
pub async fn torrent_status(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
) -> Result<TorrentStatus, String> {
    state.engine(&app).await?.status(&info_hash).await.map_err(fail)
}

#[tauri::command]
pub async fn torrent_pause(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
) -> Result<(), String> {
    state.engine(&app).await?.pause(&info_hash).await.map_err(fail)
}

#[tauri::command]
pub async fn torrent_resume(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
) -> Result<(), String> {
    state.engine(&app).await?.resume(&info_hash).await.map_err(fail)
}

#[tauri::command]
pub async fn torrent_remove(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    info_hash: String,
) -> Result<(), String> {
    state.engine(&app).await?.remove(&info_hash).await.map_err(fail)
}
