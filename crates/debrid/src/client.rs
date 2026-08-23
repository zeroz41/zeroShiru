//! The request machinery every provider shares: rate limiting, retries,
//! authentication schemes, body encoding, latency-stretched poll budgets,
//! availability memory and the account listing cache. Port of the stateful half of
//! common/modules/debrid/service.js.

use crate::error::DebridError;
use crate::limiter::{Limiter, Limits};
use crate::platform::Platform;
use crate::{AuthScheme, BodyEncoding, ProviderConfig};
use serde_json::Value;
use shiru_domain::{parse_hash, Availability, DebridFile};
use shiru_networking::{Body, HttpRequest, HttpResponse, HttpTransport, Method};
use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// How far a poll budget may stretch on a slow link.
const MAX_STRETCH: f64 = 3.0;

/// How many times a removal this client owes the account is retried before it is
/// written off. A service that will not take the removal is not worth asking forever.
const MAX_CLEANUP_ATTEMPTS: usize = 3;

/// How many times a request refused for going too fast is sent again.
const RATE_LIMIT_RETRIES: u32 = 2;

/// How long to wait out a `429` that arrived without a `retry-after` header.
const RATE_LIMIT_FALLBACK_MS: u64 = 5_000;

/// How long one unanswered round trip keeps the whole account treated as quiet.
///
/// TorBox wedges per endpoint: connections are accepted and never answered, for minutes,
/// while `curl` proves the server itself is up (2026-08-19 and again 2026-08-22 in the
/// user's own log). A resolve is a chain of round trips, and paying the full request
/// budget for every link in the chain against a service that just proved it is not
/// answering turned one play click into 30-60 seconds of spinner before the fallback
/// could even be offered. One full-budget timeout has already been paid — that is the
/// evidence — so while it is fresh, later requests only probe whether the service came
/// back, and the first answer of any kind clears the state instantly.
const QUIET_COOLDOWN_MS: u64 = 30_000;

/// The round-trip budget while the service is quiet. Not a verdict on the service — the
/// verdict was the full-budget timeout that installed the quiet state — just how long a
/// "did it come back yet" question is worth. Stretched by the measured link latency like
/// every other budget, so a slow connection is not mistaken for a quiet service.
const QUIET_PROBE_MS: u64 = 3_000;

/// The longest `retry-after` worth obeying. TorBox has answered a link-request burst
/// with `retry-after: 300`, and honouring it froze every request on the account —
/// playback included — for five minutes. Past this, failing fast beats waiting: the
/// error says what happened, and waiting less than asked would only collect another 429.
const RATE_LIMIT_MAX_WAIT_MS: u64 = 30_000;

/// How long to leave a request that timed out before trying it once more. A round trip
/// that never came back says nothing about the service, so it is worth one more ask —
/// unlike an unreachable one, where retrying only delays the error the app already knows.
const NETWORK_RETRY_DELAY_MS: u64 = 3_000;

/// How long the account listing is reused. Matched to the badge refresh interval: both
/// the badge sweep and every resolve want it, and reading it per play put a full account
/// listing on the play path.
const LISTING_TTL_MS: u64 = 60_000;

/// Per-request overrides, mirroring the JS request options object.
#[derive(Default, Clone)]
pub struct RequestOpts {
    pub method: Option<Method>,
    /// Key/value body fields; arrays become repeated keys, as `name[]` params are read.
    pub body: Option<Vec<(String, Value)>>,
    pub encoding: Option<BodyEncoding>,
    pub auth: Option<AuthScheme>,
    pub auth_param: Option<&'static str>,
    pub timeout_ms: Option<u64>,
}

/// A diagnostic view of one debrid client, answering "why is this slow / broken"
/// without a debugger attached. Plain data; hosts serialize it for their IPC.
#[derive(Debug, Clone, Copy)]
pub struct ClientHealth {
    /// The service recently spent a full budget answering nothing, and has not spoken since.
    pub quiet: bool,
    /// Round trips in a row that never came back.
    pub unanswered_timeouts: u64,
    /// Rolling round-trip estimate, 0 until the first answer. Budgets stretch against it.
    pub latency_ms: u64,
    /// Availability answers held in memory.
    pub remembered_answers: usize,
    /// Removals the account is still owed (see OrphanOnDrop).
    pub orphaned_removals: usize,
    pub limiter: crate::limiter::LimiterHealth,
}

/// A provider's response conventions: how envelopes unwrap and how errors map.
pub trait Dialect: Send + Sync {
    /// Unpacks a successful response body. Providers whose APIs report failures
    /// inside a 200 throw from here, routing them through the same typed errors.
    fn unwrap(&self, json: Value) -> Result<Value, DebridError> {
        Ok(json)
    }

    /// Maps an HTTP error response to a typed error.
    fn map_error(&self, status: u16, json: Option<&Value>) -> DebridError {
        let message = json
            .and_then(|value| value.get("error").or_else(|| value.get("message")))
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| format!("Request failed with status {status}"));
        let code = json
            .and_then(|value| value.get("error_code"))
            .map(|value| value.to_string());
        if status == 401 || status == 403 {
            DebridError::Auth { message, status: Some(status), code }
        } else {
            DebridError::Service { message, status: Some(status), code }
        }
    }
}

/// Default dialect: plain JSON bodies, standard status-code mapping.
pub struct PlainDialect;
impl Dialect for PlainDialect {}

pub struct DebridClient {
    pub config: ProviderConfig,
    api_key: String,
    transport: Arc<dyn HttpTransport>,
    platform: Arc<dyn Platform>,
    /// Rolling estimate of one round trip, 0 until the first answer.
    latency: AtomicU64,
    /// Round trips in a row that never came back, and when the last one gave up.
    /// Together they say whether the service is quiet right now; see QUIET_COOLDOWN_MS.
    quiet_timeouts: AtomicU64,
    quiet_at: AtomicU64,
    /// What the service has already said about a hash, with when it said it.
    availability: Mutex<HashMap<String, (Availability, u64)>>,
    /// The real release name behind a hash, as the service knows it.
    release_names: Mutex<HashMap<String, String>>,
    /// Removals that failed, to try again. Keyed by the whole request, since services
    /// that name the torrent in the body would otherwise all collide on one url.
    orphans: Mutex<HashMap<String, (String, RequestOpts, usize)>>,
    /// Everything this account sends goes through here, so a season pack's worth of
    /// link requests can go out together without tripping the service's allowance.
    limiter: Limiter,
    /// The account's own torrent listing, read at most once per `LISTING_TTL_MS` and
    /// shared by every caller. An async lock rather than a plain one, so a second
    /// caller arriving mid-read waits for that read instead of starting another —
    /// which is what the JS got from sharing the promise.
    listing: futures::lock::Mutex<Option<(u64, Value)>>,
}

impl DebridClient {
    pub fn new(
        config: ProviderConfig,
        api_key: String,
        transport: Arc<dyn HttpTransport>,
        platform: Arc<dyn Platform>,
    ) -> Self {
        let limiter = Limiter::new(Limits {
            max_concurrent: config.max_concurrent,
            min_time_ms: config.min_time_ms,
            reservoir: config.reservoir,
        });
        DebridClient {
            config,
            api_key,
            transport,
            platform,
            latency: AtomicU64::new(0),
            quiet_timeouts: AtomicU64::new(0),
            quiet_at: AtomicU64::new(0),
            availability: Mutex::new(HashMap::new()),
            release_names: Mutex::new(HashMap::new()),
            orphans: Mutex::new(HashMap::new()),
            limiter,
            listing: futures::lock::Mutex::new(None),
        }
    }

    pub fn platform(&self) -> &dyn Platform {
        self.platform.as_ref()
    }

    /// Applies the service's authentication scheme. Some APIs authenticate one odd
    /// endpoint differently, hence the per-request override.
    fn authorize(&self, url: &str, auth: AuthScheme, auth_param: &str) -> (String, Vec<(String, String)>) {
        match auth {
            AuthScheme::Bearer => (
                url.to_string(),
                vec![("Authorization".into(), format!("Bearer {}", self.api_key))],
            ),
            AuthScheme::Query => {
                let separator = if url.contains('?') { '&' } else { '?' };
                (format!("{url}{separator}{auth_param}={}", self.api_key), vec![])
            }
        }
    }

    /// Encodes a request body. An array value becomes the same key repeated per item.
    fn encode_body(fields: &[(String, Value)], encoding: BodyEncoding) -> Body {
        match encoding {
            BodyEncoding::Json => {
                let map: serde_json::Map<String, Value> =
                    fields.iter().cloned().collect();
                Body::Bytes {
                    content_type: "application/json".into(),
                    bytes: serde_json::to_vec(&Value::Object(map)).unwrap_or_default(),
                }
            }
            BodyEncoding::Multipart => Body::Multipart(flatten(fields)),
            BodyEncoding::Form => {
                let encoded = flatten(fields)
                    .into_iter()
                    .map(|(key, value)| format!("{}={}", urlencode(&key), urlencode(&value)))
                    .collect::<Vec<_>>()
                    .join("&");
                Body::Bytes {
                    content_type: "application/x-www-form-urlencoded".into(),
                    bytes: encoded.into_bytes(),
                }
            }
        }
    }

    /// One authenticated request, paced against the service's allowance and retried
    /// where retrying is what the service asked for.
    ///
    /// Two failures are worth another go and nothing else is. A `429` is the service
    /// saying "not that fast", which is a request about timing rather than a verdict
    /// on the request — so it waits out the `retry-after` (pausing every other request
    /// on the account with it, since they would only collect their own 429) and asks
    /// again, unless the wait it asked for is longer than anyone should sit through. A
    /// timeout is a round trip that never came back, which says nothing at all, so it
    /// gets exactly one more. Everything else — auth, a 500, an unreachable host — is
    /// an answer, and repeating the question does not improve it.
    pub async fn request(&self, dialect: &dyn Dialect, url: &str, opts: RequestOpts) -> Result<Value, DebridError> {
        if self.api_key.is_empty() {
            return Err(DebridError::Auth { message: "No debrid API key configured".into(), status: None, code: None });
        }
        let mut rate_limited = 0;
        let mut timed_out = 0;
        // whether the service was already known-quiet before this call spent anything.
        // If so, a timeout here is confirmation rather than news, and the one-more-ask
        // retry below is skipped — it is what turned a wedged service into a chain of
        // full-budget waits, one per round trip of a resolve
        let quiet_at_entry = self.quiet();
        loop {
            // the permit lives exactly as long as the round trip, so a request that
            // failed hands its place back before anything waits on the retry
            let outcome = {
                let _permit = self.limiter.acquire(self.platform.as_ref()).await;
                self.attempt(dialect, url, &opts).await
            };
            let (error, retry_after) = match outcome {
                Ok(value) => return Ok(value),
                Err(failure) => failure,
            };
            if error.throttled() && rate_limited < RATE_LIMIT_RETRIES {
                let wait = retry_after.map(|seconds| seconds * 1_000).unwrap_or(RATE_LIMIT_FALLBACK_MS);
                if wait > RATE_LIMIT_MAX_WAIT_MS {
                    tracing::warn!(target: "debrid", service = self.config.id, wait, "rate limited for longer than is worth waiting out");
                    return Err(error);
                }
                tracing::debug!(target: "debrid", service = self.config.id, wait, "rate limited, holding every request on this account");
                self.limiter.pause_for(self.platform.as_ref(), wait);
                self.platform.sleep(wait).await;
                rate_limited += 1;
                continue;
            }
            if matches!(error, DebridError::Timeout { .. }) && timed_out < 1 && !quiet_at_entry {
                self.platform.sleep(NETWORK_RETRY_DELAY_MS).await;
                timed_out += 1;
                continue;
            }
            return Err(error);
        }
    }

    /// One authenticated round trip, with the provider's error conventions applied.
    /// Reports the `retry-after` alongside the error, because only the caller above
    /// knows whether this request has any retries left to spend on it.
    async fn attempt(
        &self,
        dialect: &dyn Dialect,
        url: &str,
        opts: &RequestOpts,
    ) -> Result<Value, (DebridError, Option<u64>)> {
        let opts = opts.clone();
        let auth = opts.auth.unwrap_or(self.config.auth);
        let auth_param = opts.auth_param.unwrap_or(self.config.auth_param);
        let (authorized_url, headers) = self.authorize(url, auth, auth_param);
        let body = opts
            .body
            .as_ref()
            .map(|fields| Self::encode_body(fields, opts.encoding.unwrap_or(self.config.encoding)));
        let mut timeout_ms = opts.timeout_ms.unwrap_or(self.config.timeouts.request);
        // while the service is quiet the full budget has already been paid once; this
        // round trip only asks whether it came back
        if self.quiet() {
            timeout_ms = timeout_ms.min(self.budget(QUIET_PROBE_MS));
        }
        let request = HttpRequest {
            method: opts.method.unwrap_or(Method::Get),
            url: authorized_url,
            headers: headers.into_iter().collect(),
            body,
            timeout_ms,
        };
        let sent = self.platform.now_ms();
        let response = self
            .transport
            .execute(request)
            .await
            .map_err(|error| match error {
                shiru_networking::TransportError::Timeout(ms) => {
                    // an unanswered round trip is the evidence the quiet state runs on
                    let strikes = self.quiet_timeouts.fetch_add(1, Ordering::Relaxed) + 1;
                    self.quiet_at.store(self.platform.now_ms(), Ordering::Relaxed);
                    if strikes == 1 {
                        tracing::warn!(target: "debrid", service = self.config.id, budget_ms = timeout_ms, "service went quiet: a full budget passed with no answer; later requests will only probe");
                    }
                    DebridError::Timeout { message: format!("request timed out after {ms}ms") }
                }
                shiru_networking::TransportError::Network(message) => DebridError::Network { message },
            })
            .map_err(|error| (error, None))?;
        // only round trips that came back, so a timeout cannot inflate it
        self.observe_latency(self.platform.now_ms().saturating_sub(sent));
        // any answer at all — even an error status — is the service talking again
        if self.quiet_timeouts.swap(0, Ordering::Relaxed) > 0 {
            tracing::info!(target: "debrid", service = self.config.id, "service is answering again");
        }
        self.finish(dialect, response)
    }

    fn finish(
        &self,
        dialect: &dyn Dialect,
        response: HttpResponse,
    ) -> Result<Value, (DebridError, Option<u64>)> {
        if !response.ok() {
            let json: Option<Value> = serde_json::from_slice(&response.body).ok();
            let error = dialect.map_error(response.status, json.as_ref());
            // a retry-after in seconds; anything else (an HTTP date, junk) reads as absent
            // and the caller falls back to its own wait
            let retry_after = (response.status == 429)
                .then(|| response.header("retry-after").and_then(|value| value.trim().parse::<u64>().ok()))
                .flatten();
            return Err((error, retry_after));
        }
        if response.status == 204 || response.body.is_empty() {
            return Ok(Value::Null);
        }
        let json: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
        dialect.unwrap(json).map_err(|error| (error, None))
    }

    /// The account's own torrent listing, read at most once per TTL and shared by every
    /// caller. Both the badge refresh and every resolve want it, and reading it per play
    /// put a full account listing on the play path — on TorBox that is a thousand-entry
    /// response before the first link request even goes out. An entry can be a minute
    /// stale, so callers confirm one before acting on its id.
    ///
    /// `fresh` forces a read, for polling a change just made.
    pub async fn listing<F, Fut>(&self, fresh: bool, fetch: F) -> Result<Value, DebridError>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Value, DebridError>>,
    {
        let mut known = self.listing.lock().await;
        if !fresh {
            if let Some((at, listing)) = known.as_ref() {
                if self.platform.now_ms().saturating_sub(*at) < LISTING_TTL_MS {
                    return Ok(listing.clone());
                }
            }
        }
        // a failed read is never remembered: the next caller asks again rather than
        // inheriting a failure for a minute
        let listing = fetch().await?;
        *known = Some((self.platform.now_ms(), listing.clone()));
        Ok(listing)
    }

    /// Drops the remembered listing, because the account just changed.
    pub async fn forget_listing(&self) {
        *self.listing.lock().await = None;
    }

    /// Replaces or appends one entry in the remembered listing, for when the account
    /// changed by exactly that entry. Forgetting instead means the next resolve pays a
    /// thousand-entry re-read for a change this client just made and can describe —
    /// which put that read back on the play path, ahead of the links the user is
    /// waiting for. `same` says whether two entries describe the same torrent.
    pub async fn amend_listing(&self, entry: Value, same: impl Fn(&Value, &Value) -> bool) {
        let mut known = self.listing.lock().await;
        if let Some((_, listing)) = known.as_mut() {
            if let Some(items) = listing.as_array_mut() {
                if let Some(existing) = items.iter_mut().find(|item| same(item, &entry)) {
                    *existing = entry;
                } else {
                    items.push(entry);
                }
            }
        }
        // nothing remembered is nothing to amend: the next read pays for itself anyway
    }

    /// Undoes something this client created on the account. Never fails: it runs from
    /// error paths, where it would mask the real failure. A removal that fails is
    /// remembered and retried, because the likeliest cause is the link dropping — and a
    /// magnet left behind is the one trace an availability check can leave on an account.
    pub async fn release(&self, dialect: &dyn Dialect, url: &str, opts: RequestOpts) {
        let key = Self::request_key(url, &opts);
        let outcome = self.request(dialect, url, opts.clone()).await;
        let mut orphans = self.orphans.lock().unwrap();
        match outcome {
            // gone is what we wanted, however it got that way
            Ok(_) => {
                orphans.remove(&key);
            }
            Err(error) if error.status() == Some(404) => {
                orphans.remove(&key);
            }
            Err(_) => {
                let attempts = orphans.get(&key).map(|(_, _, tries)| *tries).unwrap_or(0) + 1;
                if attempts < MAX_CLEANUP_ATTEMPTS {
                    orphans.insert(key, (url.to_string(), opts, attempts));
                } else {
                    orphans.remove(&key);
                }
            }
        }
    }

    /// Identifies one removal: services name the torrent in the url or in the body,
    /// and two different torrents must never look like the same outstanding removal.
    fn request_key(url: &str, opts: &RequestOpts) -> String {
        match &opts.body {
            Some(fields) => format!("{url}|{fields:?}"),
            None => url.to_string(),
        }
    }

    /// How many removals are still outstanding.
    pub fn orphaned(&self) -> usize {
        self.orphans.lock().unwrap().len()
    }

    /// Whether the service is quiet right now: a round trip recently spent its whole
    /// budget without an answer, and nothing has answered since. Requests made in this
    /// state are short probes rather than full-budget waits.
    pub fn quiet(&self) -> bool {
        self.quiet_timeouts.load(Ordering::Relaxed) > 0
            && self.platform.now_ms().saturating_sub(self.quiet_at.load(Ordering::Relaxed)) < QUIET_COOLDOWN_MS
    }

    /// Everything worth knowing about this client's health in one read, for the
    /// diagnostics surface. Cheap: atomics and two short lock holds.
    pub fn health(&self) -> ClientHealth {
        ClientHealth {
            quiet: self.quiet(),
            unanswered_timeouts: self.quiet_timeouts.load(Ordering::Relaxed),
            latency_ms: self.latency.load(Ordering::Relaxed),
            remembered_answers: self.availability.lock().unwrap().len(),
            orphaned_removals: self.orphaned(),
            limiter: self.limiter.snapshot(self.platform.as_ref()),
        }
    }

    /// Records a removal the account is owed without sending it, for cleanup paths that
    /// cannot make a request — a future dropped mid-resolve has only its `Drop` to speak
    /// from. The next `retry_cleanup` sends it like any other outstanding removal.
    pub fn note_orphan(&self, url: String, opts: RequestOpts) {
        let key = Self::request_key(&url, &opts);
        self.orphans.lock().unwrap().insert(key, (url, opts, 0));
    }

    /// Retries removals that failed earlier. Only ever replays a removal `release` was
    /// already asked to make, so it can no more reach a torrent the user wanted than the
    /// original call could. Never persisted: a stale id would eventually name something else.
    pub async fn retry_cleanup(&self, dialect: &dyn Dialect) {
        let pending: Vec<(String, RequestOpts)> = {
            let orphans = self.orphans.lock().unwrap();
            orphans.values().map(|(url, opts, _)| (url.clone(), opts.clone())).collect()
        };
        for (url, opts) in pending {
            self.release(dialect, &url, opts).await;
        }
    }

    /// Folds one round trip into the latency estimate, weighted towards recent requests.
    fn observe_latency(&self, ms: u64) {
        let known = self.latency.load(Ordering::Relaxed);
        let next = if known == 0 { ms } else { (known * 7 + ms * 3) / 10 };
        self.latency.store(next, Ordering::Relaxed);
    }

    /// A poll budget stretched to fit the connection in use, up to MAX_STRETCH. The
    /// defaults are written for a healthy link; on a slow one the same budget buys a
    /// single request, so every poll loop times out and reports no answer.
    pub fn budget(&self, base_ms: u64) -> u64 {
        let latency = self.latency.load(Ordering::Relaxed) as f64;
        let stretch = (latency / self.config.nominal_latency as f64).clamp(1.0, MAX_STRETCH);
        (base_ms as f64 * stretch).round() as u64
    }

    /// Records what is known about a release so later checks are free. Unknown is not
    /// an answer, so recording it forgets what was there.
    pub fn remember(&self, magnet_or_hash: &str, state: Availability) {
        let Some(hash) = parse_hash(magnet_or_hash) else { return };
        let mut known = self.availability.lock().unwrap();
        if state == Availability::Unknown {
            known.remove(&hash);
        } else {
            known.insert(hash, (state, self.platform.now_ms()));
        }
    }

    /// A remembered answer that has not expired, or `None` when the hash needs asking about.
    pub fn recall(&self, hash: &str) -> Option<Availability> {
        let mut known = self.availability.lock().unwrap();
        let (state, at) = *known.get(hash)?;
        let age = self.platform.now_ms().saturating_sub(at);
        if age < state.ttl().as_millis() as u64 {
            Some(state)
        } else {
            known.remove(hash); // stale, ask again
            None
        }
    }

    /// Records the real name of a release, whenever the service happens to mention one.
    pub fn remember_release(&self, magnet_or_hash: &str, name: &str) {
        if name.is_empty() {
            return;
        }
        if let Some(hash) = parse_hash(magnet_or_hash) {
            self.release_names.lock().unwrap().insert(hash, name.to_string());
        }
    }

    /// Every release name the service has mentioned so far, keyed by info hash.
    /// Free information: it rides along on answers the client already asks for.
    pub fn release_names(&self) -> HashMap<String, String> {
        self.release_names.lock().unwrap().clone()
    }

    /// The service's own name for a release, or `None` when it has never mentioned one.
    pub fn release_name(&self, magnet_or_hash: &str) -> Option<String> {
        let hash = parse_hash(magnet_or_hash)?;
        self.release_names.lock().unwrap().get(&hash).cloned()
    }

    /// Lowercase, deduplicated hashes, order preserved, stopping at `limit`.
    pub fn normalize_hashes(magnets_or_hashes: &[String], limit: usize) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mut hashes = Vec::new();
        for entry in magnets_or_hashes {
            if let Some(hash) = parse_hash(entry) {
                if seen.insert(hash.clone()) {
                    hashes.push(hash);
                    if hashes.len() >= limit {
                        break;
                    }
                }
            }
        }
        hashes
    }
}

/// Arms a removal that fires only if the surrounding future dies without disarming it.
///
/// A Tauri command being cancelled, a webview reload, the resolve budget expiring — all
/// of them drop the provider's future wherever it happens to be awaiting. A future
/// dropped between "magnet added to the account" and "cleanup ran" used to leave that
/// torrent on the account with nothing tracking it. This guard is created the moment an
/// add succeeds and disarmed on every path that takes responsibility another way; if it
/// drops still armed, the removal lands in the client's orphan list, which the next
/// sweep retries before adding anything new.
pub struct OrphanOnDrop<'a> {
    client: &'a DebridClient,
    requests: Vec<(String, RequestOpts)>,
}

impl<'a> OrphanOnDrop<'a> {
    pub fn unarmed(client: &'a DebridClient) -> Self {
        OrphanOnDrop { client, requests: Vec::new() }
    }

    /// Arms the guard with a request that would undo something just created. A guard can
    /// owe several removals at once — a batch check uploads a whole list of magnets.
    pub fn arm(&mut self, url: String, opts: RequestOpts) {
        self.requests.push((url, opts));
    }

    /// Stands the guard down: the caller is taking responsibility for cleanup itself,
    /// or the created thing is meant to outlive the call (a successful resolve).
    pub fn disarm(&mut self) {
        self.requests.clear();
    }
}

impl Drop for OrphanOnDrop<'_> {
    fn drop(&mut self) {
        for (url, opts) in self.requests.drain(..) {
            tracing::debug!(target: "debrid", service = self.client.config.id, "a dropped call left a torrent behind; its removal is now owed");
            self.client.note_orphan(url, opts);
        }
    }
}

/// Turns candidates into stream links, skipping ones the service cannot serve — packs
/// do contain dead files, and one must not fail the whole resolve. Auth failures still
/// abort, since every other link would fail the same way. Port of the JS base class's
/// `mapFiles`.
///
/// Concurrent, and deliberately so. Sending a pack's links one at a time costs a full
/// round trip each before playback can start; sending them together costs one, and the
/// limiter — not this function — is what keeps that inside the service's allowance.
/// `join_all` polls in order, so the first candidate is the first to take a slot, which
/// is how providers put the episode the user actually asked for at the front of the queue.
pub async fn map_files<'a, T, F, Fut>(candidates: &'a [T], to_file: F) -> Result<Vec<DebridFile>, DebridError>
where
    F: Fn(&'a T) -> Fut,
    Fut: Future<Output = Result<Option<DebridFile>, DebridError>>,
{
    let attempts = futures::future::join_all(candidates.iter().map(&to_file)).await;
    let mut files = Vec::with_capacity(attempts.len());
    for attempt in attempts {
        match attempt {
            Ok(Some(file)) => files.push(file),
            Ok(None) => {}
            Err(error @ DebridError::Auth { .. }) => return Err(error),
            Err(error) => tracing::debug!(target: "debrid", %error, "skipping a file the service would not link"),
        }
    }
    Ok(files)
}

fn flatten(fields: &[(String, Value)]) -> Vec<(String, String)> {
    let mut flat = Vec::new();
    for (key, value) in fields {
        match value {
            Value::Array(items) => {
                for item in items {
                    flat.push((key.clone(), scalar(item)));
                }
            }
            other => flat.push((key.clone(), scalar(other))),
        }
    }
    flat
}

fn scalar(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

fn urlencode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// What the client does on a bad connection — the case the JS layer was getting wrong.
///
/// Measured on a satellite link, one request took about a second, so a probe cost five or
/// six seconds and a torrent whose metadata the service did not already hold burned the
/// whole budget and reported no answer. Three of those in a row ended a sweep and nothing
/// asked again, which left results lists with two badges on them. The fixes pinned here:
/// time limits that follow the connection rather than assuming one, and a link failure that
/// never turns into an answer about a release.
#[cfg(test)]
mod connection {
    use super::*;
    use crate::testing::{ManualClock, MockTransport, Route};
    use crate::providers::torbox::TorBox;
    use crate::{DebridProvider, Timeouts};

    fn client() -> DebridClient {
        let config = crate::ProviderConfig {
            id: "test",
            title: "Test",
            auth: AuthScheme::Bearer,
            auth_param: "apikey",
            encoding: BodyEncoding::Form,
            timeouts: Timeouts::default(),
            nominal_latency: 300,
            max_files: 60,
            availability_check: crate::AvailabilityCheck::None,
            check_adds_magnets: false,
            max_batch: 100,
            max_probes: 10,
            max_concurrent: 4,
            min_time_ms: 250,
            reservoir: None,
        };
        DebridClient::new(
            config,
            "key".into(),
            Arc::new(MockTransport::new(vec![])),
            Arc::new(ManualClock::new()),
        )
    }

    const READY: u64 = 5_000; // Timeouts::default().ready

    /// A client on a scripted transport with a hand-advanced clock, both shared back.
    fn wired() -> (DebridClient, Arc<MockTransport>, Arc<ManualClock>) {
        let transport = Arc::new(MockTransport::new(vec![]));
        let clock = Arc::new(ManualClock::new());
        let config = crate::ProviderConfig {
            id: "test",
            title: "Test",
            auth: AuthScheme::Bearer,
            auth_param: "apikey",
            encoding: BodyEncoding::Form,
            timeouts: Timeouts::default(),
            nominal_latency: 300,
            max_files: 60,
            availability_check: crate::AvailabilityCheck::None,
            check_adds_magnets: false,
            max_batch: 100,
            max_probes: 10,
            max_concurrent: 4,
            min_time_ms: 250,
            reservoir: None,
        };
        let client = DebridClient::new(config, "key".into(), transport.clone(), clock.clone());
        (client, transport, clock)
    }

    /// The timeout each recorded request went out with, in order.
    fn sent_budgets(transport: &MockTransport) -> Vec<u64> {
        transport.requests.lock().unwrap().iter().map(|request| request.timeout_ms).collect()
    }

    // --- the quiet state: what one unanswered round trip is allowed to cost the next ---
    //
    // TorBox wedges per endpoint — connections accepted, nothing answered — and a resolve
    // is a chain of round trips. In the user's log (2026-08-22) one play click spent
    // 30-60s of spinner paying the full budget for every link of that chain against a
    // service that had already proven it was not answering.

    #[tokio::test]
    async fn a_full_budget_timeout_makes_later_requests_probes_rather_than_waits() {
        let (client, transport, _) = wired();
        transport.rescript(vec![Route::timeout("wedged", 30_000)]);
        let error = client.request(&PlainDialect, "https://api/wedged", RequestOpts::default()).await.unwrap_err();
        assert!(matches!(error, DebridError::Timeout { .. }));
        let budgets = sent_budgets(&transport);
        assert_eq!(budgets.len(), 2, "the first offender still gets its one more ask");
        assert_eq!(budgets[0], 30_000, "the first ask pays the full budget — that is the evidence");
        assert_eq!(budgets[1], 3_000, "the retry only probes whether the service came back");

        // the service is now known quiet: a different request gets one probe, no retry
        let error = client.request(&PlainDialect, "https://api/wedged", RequestOpts::default()).await.unwrap_err();
        assert!(matches!(error, DebridError::Timeout { .. }));
        let budgets = sent_budgets(&transport);
        assert_eq!(budgets.len(), 3, "confirming a known-quiet service is one request, not a full-budget chain");
        assert_eq!(budgets[2], 3_000);
    }

    #[tokio::test]
    async fn an_answer_of_any_kind_ends_the_quiet_state() {
        let (client, transport, _) = wired();
        transport.rescript(vec![
            Route::timeout("wedged", 30_000),
            Route::json("healthy", 500, r#"{"error":"the disk fell over"}"#),
        ]);
        client.request(&PlainDialect, "https://api/wedged", RequestOpts::default()).await.unwrap_err();
        assert!(client.quiet());
        // a 500 is a bad answer, but it is an answer: the service is talking again
        client.request(&PlainDialect, "https://api/healthy", RequestOpts::default()).await.unwrap_err();
        assert!(!client.quiet());
        client.request(&PlainDialect, "https://api/wedged", RequestOpts::default()).await.unwrap_err();
        let budgets = sent_budgets(&transport);
        assert_eq!(
            &budgets[3..],
            &[30_000, 3_000],
            "after an answer, the next timeout is news again and gets the full treatment"
        );
    }

    #[tokio::test]
    async fn the_quiet_state_expires_when_the_evidence_goes_stale() {
        let (client, transport, clock) = wired();
        transport.rescript(vec![Route::timeout("wedged", 30_000)]);
        client.request(&PlainDialect, "https://api/wedged", RequestOpts::default()).await.unwrap_err();
        assert!(client.quiet());
        clock.advance(31_000);
        assert!(!client.quiet(), "a timeout half a minute ago says nothing about the service now");
    }

    #[tokio::test]
    async fn a_slow_link_stretches_the_quiet_probe_like_every_other_budget() {
        let (client, transport, _) = wired();
        for _ in 0..20 {
            client.observe_latency(900); // three times what the defaults assume
        }
        transport.rescript(vec![Route::timeout("wedged", 30_000)]);
        client.request(&PlainDialect, "https://api/wedged", RequestOpts::default()).await.unwrap_err();
        let budgets = sent_budgets(&transport);
        assert_eq!(budgets[1], 9_000, "a slow connection must not be mistaken for a quiet service");
    }

    #[test]
    fn a_healthy_link_gets_the_time_limits_as_written() {
        let client = client();
        assert_eq!(client.budget(READY), READY, "nothing measured yet, so nothing to correct for");
        client.observe_latency(300);
        assert_eq!(client.budget(READY), READY);
        client.observe_latency(10);
        assert_eq!(client.budget(READY), READY, "a fast link is not given a shorter budget than the default");
    }

    #[test]
    fn a_slow_link_stretches_them_so_a_poll_loop_still_gets_its_turns() {
        let client = client();
        for _ in 0..20 {
            client.observe_latency(900); // three times what the defaults assume
        }
        assert!(
            client.budget(READY) > READY * 2,
            "900ms round trips must buy more than double, got {}ms",
            client.budget(READY)
        );
    }

    #[test]
    fn but_only_so_far_since_a_link_that_slow_is_not_one_to_keep_waiting_on() {
        let client = client();
        for _ in 0..40 {
            client.observe_latency(30_000);
        }
        assert!(client.budget(READY) <= READY * 3, "the stretch is capped");
    }

    #[test]
    fn the_estimate_follows_the_link_rather_than_the_worst_moment_it_ever_had() {
        let client = client();
        client.observe_latency(200);
        client.observe_latency(5_000); // one bad request
        let spike = client.latency.load(Ordering::Relaxed);
        for _ in 0..10 {
            client.observe_latency(200);
        }
        assert!(
            client.latency.load(Ordering::Relaxed) < spike / 2,
            "a recovered link is noticed within a few requests"
        );
    }

    #[tokio::test]
    async fn a_request_that_never_came_back_does_not_inflate_the_estimate() {
        let clock = Arc::new(ManualClock::new());
        let transport = Arc::new(MockTransport::new(vec![Route::timeout("slow", 30_000)]));
        let client = DebridClient::new(client().config, "key".into(), transport, clock);
        let error = client.request(&PlainDialect, "https://api/slow", RequestOpts::default()).await.unwrap_err();
        assert!(matches!(error, DebridError::Timeout { .. }));
        assert_eq!(client.budget(READY), READY, "a timeout is not a measurement of the link");
    }

    #[tokio::test]
    async fn a_dropped_link_is_a_network_error_not_a_verdict_on_the_release() {
        let transport = Arc::new(MockTransport::new(vec![Route::offline("anything")]));
        let client = DebridClient::new(client().config, "key".into(), transport, Arc::new(ManualClock::new()));
        let error = client.request(&PlainDialect, "https://api/anything", RequestOpts::default()).await.unwrap_err();
        assert!(matches!(error, DebridError::Network { .. }));
        assert_eq!(error.proven_availability(), None, "an unreachable service has said nothing about the release");
    }

    #[tokio::test]
    async fn a_removal_that_failed_is_remembered_and_retried_once_the_link_is_back() {
        let transport = Arc::new(MockTransport::new(vec![Route::offline("delete")]));
        let client = DebridClient::new(client().config, "key".into(), transport.clone(), Arc::new(ManualClock::new()));
        let opts = RequestOpts { method: Some(Method::Delete), ..Default::default() };

        client.release(&PlainDialect, "https://api/delete/abc", opts.clone()).await;
        assert_eq!(client.orphaned(), 1, "a torrent this client added and could not remove must be remembered");

        transport.rescript(vec![Route::json("delete", 200, "{}")]);
        client.retry_cleanup(&PlainDialect).await;
        assert_eq!(client.orphaned(), 0, "and taken off the account once the link is back");
        assert!(transport.urls().len() > 1, "which means it really was asked again");
    }

    #[tokio::test]
    async fn a_removal_the_service_says_is_already_gone_is_not_retried() {
        let transport = Arc::new(MockTransport::new(vec![Route::json("delete", 404, r#"{"error":"unknown"}"#)]));
        let client = DebridClient::new(client().config, "key".into(), transport, Arc::new(ManualClock::new()));
        let opts = RequestOpts { method: Some(Method::Delete), ..Default::default() };
        client.release(&PlainDialect, "https://api/delete/abc", opts).await;
        assert_eq!(client.orphaned(), 0, "gone is what was wanted, however it got that way");
    }

    #[tokio::test]
    async fn a_removal_that_keeps_being_refused_is_eventually_written_off() {
        let transport = Arc::new(MockTransport::new(vec![Route::json("delete", 500, r#"{"error":"server"}"#)]));
        let client = DebridClient::new(client().config, "key".into(), transport, Arc::new(ManualClock::new()));
        let opts = RequestOpts { method: Some(Method::Delete), ..Default::default() };
        client.release(&PlainDialect, "https://api/delete/abc", opts).await;
        for _ in 0..5 {
            client.retry_cleanup(&PlainDialect).await;
        }
        assert_eq!(client.orphaned(), 0, "a service that will not take the removal is not worth asking forever");
    }

    #[tokio::test]
    async fn two_removals_at_the_same_endpoint_are_two_debts_not_one() {
        // services that name the torrent in the body all share one url
        let transport = Arc::new(MockTransport::new(vec![Route::offline("control")]));
        let client = DebridClient::new(client().config, "key".into(), transport, Arc::new(ManualClock::new()));
        for id in ["one", "two"] {
            let opts = RequestOpts {
                method: Some(Method::Post),
                body: Some(vec![("torrent_id".into(), Value::String(id.into()))]),
                ..Default::default()
            };
            client.release(&PlainDialect, "https://api/control", opts).await;
        }
        assert_eq!(client.orphaned(), 2);
    }

    #[tokio::test]
    async fn poll_budgets_grow_with_the_link_a_provider_is_actually_on() {
        // the same provider, one on a healthy link and one on a slow one
        let clock = Arc::new(ManualClock::new());
        let transport = Arc::new(
            MockTransport::new(vec![Route::json("torrents", 200, r#"{"success":true,"data":[]}"#)])
                .on_link(clock.clone(), 1_200),
        );
        let torbox = TorBox::new("key".into(), transport, clock);
        let before = torbox.client().budget(READY);
        for _ in 0..10 {
            let _ = torbox.list_availability().await;
        }
        let after = torbox.client().budget(READY);
        assert!(after > before, "a slow link buys more time, {before}ms -> {after}ms");
        assert!(after <= READY * 3, "but never more than the cap");
    }
}

/// What pacing and retries do to the traffic this client puts on an account — the half
/// of the JS base class that went missing in the port, and the half TorBox reacts to.
#[cfg(test)]
mod pacing {
    use super::*;
    use crate::providers::torbox::TorBox;
    use crate::testing::{ManualClock, MockTransport, Route};
    use crate::DebridProvider;

    fn torbox(routes: Vec<Route>) -> (TorBox, Arc<MockTransport>, Arc<ManualClock>) {
        let transport = Arc::new(MockTransport::new(routes));
        let clock = Arc::new(ManualClock::new());
        (TorBox::new("key".into(), transport.clone(), clock.clone()), transport, clock)
    }

    #[tokio::test]
    async fn a_request_refused_for_going_too_fast_is_made_again_after_the_wait_it_asked_for() {
        let (torbox, transport, clock) = torbox(vec![Route::json("checkcached", 429, r#"{"error":"RATE_LIMIT"}"#)
            .with_headers(vec![("retry-after", "2")])]);
        let started = clock.now_ms();
        let hashes = vec!["a".repeat(40)];
        let failed = torbox.check_availability_batch(&hashes).await;

        assert!(failed.is_err(), "it keeps failing, so eventually it gives up");
        assert_eq!(transport.urls().len(), 3, "the first ask plus two more");
        assert!(clock.now_ms() - started >= 4_000, "and it waited the two seconds it was told, each time");
    }

    #[tokio::test]
    async fn a_wait_longer_than_anyone_should_sit_through_is_reported_instead_of_waited_out() {
        // measured live: a link burst earned retry-after: 300. Honouring that froze every
        // request on the account — playback included — for five minutes
        let (torbox, transport, clock) = torbox(vec![Route::json("checkcached", 429, r#"{"error":"RATE_LIMIT"}"#)
            .with_headers(vec![("retry-after", "300")])]);
        let started = clock.now_ms();
        assert!(torbox.check_availability_batch(&[ "a".repeat(40)]).await.is_err());
        assert_eq!(transport.urls().len(), 1, "asking again would only collect another one");
        assert!(clock.now_ms() - started < 30_000, "and nothing was made to wait for it");
    }

    #[tokio::test]
    async fn a_round_trip_that_never_came_back_is_worth_exactly_one_more_ask() {
        let (torbox, transport, _clock) = torbox(vec![Route::timeout("checkcached", 30_000)]);
        assert!(torbox.check_availability_batch(&["a".repeat(40)]).await.is_err());
        assert_eq!(transport.urls().len(), 2, "a timeout says nothing, so it is asked once more");
    }

    #[tokio::test]
    async fn a_service_that_answered_is_not_asked_the_same_question_twice() {
        // auth, a 500, an unreachable host: all answers. Repeating the question does not
        // improve any of them, and doing so is how a retry loop becomes the outage
        for route in [
            Route::json("checkcached", 401, r#"{"error":"BAD_TOKEN"}"#),
            Route::json("checkcached", 500, r#"{"error":"DATABASE_ERROR"}"#),
            Route::offline("checkcached"),
        ] {
            let (torbox, transport, _clock) = torbox(vec![route]);
            assert!(torbox.check_availability_batch(&["a".repeat(40)]).await.is_err());
            assert_eq!(transport.urls().len(), 1);
        }
    }

    /// Answers the account listing at once, but holds every link request until
    /// `max_concurrent` of them have arrived together. Sequential code never gets that
    /// far, so it hangs — which the timeout in the test turns into a failure.
    struct LinksMustOverlap {
        listing: String,
        arrived: tokio::sync::Barrier,
    }

    #[async_trait::async_trait]
    impl shiru_networking::HttpTransport for LinksMustOverlap {
        async fn execute(
            &self,
            request: shiru_networking::HttpRequest,
        ) -> Result<HttpResponse, shiru_networking::TransportError> {
            let body = if request.url.contains("requestdl") {
                self.arrived.wait().await;
                r#"{"success":true,"data":"https://cdn/x.mkv"}"#.to_string()
            } else {
                self.listing.clone()
            };
            Ok(HttpResponse { status: 200, headers: HashMap::new(), body: body.into_bytes() })
        }
    }

    #[tokio::test]
    async fn a_pack_asks_for_its_links_together_rather_than_one_round_trip_at_a_time() {
        // this is what the limiter buys back: the JS sent these concurrently and stayed
        // inside the allowance because Bottleneck paced them. Sequential was the port's
        // stand-in for pacing, and it cost a full round trip per episode of the pack
        // before playback could start — on a slow link, most of a minute of black screen
        let files: Vec<String> = (1..=6)
            .map(|n| format!(r#"{{"id":{n},"name":"Pack/Show - 0{n}.mkv","size":100,"mimetype":"video/x-matroska"}}"#))
            .collect();
        let listing = format!(
            r#"{{"success":true,"data":[{{"id":7,"hash":"{}","name":"Pack","download_present":true,"download_finished":true,"progress":1,"files":[{}]}}]}}"#,
            "a".repeat(40),
            files.join(",")
        );
        let transport = Arc::new(LinksMustOverlap {
            listing,
            // TorBox's own max_concurrent: the most the limiter will let overlap
            arrived: tokio::sync::Barrier::new(3),
        });
        let torbox = TorBox::new("key".into(), transport, Arc::new(ManualClock::new()));
        let resolved = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            torbox.resolve(&format!("magnet:?xt=urn:btih:{}", "a".repeat(40)), &Default::default()),
        )
        .await
        .expect("the links went out one at a time, so none of them ever met another")
        .expect("a cached pack resolves");
        assert_eq!(resolved.files.len(), 6, "and every file still comes back");
    }

    #[tokio::test]
    async fn the_account_listing_is_read_once_a_minute_and_not_once_per_play() {
        // reading it per play put a thousand-entry response ahead of the links the user is
        // actually waiting for, every single time they pressed play
        let torrent = format!(
            r#"{{"id":7,"hash":"{}","name":"Show","download_present":true,"download_finished":true,"progress":1,"files":[{{"id":1,"name":"Show/Show - 01.mkv","size":100}}]}}"#,
            "a".repeat(40)
        );
        let (torbox, transport, clock) = torbox(vec![
            Route::json("torrents/mylist", 200, &format!(r#"{{"success":true,"data":[{torrent}]}}"#)),
            Route::json("requestdl", 200, r#"{"success":true,"data":"https://cdn/x.mkv"}"#),
        ]);
        let magnet = format!("magnet:?xt=urn:btih:{}", "a".repeat(40));

        torbox.list_availability().await.unwrap();
        let after_badges = transport.urls().iter().filter(|url| url.contains("mylist")).count();
        torbox.resolve(&magnet, &Default::default()).await.unwrap();
        let after_play = transport.urls().iter().filter(|url| url.contains("mylist")).count();
        assert_eq!(
            transport.urls().iter().filter(|url| url.contains("mylist") && !url.contains("&id=")).count(),
            after_badges,
            "the play reused the listing the badge refresh had already paid for"
        );
        assert_eq!(
            after_play, after_badges,
            "requestdl confirms the cached id by using it; an uncached confirmation used to block playback"
        );

        clock.advance(61_000);
        torbox.list_availability().await.unwrap();
        assert_eq!(
            transport.urls().iter().filter(|url| url.contains("mylist") && !url.contains("&id=")).count(),
            after_badges + 1,
            "and a minute later it is read again"
        );
    }
}
