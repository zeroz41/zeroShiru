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
