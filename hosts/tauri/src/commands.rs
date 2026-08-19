//! IPC adapters. Each command is a thin translation onto the shared Rust core —
//! the Svelte side talks to these through its service layer, never directly.

use serde::{Deserialize, Serialize};
use shiru_core::{route_debrid, DebridMode, RouteDecision, RouteInput};
use shiru_platform_contracts::PlatformCapabilities;

#[derive(Serialize)]
pub struct PlatformInfo {
    pub platform: &'static str,
    pub arch: &'static str,
    pub development: bool,
    pub capabilities: PlatformCapabilities,
}

#[tauri::command]
pub fn get_app_version(app: tauri::AppHandle) -> String {
    app.package_info().version.to_string()
}

pub fn platform_info() -> PlatformInfo {
    PlatformInfo {
        platform: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        development: cfg!(debug_assertions),
        capabilities: PlatformCapabilities::DESKTOP,
    }
}

#[tauri::command]
pub fn get_platform_info() -> PlatformInfo {
    platform_info()
}

/// Opens a URL in the system browser. Scheme-restricted: the bridge's openURI is
/// reachable from page content, and a file:// or custom scheme here would be an
/// escape hatch.
#[tauri::command]
pub fn open_uri(uri: String) -> Result<(), String> {
    if !uri.starts_with("https://") && !uri.starts_with("http://") {
        return Err("only http(s) URLs may be opened".into());
    }
    #[cfg(desktop)]
    return open::that_detached(&uri).map_err(|error| error.to_string());
    #[cfg(mobile)]
    {
        let _ = uri;
        Err("open_uri needs the mobile opener adapter (phase 12)".into())
    }
}

#[derive(Deserialize)]
pub struct RouteRequest {
    pub torrent_id: Option<String>,
    pub hash: Option<String>,
    pub service_selected: bool,
    pub service_ready: bool,
    pub offline: bool,
    pub mode: Option<DebridMode>,
}

/// How a play request should be handled, decided by the shared core.
#[tauri::command]
pub fn route_playback(request: RouteRequest) -> RouteDecision {
    route_debrid(&RouteInput {
        torrent_id: request.torrent_id.as_deref(),
        hash: request.hash.as_deref(),
        service_selected: request.service_selected,
        service_ready: request.service_ready,
        offline: request.offline,
        mode: request.mode,
    })
}
