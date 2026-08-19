//! Torrent IPC: one session, started by the frontend with its settings; every
//! session event is forwarded as a `shiru://torrent` window event of the shape
//! `{ type, data }`, fanned out by the injected bridge script.

use shiru_torrent::{ScrapeEntry, SessionSettings, TorrentSession};
use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::Mutex;

#[derive(Default)]
pub struct TorrentState {
    session: Mutex<Option<Arc<TorrentSession>>>,
}

impl TorrentState {
    async fn session(&self) -> Result<Arc<TorrentSession>, String> {
        self.session
            .lock()
            .await
            .clone()
            .ok_or_else(|| "torrent session not started".to_string())
    }
}

/// Starts (or restarts) the session with the renderer's settings and begins
/// pushing events. Resolving tells the frontend the session is ready.
#[tauri::command]
pub async fn torrent_start(
    app: tauri::AppHandle,
    state: tauri::State<'_, TorrentState>,
    settings: SessionSettings,
) -> Result<(), String> {
    let mut slot = state.session.lock().await;
    if slot.is_some() {
        // settings changed mid-run: apply what can change live
        if let Some(session) = slot.clone() {
            session.update_settings(settings).await;
        }
        return Ok(());
    }
    let dir = app
        .path()
        .app_cache_dir()
        .map_err(|error| error.to_string())?
        .join("torrents");
    let (session, mut events) = TorrentSession::start(dir, settings)
        .await
        .map_err(|error| error.to_string())?;
    let emitter = app.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = events.recv().await {
            let (kind, data) = event.wire();
            let _ = emitter.emit("shiru://torrent", serde_json::json!({ "type": kind, "data": data }));
        }
    });
    *slot = Some(session);
    Ok(())
}

#[tauri::command]
pub async fn torrent_stream(
    state: tauri::State<'_, TorrentState>,
    id: String,
    #[allow(non_snake_case)] base64: Option<bool>,
) -> Result<(), String> {
    let session = state.session().await?;
    tauri::async_runtime::spawn(async move { session.stream(id, base64.unwrap_or(false)).await });
    Ok(())
}

#[tauri::command]
pub async fn torrent_stage(
    state: tauri::State<'_, TorrentState>,
    id: String,
    base64: Option<bool>,
) -> Result<(), String> {
    let session = state.session().await?;
    tauri::async_runtime::spawn(async move { session.stage(id, base64.unwrap_or(false)).await });
    Ok(())
}

#[tauri::command]
pub async fn torrent_unload(state: tauri::State<'_, TorrentState>) -> Result<(), String> {
    state.session().await?.unload().await;
    Ok(())
}

#[tauri::command]
pub async fn torrent_untrack(state: tauri::State<'_, TorrentState>, hash: String) -> Result<(), String> {
    state.session().await?.untrack(hash).await;
    Ok(())
}

#[tauri::command]
pub async fn torrent_complete(state: tauri::State<'_, TorrentState>, hash: String) -> Result<(), String> {
    state.session().await?.complete(hash).await;
    Ok(())
}

#[tauri::command]
pub async fn torrent_rescan(state: tauri::State<'_, TorrentState>) -> Result<(), String> {
    state.session().await?.rescan().await;
    Ok(())
}

#[tauri::command]
pub async fn torrent_scrape(
    state: tauri::State<'_, TorrentState>,
    hashes: Vec<String>,
) -> Result<Vec<ScrapeEntry>, String> {
    Ok(state.session().await?.scrape(hashes).await)
}

#[tauri::command]
pub async fn torrent_set_playback(
    state: tauri::State<'_, TorrentState>,
    current: serde_json::Value,
    external: Option<bool>,
) -> Result<(), String> {
    state
        .session()
        .await?
        .set_playback(current, external.unwrap_or(false))
        .await;
    Ok(())
}

#[tauri::command]
pub async fn torrent_launch_external(
    state: tauri::State<'_, TorrentState>,
    current: serde_json::Value,
) -> Result<(), String> {
    state.session().await?.launch_external(current).await;
    Ok(())
}

#[tauri::command]
pub async fn torrent_update_settings(
    state: tauri::State<'_, TorrentState>,
    settings: SessionSettings,
) -> Result<(), String> {
    state.session().await?.update_settings(settings).await;
    Ok(())
}
