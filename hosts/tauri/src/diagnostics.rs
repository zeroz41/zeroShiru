//! One snapshot of everything worth knowing when the app misbehaves, and the knob
//! that makes the log louder without a restart.
//!
//! The lesson behind this file: every debugging session on this app has started by
//! discovering that the state which explained the problem — a debrid service gone
//! quiet, a limiter pause, an art cache refusing a URL — existed in memory and was
//! visible nowhere. The snapshot is pull-based and cheap, so the settings screen can
//! poll it while open and cost nothing the rest of the time.

use crate::debrid::{DebridState, ServiceHealth};
use crate::{logging, media_cache};
use serde::Serialize;

#[derive(Serialize)]
pub struct Diagnostics {
    pub version: &'static str,
    pub uptime_ms: u64,
    pub log: logging::LogStats,
    /// Every warm debrid provider, most recently used first.
    pub debrid: Vec<ServiceHealth>,
    pub media_cache: media_cache::MediaCacheStats,
}

#[tauri::command]
pub async fn get_diagnostics(
    app: tauri::AppHandle,
    debrid: tauri::State<'_, DebridState>,
) -> Result<Diagnostics, String> {
    let debrid = debrid.health();
    let dir = media_cache::media_dir(&app);
    // the directory walk is real IO, so it runs off the async workers
    let media_cache = tauri::async_runtime::spawn_blocking(move || media_cache::stats(dir.as_deref()))
        .await
        .map_err(|error| error.to_string())?;
    Ok(Diagnostics {
        version: env!("CARGO_PKG_VERSION"),
        uptime_ms: logging::uptime_ms(),
        log: logging::stats(),
        debrid,
        media_cache,
    })
}

/// Changes how loud the host log is, live. An empty filter returns to the default.
#[tauri::command]
pub fn set_log_filter(filter: String) -> Result<(), String> {
    logging::set_filter(&filter)
}
