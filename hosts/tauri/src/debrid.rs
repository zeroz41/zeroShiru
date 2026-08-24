//! Debrid IPC adapters. The frontend owns none of this any more: it asks for an
//! answer and gets one, while provider HTTP, availability memory, the account
//! listing, rate limits and pack picking all live in the shared crates.
//!
//! Provider instances are cached per (service, key) so that memory survives
//! across calls, mirroring the service lifecycle the JS layer used to have.

use serde::{Deserialize, Serialize};
use shiru_core::{parse_names, pick_episode_file, pick_pack, EpisodeNotInPack};
use shiru_debrid::manager::{create_provider, ManagedProvider, WatchEvent, PROVIDER_IDS};
use shiru_debrid::platform::NativePlatform;
use shiru_debrid::{DebridError, ResolveOptions};
use shiru_domain::{parse_hash, to_player_file, Availability, DebridResolved, PlayerFile};
use shiru_networking::NativeTransport;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::Emitter;

/// The event channel availability answers arrive on, so badges fill in as a sweep
/// goes rather than all at once when it ends.
const DEBRID_EVENT: &str = "shiru://debrid";

/// How many (service, key) providers stay warm at once. One slot was not enough: the
/// settings test button validating a different service evicted the live account's whole
/// state — availability memory, the listing cache, the orphan list, and any pause a 429
/// had installed — in the middle of whatever it was doing.
const PROVIDER_SLOTS: usize = 4;

/// Direct links are idempotent for a service torrent/file pair and expensive to ask for.
/// Keep successful windows long enough for re-clicks and stall recovery, but never so
/// long that an unprobed expired token becomes normal playback.
const RESOLVED_TTL: Duration = Duration::from_secs(15 * 60);
/// Bounds accounts/releases/windows held in memory.
const RESOLVED_SLOTS: usize = 64;

struct ResolvedEntry {
    service: String,
    api_key: String,
    hash: String,
    resolved: DebridResolved,
    stored_at: Instant,
}

#[derive(Default)]
struct ResolvedCache {
    /// Most recently used first. A large pack may have several windows cached around
    /// different episodes; any window containing the next episode is reusable.
    entries: VecDeque<ResolvedEntry>,
}

impl ResolvedCache {
    fn get(
        &mut self,
        service: &str,
        api_key: &str,
        hash: &str,
        episode: Option<f64>,
    ) -> Option<DebridResolved> {
        self.get_at(service, api_key, hash, episode, Instant::now())
    }

    fn get_at(
        &mut self,
        service: &str,
        api_key: &str,
        hash: &str,
        episode: Option<f64>,
        now: Instant,
    ) -> Option<DebridResolved> {
        self.entries.retain(|entry| now.saturating_duration_since(entry.stored_at) < RESOLVED_TTL);
        let found = self.entries.iter().position(|entry| {
            entry.service == service
                && entry.api_key == api_key
                && entry.hash == hash
                && retarget(&entry.resolved, episode).is_some()
        })?;
        let entry = self.entries.remove(found)?;
        let answer = retarget(&entry.resolved, episode);
        self.entries.push_front(entry);
        answer
    }

    fn insert(&mut self, service: &str, api_key: &str, resolved: DebridResolved) {
        self.insert_at(service, api_key, resolved, Instant::now());
    }

    fn insert_at(&mut self, service: &str, api_key: &str, resolved: DebridResolved, stored_at: Instant) {
        // Replace this link window, not every window for the hash: episode 100 of a
        // long pack can coexist with cached links around episode 1.
        self.entries.retain(|entry| {
            !(entry.service == service
                && entry.api_key == api_key
                && entry.hash == resolved.hash
                && entry.resolved.target == resolved.target)
        });
        self.entries.push_front(ResolvedEntry {
            service: service.to_string(),
            api_key: api_key.to_string(),
            hash: resolved.hash.clone(),
            resolved,
            stored_at,
        });
        self.entries.truncate(RESOLVED_SLOTS);
    }

    fn forget(&mut self, service: &str, api_key: &str, hash: &str) {
        self.entries.retain(|entry| {
            entry.service != service || entry.api_key != api_key || entry.hash != hash
        });
    }
}

/// Re-picks the requested episode from a cached link window. If the episode lies
/// outside it, the provider is asked for a new window instead.
fn retarget(resolved: &DebridResolved, episode: Option<f64>) -> Option<DebridResolved> {
    let Some(episode) = episode else { return Some(resolved.clone()) };
    let files: Vec<(String, u64)> = resolved.files.iter().map(|file| (file.path.clone(), file.size)).collect();
    // A cached window is not necessarily the whole release. `pick_pack` deliberately
    // turns a mismatch in <= max_files entries into Ok(None), because a provider handing
    // over a complete small release lets the player decide. Doing that to a cached slice
    // could hand episodes 1-12 to a request for episode 50, so cache lookup is strict.
    let target = match pick_episode_file(&files, episode, parse_names) {
        Ok(Some(index)) => resolved.files.get(index).map(|file| file.path.clone()),
        Ok(None) => resolved.target.clone(), // an unnumbered movie is intentionally unjudgeable
        Err(_) => return None,
    };
    Some(DebridResolved { target, ..resolved.clone() })
}

#[derive(Default)]
pub struct DebridState {
    /// Most recently used first.
    active: Mutex<Vec<(String, String, Arc<ManagedProvider>)>>,
    /// The running availability watch, if any. One at a time: a new results list
    /// supersedes the old one, and aborting mid-flight is safe — every claim the
    /// watch takes is released by a Drop guard in the crate.
    watch: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    /// Successful direct-link windows, scoped to the account whose links they contain.
    resolved: Mutex<ResolvedCache>,
}

impl DebridState {
    fn managed(&self, service: &str, api_key: &str) -> Result<Arc<ManagedProvider>, DebridFailure> {
        let mut active = self.active.lock().unwrap();
        if let Some(index) = active
            .iter()
            .position(|(known_service, known_key, _)| known_service == service && known_key == api_key)
        {
            let entry = active.remove(index);
            let managed = entry.2.clone();
            active.insert(0, entry);
            return Ok(managed);
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
        active.insert(0, (service.to_string(), api_key.to_string(), managed.clone()));
        while active.len() > PROVIDER_SLOTS {
            let (_, _, outgoing) = active.pop().expect("len checked");
            // whatever the outgoing account is still owed, it is owed on that account and
            // no other — a probe that dropped mid-flight left a magnet behind, and once
            // this provider is gone nothing else holds the id to take it off again
            if outgoing.client().orphaned() > 0 {
                tauri::async_runtime::spawn(async move { outgoing.provider().retry_cleanup().await });
            }
        }
        Ok(managed)
    }
}

/// One warm provider's health, as the diagnostics surface reports it.
#[derive(Serialize)]
pub struct ServiceHealth {
    pub service: String,
    /// The service recently spent a full budget answering nothing.
    pub quiet: bool,
    pub unanswered_timeouts: u64,
    /// Rolling round-trip estimate the budgets stretch against.
    pub latency_ms: u64,
    pub remembered_answers: usize,
    /// Removals the account is still owed by dropped calls.
    pub orphaned_removals: usize,
    /// A magnet-adding sweep owns the account right now.
    pub sweeping: bool,
    pub requests_in_flight: usize,
    pub requests_waiting: usize,
    /// A 429's pause, however much of it is left.
    pub paused_for_ms: u64,
}

impl DebridState {
    /// Every warm provider's health, most recently used first. Cheap reads only.
    pub fn health(&self) -> Vec<ServiceHealth> {
        self.active
            .lock()
            .unwrap()
            .iter()
            .map(|(service, _, managed)| {
                let health = managed.client().health();
                ServiceHealth {
                    service: service.clone(),
                    quiet: health.quiet,
                    unanswered_timeouts: health.unanswered_timeouts,
                    latency_ms: health.latency_ms,
                    remembered_answers: health.remembered_answers,
                    orphaned_removals: health.orphaned_removals,
                    sweeping: managed.sweeping(),
                    requests_in_flight: health.limiter.in_flight,
                    requests_waiting: health.limiter.waiting,
                    paused_for_ms: health.limiter.paused_for_ms,
                }
            })
            .collect()
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

fn kind_of(error: &DebridError) -> &'static str {
    match error {
        DebridError::Auth { .. } => "auth",
        DebridError::Network { .. } => "network",
        DebridError::Timeout { .. } => "timeout",
        DebridError::NotCached { .. } => "not-cached",
        DebridError::Unavailable { .. } => "unavailable",
        DebridError::Rejected { .. } => "rejected",
        DebridError::Service { .. } => "service",
    }
}

fn failure(error: DebridError) -> DebridFailure {
    DebridFailure { kind: kind_of(&error), message: error.to_string() }
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


/// Hashes as the results list actually has them: an entry a source could not give
/// an info hash for is a `null` in that array, and a strict `Vec<String>` rejects
/// the whole call over it — one hashless release would leave every badge on the
/// screen empty, silently, because the failure is not about any release. Anything
/// that is not a string is dropped and the rest of the list is still answered.
fn lenient_hashes<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    let raw = Vec::<serde_json::Value>::deserialize(deserializer)?;
    Ok(raw.into_iter().filter_map(|value| match value {
        serde_json::Value::String(hash) => Some(hash),
        _ => None,
    })
    .collect())
}

/// The hash arguments of a command, so the lenient reading is written once.
#[derive(Deserialize)]
pub struct Hashes(#[serde(deserialize_with = "lenient_hashes")] pub Vec<String>);

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
    let answers = managed
        .list_availability()
        .await
        .inspect_err(|error| tracing::warn!(target: "debrid", %service, %error, "account listing failed"))
        .map_err(failure)?;
    tracing::info!(target: "debrid", %service, held = answers.len(), "account listing");
    Ok(AvailabilityReply { answers, names: managed.client().release_names() })
}

/// Starts — or replaces — the availability watch for the current results list.
///
/// The crate owns the whole badge lifecycle: remembered answers first, a check round
/// for the rest, then patient backing-off retries for whatever the service left
/// unanswered. Everything is pushed as an event the moment it happens, and this
/// command returns as soon as the watch is running. The old JS loop did all of this
/// over three IPC round trips per attempt, with its own copy of the backoff policy.
#[tauri::command]
pub async fn debrid_watch_availability(
    app: tauri::AppHandle,
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    hashes: Hashes,
    request_id: Option<u64>,
) -> Result<(), DebridFailure> {
    let managed = state.managed(&service, &api_key)?;
    let Hashes(hashes) = hashes;
    // the previous list's watch is over before the new one starts, so two guarded
    // sweeps never overlap on one account
    if let Some(previous) = state.watch.lock().unwrap().take() {
        previous.abort();
    }
    let handle = tauri::async_runtime::spawn(async move {
        managed
            .watch_availability(&hashes, |event| {
                let payload = match event {
                    WatchEvent::Answer { hash, state, name } => serde_json::json!({
                        "type": "availability",
                        "data": { "hash": hash, "state": state, "name": name, "requestId": request_id }
                    }),
                    WatchEvent::Checking(active) => serde_json::json!({
                        "type": "checking",
                        "data": { "active": active, "requestId": request_id }
                    }),
                    WatchEvent::Outage(error) => serde_json::json!({
                        "type": "outage",
                        "data": { "kind": kind_of(error), "message": error.to_string(), "requestId": request_id }
                    }),
                };
                let _ = app.emit(DEBRID_EVENT, payload);
            })
            .await;
        let _ = app.emit(
            DEBRID_EVENT,
            serde_json::json!({ "type": "settled", "data": { "requestId": request_id } }),
        );
    });
    state.watch.lock().unwrap().replace(handle);
    Ok(())
}

/// Stops the running watch, because the results it described are no longer on screen.
#[tauri::command]
pub fn debrid_cancel_availability(state: tauri::State<'_, DebridState>) {
    if let Some(previous) = state.watch.lock().unwrap().take() {
        previous.abort();
    }
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
    let started = std::time::Instant::now();
    tracing::info!(target: "debrid", %service, ?episode, "resolve started");
    if let Some(hash) = parse_hash(&magnet) {
        if let Some(resolved) = state
            .resolved
            .lock()
            .unwrap()
            .get(&service, &api_key, &hash, episode)
        {
            tracing::info!(
                target: "debrid",
                %service,
                ?episode,
                elapsed_ms = started.elapsed().as_millis(),
                files = resolved.files.len(),
                "resolve completed from direct-link cache"
            );
            managed.client().remember(&resolved.hash, Availability::Cached);
            return Ok(resolved_reply(resolved));
        }
    }
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
    let resolved = managed.resolve(&magnet, &opts).await;
    let resolved = match resolved {
        Ok(resolved) => {
            tracing::info!(
                target: "debrid",
                %service,
                elapsed_ms = started.elapsed().as_millis(),
                files = resolved.files.len(),
                "resolve completed"
            );
            resolved
        }
        Err(error) => {
            tracing::warn!(
                target: "debrid",
                %service,
                elapsed_ms = started.elapsed().as_millis(),
                %error,
                "resolve failed"
            );
            return Err(failure(error));
        }
    };
    // the cached account listing is dropped by whichever provider added a torrent, at the
    // moment it added it — a resolve that streamed something already on the account
    // changed nothing, and paying for a fresh listing after every play is what put a
    // thousand-entry response on the play path in the first place
    // playing it proves the service holds it, which is the best answer there is
    managed.client().remember(&resolved.hash, Availability::Cached);
    state.resolved.lock().unwrap().insert(&service, &api_key, resolved.clone());
    Ok(resolved_reply(resolved))
}

/// Drops cached direct links after the frontend's byte probe proves one dead. Every
/// episode window for the release goes: an expired account token or CDN assignment can
/// affect more than the one file that happened to be played first.
#[tauri::command]
pub fn debrid_forget_resolved(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    hash: String,
) {
    let hash = parse_hash(&hash).unwrap_or_else(|| hash.to_ascii_lowercase());
    state.resolved.lock().unwrap().forget(&service, &api_key, &hash);
}

/// A resolved release, shaped the way the player takes files.
#[derive(Serialize)]
pub struct ResolvedReply {
    pub hash: String,
    pub name: String,
    pub files: Vec<PlayerFile>,
    /// Path of the file the resolve picked to play; the frontend probes and warms this
    /// one, since pack files land on different CDN nodes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

fn resolved_reply(resolved: DebridResolved) -> ResolvedReply {
    let files = resolved
        .files
        .iter()
        .map(|file| to_player_file(&resolved.hash, &resolved.name, file))
        .collect();
    ResolvedReply { hash: resolved.hash, name: resolved.name, files, target: resolved.target }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiru_domain::DebridFile;

    fn cached_resolved() -> DebridResolved {
        let files = (1..=3)
            .map(|episode| DebridFile {
                name: format!("Show - {episode:02}.mkv"),
                path: format!("/Show - {episode:02}.mkv"),
                size: 1_000 + episode,
                url: format!("https://cdn.test/{episode:02}"),
                r#type: None,
            })
            .collect();
        DebridResolved {
            hash: "a".repeat(40),
            name: "Show".into(),
            files,
            target: Some("/Show - 01.mkv".into()),
        }
    }

    #[test]
    fn watch_events_serialize_the_shapes_the_frontend_reads() {
        // the exact wire shapes: the frontend branches on `type` and reads `data`
        // fields by name, and every event carries the request id of its watch
        let answer = serde_json::json!({
            "type": "availability",
            "data": { "hash": "info-hash", "state": Availability::Cached, "name": "Show", "requestId": 42 }
        });
        assert_eq!(answer["data"]["state"], "cached", "availability serializes lowercase");
        assert_eq!(answer["data"]["requestId"], 42);
        let outage = serde_json::json!({
            "type": "outage",
            "data": { "kind": kind_of(&DebridError::Timeout { message: "t".into() }), "message": "t", "requestId": 42 }
        });
        assert_eq!(outage["data"]["kind"], "timeout");
    }

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

    #[test]
    fn resolved_links_are_reused_and_retargeted_only_inside_the_cached_window() {
        let now = Instant::now();
        let mut cache = ResolvedCache::default();
        cache.insert_at("torbox", "key", cached_resolved(), now);

        let episode_two = cache
            .get_at("torbox", "key", &"a".repeat(40), Some(2.0), now)
            .expect("episode two is already linked in this window");
        assert_eq!(episode_two.target.as_deref(), Some("/Show - 02.mkv"));
        assert!(
            cache.get_at("torbox", "key", &"a".repeat(40), Some(50.0), now).is_none(),
            "an episode outside the window must ask the provider for another window"
        );
        assert!(
            cache.get_at("torbox", "other-key", &"a".repeat(40), Some(2.0), now).is_none(),
            "account-bound links never cross accounts"
        );
    }

    #[test]
    fn dead_or_expired_resolved_links_leave_the_cache() {
        let now = Instant::now();
        let mut cache = ResolvedCache::default();
        cache.insert_at(
            "torbox",
            "key",
            cached_resolved(),
            now - RESOLVED_TTL - Duration::from_secs(1),
        );
        assert!(cache.get_at("torbox", "key", &"a".repeat(40), Some(1.0), now).is_none());

        cache.insert_at("torbox", "key", cached_resolved(), now);
        cache.forget("torbox", "key", &"a".repeat(40));
        assert!(cache.get_at("torbox", "key", &"a".repeat(40), Some(1.0), now).is_none());
    }
    #[test]
    fn a_results_list_holding_a_hashless_release_is_still_answered() {
        // exactly what reaches the command: `sortedResults.map(result => result.hash)`
        // over a list where one source could not name an info hash
        let payload = serde_json::json!([
            "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            null,
            "0795e58989ca49f7a2fb556c445e60c9f653be08"
        ]);
        let Hashes(hashes) = serde_json::from_value(payload).expect("one hashless entry cannot refuse the whole list");
        assert_eq!(hashes.len(), 2, "the releases that do have a hash are still asked about");

        let strict: Result<Vec<String>, _> = serde_json::from_value(serde_json::json!(["a", null]));
        assert!(strict.is_err(), "and this is what used to happen instead");
    }
}
