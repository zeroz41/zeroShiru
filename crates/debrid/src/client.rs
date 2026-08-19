//! The request machinery every provider shares: authentication schemes, body
//! encoding, latency-stretched poll budgets, availability memory and the account
//! listing cache. Port of the stateful half of common/modules/debrid/service.js.
//!
//! Rate limiting note: the JS layer wraps requests in Bottleneck. The Rust port
//! keeps concurrency/pacing simpler (a semaphore plus min-gap) — the per-provider
//! reservoir numbers live in ProviderConfig for when a fuller limiter is needed.

use crate::error::DebridError;
use crate::platform::Platform;
use crate::{AuthScheme, BodyEncoding, ProviderConfig};
use serde_json::Value;
use shiru_domain::{parse_hash, Availability};
use shiru_networking::{Body, HttpRequest, HttpResponse, HttpTransport, Method};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// How far a poll budget may stretch on a slow link.
const MAX_STRETCH: f64 = 3.0;

/// How many times a removal this client owes the account is retried before it is
/// written off. A service that will not take the removal is not worth asking forever.
const MAX_CLEANUP_ATTEMPTS: usize = 3;

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
    /// What the service has already said about a hash, with when it said it.
    availability: Mutex<HashMap<String, (Availability, u64)>>,
    /// The real release name behind a hash, as the service knows it.
    release_names: Mutex<HashMap<String, String>>,
    /// Removals that failed, to try again. Keyed by the whole request, since services
    /// that name the torrent in the body would otherwise all collide on one url.
    orphans: Mutex<HashMap<String, (String, RequestOpts, usize)>>,
}

impl DebridClient {
    pub fn new(
        config: ProviderConfig,
        api_key: String,
        transport: Arc<dyn HttpTransport>,
        platform: Arc<dyn Platform>,
    ) -> Self {
        DebridClient {
            config,
            api_key,
            transport,
            platform,
            latency: AtomicU64::new(0),
            availability: Mutex::new(HashMap::new()),
            release_names: Mutex::new(HashMap::new()),
            orphans: Mutex::new(HashMap::new()),
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

    /// One authenticated round trip, with the provider's error conventions applied.
    pub async fn request(&self, dialect: &dyn Dialect, url: &str, opts: RequestOpts) -> Result<Value, DebridError> {
        if self.api_key.is_empty() {
            return Err(DebridError::Auth { message: "No debrid API key configured".into(), status: None, code: None });
        }
        let auth = opts.auth.unwrap_or(self.config.auth);
        let auth_param = opts.auth_param.unwrap_or(self.config.auth_param);
        let (authorized_url, headers) = self.authorize(url, auth, auth_param);
        let body = opts
            .body
            .as_ref()
            .map(|fields| Self::encode_body(fields, opts.encoding.unwrap_or(self.config.encoding)));
        let timeout_ms = opts.timeout_ms.unwrap_or(self.config.timeouts.request);
        let request = HttpRequest {
            method: opts.method.unwrap_or(Method::Get),
            url: authorized_url,
            headers: headers.into_iter().collect(),
            body,
            timeout_ms,
        };
        let sent = self.platform.now_ms();
        let response = self.transport.execute(request).await.map_err(|error| match error {
            shiru_networking::TransportError::Timeout(ms) => {
                DebridError::Timeout { message: format!("request timed out after {ms}ms") }
            }
            shiru_networking::TransportError::Network(message) => DebridError::Network { message },
        })?;
        // only round trips that came back, so a timeout cannot inflate it
        self.observe_latency(self.platform.now_ms().saturating_sub(sent));
        self.finish(dialect, response)
    }

    fn finish(&self, dialect: &dyn Dialect, response: HttpResponse) -> Result<Value, DebridError> {
        if !response.ok() {
            let json: Option<Value> = serde_json::from_slice(&response.body).ok();
            let mut error = dialect.map_error(response.status, json.as_ref());
            if response.status == 429 {
                // surface retry-after so a limiter layer can decide what to do with it
                if let (Some(after), DebridError::Service { message, .. }) =
                    (response.header("retry-after"), &mut error)
                {
                    *message = format!("{message} (retry-after: {after})");
                }
            }
            return Err(error);
        }
        if response.status == 204 || response.body.is_empty() {
            return Ok(Value::Null);
        }
        let json: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
        dialect.unwrap(json)
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
        };
        DebridClient::new(
            config,
            "key".into(),
            Arc::new(MockTransport::new(vec![])),
            Arc::new(ManualClock::new()),
        )
    }

    const READY: u64 = 5_000; // Timeouts::default().ready

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
