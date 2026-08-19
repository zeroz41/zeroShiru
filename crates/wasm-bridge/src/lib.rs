//! The WASM surface for the TV hosts (Tizen/webOS). JSON in, JSON out at the
//! boundary — keeps the ABI simple and mirrors the Tauri IPC command shapes, so
//! the frontend service layer can wrap either host identically.
//!
//! Targets baseline browser WebAssembly only: no threads, no SIMD, no exotic
//! extensions (migration report section 55).

use wasm_bindgen::prelude::*;

/// The lowercase info hash of a magnet URI or bare hash, empty when there is none.
#[wasm_bindgen]
pub fn parse_hash(magnet_or_hash: &str) -> String {
    shiru_domain::parse_hash(magnet_or_hash).unwrap_or_default()
}

/// Route a play request. Takes/returns the same JSON shapes as the Tauri
/// `route_playback` command.
#[wasm_bindgen]
pub fn route_playback(request_json: &str) -> Result<String, JsError> {
    #[derive(serde::Deserialize)]
    struct RouteRequest {
        torrent_id: Option<String>,
        hash: Option<String>,
        service_selected: bool,
        service_ready: bool,
        offline: bool,
        mode: Option<shiru_core::DebridMode>,
    }
    let request: RouteRequest = serde_json::from_str(request_json)?;
    let decision = shiru_core::route_debrid(&shiru_core::RouteInput {
        torrent_id: request.torrent_id.as_deref(),
        hash: request.hash.as_deref(),
        service_selected: request.service_selected,
        service_ready: request.service_ready,
        offline: request.offline,
        mode: request.mode,
    });
    Ok(serde_json::to_string(&decision)?)
}

/// Normalize a source id into a StreamCandidate, or null when unusable.
#[wasm_bindgen]
pub fn normalize_source(torrent_id: &str) -> Result<String, JsError> {
    Ok(serde_json::to_string(&shiru_sources::normalize(torrent_id))?)
}

/// Detect a media container from the first bytes of a stream.
#[wasm_bindgen]
pub fn detect_container(head: &[u8]) -> String {
    format!("{:?}", shiru_media::detect_container(head)).to_lowercase()
}

/// Parse Matroska metadata from the head of a stream. Returns the info as JSON;
/// throws with a message starting "need-more-data" when the slice ends before
/// the Tracks element — the caller fetches a larger range and retries.
#[wasm_bindgen]
pub fn parse_matroska_head(bytes: &[u8]) -> Result<String, JsError> {
    match shiru_media::parse_matroska_head(bytes) {
        Ok(info) => Ok(serde_json::to_string(&info)?),
        Err(shiru_media::MatroskaError::NeedMoreData) => Err(JsError::new("need-more-data")),
        Err(error) => Err(JsError::new(&error.to_string())),
    }
}
