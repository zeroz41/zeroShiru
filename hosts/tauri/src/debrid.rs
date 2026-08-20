//! Debrid IPC adapters. The frontend owns none of this any more: it asks for an
//! answer and gets one, while provider HTTP, availability memory, the account
//! listing, rate limits and pack picking all live in the shared crates.
//!
//! Provider instances are cached per (service, key) so that memory survives
//! across calls, mirroring the service lifecycle the JS layer used to have.

use serde::Serialize;
use shiru_core::{pick_pack, EpisodeNotInPack};
use shiru_debrid::manager::{create_provider, ManagedProvider, PROVIDER_IDS};
use shiru_debrid::platform::NativePlatform;
use shiru_debrid::{DebridError, ResolveOptions};
use shiru_domain::{to_player_file, Availability, PlayerFile};
use shiru_networking::NativeTransport;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tauri::Emitter;

/// The event channel availability answers arrive on, so badges fill in as a sweep
/// goes rather than all at once when it ends.
const DEBRID_EVENT: &str = "shiru://debrid";

#[derive(Default)]
pub struct DebridState {
    active: Mutex<Option<(String, String, Arc<ManagedProvider>)>>,
}

impl DebridState {
    fn managed(&self, service: &str, api_key: &str) -> Result<Arc<ManagedProvider>, DebridFailure> {
        let mut active = self.active.lock().unwrap();
        if let Some((known_service, known_key, managed)) = active.as_ref() {
            if known_service == service && known_key == api_key {
                return Ok(managed.clone());
            }
        }
        let provider = create_provider(
            service,
            api_key.to_string(),
            Arc::new(NativeTransport::new()),
            Arc::new(NativePlatform),
        )
        .ok_or_else(|| DebridFailure {
            kind: "service",
            message: format!("unknown debrid service: {service}"),
        })?;
        let managed = Arc::new(ManagedProvider::new(provider));
        *active = Some((service.to_string(), api_key.to_string(), managed.clone()));
        Ok(managed)
    }
}

/// Errors cross IPC as their user-facing message plus a kind the frontend can
/// branch on. `not-cached`/`unavailable` prove something about the release;
/// `rejected` says the release is wrong rather than the service.
#[derive(Serialize)]
pub struct DebridFailure {
    pub kind: &'static str,
    pub message: String,
}

fn failure(error: DebridError) -> DebridFailure {
    let kind = match &error {
        DebridError::Auth { .. } => "auth",
        DebridError::Network { .. } => "network",
        DebridError::Timeout { .. } => "timeout",
        DebridError::NotCached { .. } => "not-cached",
        DebridError::Unavailable { .. } => "unavailable",
        DebridError::Rejected { .. } => "rejected",
        DebridError::Service { .. } => "service",
    };
    DebridFailure { kind, message: error.to_string() }
}

/// One selectable service, as the settings menu and the transport description
/// need it. Inlined into the bridge script at startup, so the frontend reads the
/// registry synchronously exactly as it used to read its own.
#[derive(Serialize)]
pub struct ServiceInfo {
    pub id: &'static str,
    pub title: &'static str,
    /// Whether asking about a release puts a magnet on the account. The UI says so,
    /// because it changes what an unanswered release means.
    pub check_adds_magnets: bool,
    /// Most files one resolve turns into stream links.
    pub max_files: usize,
}

/// Every service the app can use, in menu order. Built from the providers
/// themselves, so a new provider shows up here without anything else changing.
pub fn catalog() -> Vec<ServiceInfo> {
    let transport = Arc::new(NativeTransport::new());
    let platform = Arc::new(NativePlatform);
    PROVIDER_IDS
        .iter()
        .filter_map(|id| {
            let provider = create_provider(id, String::new(), transport.clone(), platform.clone())?;
            let config = provider.config();
            Some(ServiceInfo {
                id: config.id,
                title: config.title,
                check_adds_magnets: config.check_adds_magnets,
                max_files: config.max_files,
            })
        })
        .collect()
}

#[derive(Serialize)]
pub struct AccountReply {
    pub username: String,
    pub expires: Option<String>,
}

/// Availability answers plus any release names that rode along with them. Hashes
/// absent from `answers` are unanswered, never "not cached".
#[derive(Serialize, Default)]
pub struct AvailabilityReply {
    pub answers: HashMap<String, Availability>,
    pub names: HashMap<String, String>,
    /// Whether a check that owns the account was already running, so these answers
    /// came from memory rather than from asking.
    pub busy: bool,
}

#[tauri::command]
pub async fn debrid_validate(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
) -> Result<AccountReply, DebridFailure> {
    let managed = state.managed(&service, &api_key)?;
    let info = managed.provider().validate().await.map_err(failure)?;
    Ok(AccountReply { username: info.username, expires: info.expires })
}

/// What the account itself holds — the free badge source, TTL-cached in the
/// manager so the play path can read it without paying for it.
#[tauri::command]
pub async fn debrid_list_availability(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
) -> Result<AvailabilityReply, DebridFailure> {
    let managed = state.managed(&service, &api_key)?;
    let answers = managed.list_availability().await.map_err(failure)?;
    Ok(AvailabilityReply { answers, names: managed.client().release_names(), busy: false })
}

/// Asks the service about the given releases, cheapest way it supports. Answers
/// are also pushed one at a time on `shiru://debrid` so a slow probing sweep
/// badges the list as it goes.
#[tauri::command]
pub async fn debrid_check_availability(
    app: tauri::AppHandle,
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    hashes: Vec<String>,
) -> Result<AvailabilityReply, DebridFailure> {
    let managed = state.managed(&service, &api_key)?;
    let busy = managed.sweeping();
    let answers = managed
        .check_availability(&hashes, |hash, state| {
            let _ = app.emit(
                DEBRID_EVENT,
                serde_json::json!({ "type": "availability", "data": { "hash": hash, "state": state } }),
            );
        })
        .await
        .map_err(failure)?;
    Ok(AvailabilityReply { answers, names: managed.client().release_names(), busy })
}

/// The hashes nothing is known about yet. Callers use this to skip work entirely,
/// not to decide what to ask about.
#[tauri::command]
pub async fn debrid_unknown_hashes(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    hashes: Vec<String>,
) -> Result<Vec<String>, DebridFailure> {
    Ok(state.managed(&service, &api_key)?.unknown_hashes(&hashes))
}

/// Records an answer the app proved for itself — playing a release is the most
/// authoritative cache answer there is.
#[tauri::command]
pub async fn debrid_remember(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    hash: String,
    state_value: String,
) -> Result<(), DebridFailure> {
    state
        .managed(&service, &api_key)?
        .client()
        .remember(&hash, Availability::normalize(&state_value));
    Ok(())
}

/// Resolves a magnet to player-ready files. `episode` picks the right file out of
/// a season pack using the shared recognizer; without it the largest file wins.
#[tauri::command]
pub async fn debrid_resolve(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    magnet: String,
    episode: Option<f64>,
) -> Result<ResolvedReply, DebridFailure> {
    let managed = state.managed(&service, &api_key)?;
    let max_files = managed.provider().config().max_files;
    let opts = ResolveOptions {
        file_filter: Some(Box::new(shiru_media::is_playback_path)),
        pick_file: episode.map(|episode| -> shiru_debrid::PickFile {
            Box::new(move |candidates| {
                let files: Vec<(String, u64)> = candidates
                    .iter()
                    .map(|(_, path, size)| (path.clone(), *size))
                    .collect();
                pick_pack(&files, episode, max_files).map_err(|error: EpisodeNotInPack| {
                    DebridError::Rejected { message: error.to_string() }
                })
            })
        }),
        max_files: None,
    };
    let resolved = managed.resolve(&magnet, &opts).await.map_err(failure)?;
    // the account just gained a torrent, so the cached listing no longer describes it
    managed.forget_listing();
    // playing it proves the service holds it, which is the best answer there is
    managed.client().remember(&resolved.hash, Availability::Cached);
    let files = resolved
        .files
        .iter()
        .map(|file| to_player_file(&resolved.hash, &resolved.name, file))
        .collect();
    Ok(ResolvedReply { hash: resolved.hash, name: resolved.name, files })
}

/// A resolved release, shaped the way the player takes files.
#[derive(Serialize)]
pub struct ResolvedReply {
    pub hash: String,
    pub name: String,
    pub files: Vec<PlayerFile>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_catalog_offers_every_provider_in_menu_order() {
        let catalog = catalog();
        let ids: Vec<&str> = catalog.iter().map(|service| service.id).collect();
        assert_eq!(ids, vec!["alldebrid", "premiumize", "realdebrid", "torbox"]);
        // the two facts the UI reads off a service besides its name
        let torbox = catalog.iter().find(|service| service.id == "torbox").unwrap();
        assert_eq!(torbox.title, "TorBox");
        assert!(!torbox.check_adds_magnets);
        assert_eq!(torbox.max_files, 12);
        let realdebrid = catalog.iter().find(|service| service.id == "realdebrid").unwrap();
        assert!(realdebrid.check_adds_magnets, "probing Real-Debrid owns a magnet per answer");
    }

    #[test]
    fn every_error_kind_the_frontend_branches_on_has_a_name() {
        let kinds = [
            failure(DebridError::Auth { message: "k".into(), status: None, code: None }).kind,
            failure(DebridError::Network { message: "n".into() }).kind,
            failure(DebridError::Timeout { message: "t".into() }).kind,
            failure(DebridError::not_cached()).kind,
            failure(DebridError::unavailable()).kind,
            failure(DebridError::Rejected { message: "wrong pack".into() }).kind,
            failure(DebridError::Service { message: "s".into(), status: None, code: None }).kind,
        ];
        assert_eq!(
            kinds,
            ["auth", "network", "timeout", "not-cached", "unavailable", "rejected", "service"]
        );
    }
}
