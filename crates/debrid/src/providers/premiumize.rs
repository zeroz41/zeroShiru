//! Premiumize implementation, see https://www.premiumize.me/api
//! Port of common/modules/debrid/premiumize.js; test/unit/debrid/premiumize.test.js
//! is the behavioural reference.
//!
//! The easiest service to support, having kept the endpoints the others dropped:
//! `/cache/check` answers a whole results list for free, and `/transfer/directdl`
//! returns every stream link for a magnet in one call without storing anything, so
//! there is no add or cleanup path at all — nothing here for the orphan-retry
//! manager layer to replay (TODO: other providers will need it).
//!
//! `/transfer/list` never says which info hash a transfer came from, so badges come
//! from the cache endpoint alone.

use crate::client::{DebridClient, Dialect, RequestOpts};
use crate::error::DebridError;
use crate::platform::Platform;
use crate::{
    secure_files, window_files, AccountInfo, AuthScheme, AvailabilityCheck, BodyEncoding,
    DebridProvider, ProviderConfig, ResolveOptions, Timeouts,
};
use async_trait::async_trait;
use serde_json::Value;
use shiru_domain::{parse_hash, to_magnet, Availability, DebridFile, DebridResolved};
use shiru_networking::{HttpTransport, Method};
use std::collections::HashMap;
use std::sync::Arc;

const API: &str = "https://www.premiumize.me/api";

/// Error codes worth explaining, anything else falls back to the API's own message.
fn known_message(code: &str) -> Option<&'static str> {
    match code {
        "authentication_failed" => Some("Invalid Premiumize API key"),
        "permission_denied" => Some("Premiumize denied the request, check the account"),
        "account_limit_reached" => {
            Some("This Premiumize account has used up its fair use points or active jobs")
        }
        "service_limit_reached" => {
            Some("This Premiumize account has reached its limit for this source")
        }
        "rate_limit_reached" => {
            Some("Premiumize is rate limiting this account, try again shortly")
        }
        "service_down" => Some("Premiumize cannot reach this source right now"),
        "service_unsupported" => Some("Premiumize cannot process this kind of source"),
        "link_generation_failed" => {
            Some("Premiumize could not generate a stream link, try again shortly")
        }
        _ => None,
    }
}

/// Only these mean the key or account is the problem, the rest are per-request.
const AUTH_CODES: [&str; 2] = ["authentication_failed", "permission_denied"];
/// The account cannot take more work right now, rather than this release being a problem.
const THROTTLE_CODES: [&str; 3] =
    ["rate_limit_reached", "account_limit_reached", "service_limit_reached"];
/// The same request will keep failing, so this release is not one Premiumize can serve.
const DEAD_CODES: [&str; 2] = ["service_unsupported", "permanent_error"];

/// Premiumize's response conventions: failures arrive inside a 200, with the payload at
/// the top level rather than in an envelope.
struct PremiumizeDialect;

impl Dialect for PremiumizeDialect {
    fn unwrap(&self, json: Value) -> Result<Value, DebridError> {
        // anything without a `status` field passes through untouched
        if json.get("status").and_then(Value::as_str) == Some("error") {
            return Err(self.map_error(200, Some(&json)));
        }
        Ok(json)
    }

    fn map_error(&self, status: u16, json: Option<&Value>) -> DebridError {
        let code = json
            .and_then(|value| value.get("code"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let message = code
            .as_deref()
            .and_then(known_message)
            .map(str::to_string)
            .or_else(|| {
                json.and_then(|value| value.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| format!("Request failed with status {status}"));
        let auth = code.as_deref().is_some_and(|code| AUTH_CODES.contains(&code))
            || ((status == 401 || status == 403) && code.is_none());
        if auth {
            DebridError::Auth { message, status: Some(status), code }
        } else {
            DebridError::Service { message, status: Some(status), code }
        }
    }
}

pub struct Premiumize {
    client: DebridClient,
}

impl Premiumize {
    pub fn new(
        api_key: String,
        transport: Arc<dyn HttpTransport>,
        platform: Arc<dyn Platform>,
    ) -> Self {
        let config = ProviderConfig {
            id: "premiumize",
            title: "Premiumize",
            auth: AuthScheme::Bearer,
            auth_param: "apikey",
            encoding: BodyEncoding::Form,
            timeouts: Timeouts::default(),
            nominal_latency: 300,
            max_files: 60,
            // a real cache endpoint, so badges cost one request for the whole results list
            availability_check: AvailabilityCheck::Batch,
            check_adds_magnets: false,
            max_batch: 100,
            max_probes: 10,
            // no documented allowance, so be modest
            max_concurrent: 3,
            min_time_ms: 250,
        };
        Premiumize { client: DebridClient::new(config, api_key, transport, platform) }
    }

    /// Whether an error means the account wants fewer requests rather than that a release
    /// is a problem. A sweep stops on one. Consulted by the manager layer alongside
    /// `DebridError::throttled` (TODO: wire in once the sweep/manager layer lands).
    pub fn throttled(&self, error: &DebridError) -> bool {
        error.throttled()
            || error_code(error).is_some_and(|code| THROTTLE_CODES.contains(&code))
    }

    /// Every stream link for a magnet, read out of the cache in one call. Touches
    /// nothing, so a miss comes back empty or as a code rather than needing a check first.
    async fn directdl(&self, magnet_uri: &str) -> Result<Vec<Value>, DebridError> {
        let opts = RequestOpts {
            method: Some(Method::Post),
            body: Some(vec![("src".into(), Value::String(magnet_uri.to_string()))]),
            ..Default::default()
        };
        let transfer = self
            .client
            .request(&PremiumizeDialect, &format!("{API}/transfer/directdl"), opts)
            .await
            .map_err(|error| {
                // the API groups its codes by whether the same request could ever succeed,
                // which maps straight onto what playback needs to know
                match error_code(&error) {
                    Some(code) if DEAD_CODES.contains(&code) => {
                        DebridError::Unavailable { message: error.to_string() }
                    }
                    // it can still fetch it, just not now
                    Some("not_found") => DebridError::not_cached(),
                    _ => error,
                }
            })?;
        let content: Vec<Value> = transfer
            .get("content")
            .and_then(Value::as_array)
            .map(|entries| {
                entries
                    .iter()
                    .filter(|entry| {
                        entry
                            .get("link")
                            .and_then(Value::as_str)
                            .is_some_and(|link| !link.is_empty())
                    })
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if content.is_empty() {
            return Err(DebridError::not_cached()); // directdl only reads the cache
        }
        Ok(content)
    }
}

#[async_trait]
impl DebridProvider for Premiumize {
    fn client(&self) -> &crate::client::DebridClient {
        &self.client
    }

    fn config(&self) -> &ProviderConfig {
        &self.client.config
    }

    async fn validate(&self) -> Result<AccountInfo, DebridError> {
        let account = self
            .client
            .request(&PremiumizeDialect, &format!("{API}/account/info"), RequestOpts::default())
            .await?;
        // free accounts stream cached content through the same endpoints, so premium is
        // not required
        let customer_id = match account.get("customer_id") {
            Some(Value::String(id)) if !id.is_empty() => Some(id.clone()),
            Some(Value::Number(id)) if id.as_f64() != Some(0.0) => Some(id.to_string()),
            _ => None,
        };
        let Some(customer_id) = customer_id else {
            return Err(DebridError::Auth {
                message: "Premiumize did not recognise this API key".into(),
                status: None,
                code: None,
            });
        };
        let expires = account
            .get("premium_until")
            .and_then(Value::as_i64)
            .filter(|seconds| *seconds != 0)
            .map(iso_from_unix_seconds);
        Ok(AccountInfo { username: format!("Premiumize {customer_id}"), expires })
    }

    /// Nothing to read: transfers carry no info hash, so the account listing is never
    /// fetched (the JS `fetchListing` answers `[]` for the same reason). The cache
    /// endpoint covers badges instead.
    async fn list_availability(&self) -> Result<HashMap<String, Availability>, DebridError> {
        Ok(HashMap::new())
    }

    /// One request, however many releases, and it costs the account nothing.
    async fn check_availability_batch(
        &self,
        hashes: &[String],
    ) -> Result<HashMap<String, Availability>, DebridError> {
        // the answer is positional, so every hash must arrive as its own repeated
        // parameter, in order — an unparseable one still holds its slot (as an empty
        // string, like the JS), or every result after it would shift
        let items: Vec<Value> = hashes
            .iter()
            .map(|hash| Value::String(to_magnet(hash).unwrap_or_default()))
            .collect();
        let opts = RequestOpts {
            method: Some(Method::Post),
            body: Some(vec![("items[]".into(), Value::Array(items))]),
            ..Default::default()
        };
        let checked = self
            .client
            .request(&PremiumizeDialect, &format!("{API}/cache/check"), opts)
            .await?;
        // parallel arrays indexed by request order, not keyed by hash
        let cached = checked.get("response").and_then(Value::as_array);
        Ok(hashes
            .iter()
            .enumerate()
            .map(|(index, hash)| {
                let hit = cached.and_then(|answers| answers.get(index)).is_some_and(truthy);
                // a miss means it would have to fetch it, not that it cannot
                (hash.clone(), if hit { Availability::Cached } else { Availability::Available })
            })
            .collect())
    }

    async fn probe_availability(&self, _hash: &str) -> Result<Availability, DebridError> {
        Err(DebridError::Service {
            message: "Premiumize answers availability in batches via /cache/check, never by probing".into(),
            status: None,
            code: None,
        })
    }

    async fn resolve(
        &self,
        magnet: &str,
        opts: &ResolveOptions,
    ) -> Result<DebridResolved, DebridError> {
        let hash = parse_hash(magnet).unwrap_or_default();
        let magnet_uri = to_magnet(magnet).ok_or_else(|| DebridError::Service {
            message: "Premiumize needs a magnet link or info hash to resolve".into(),
            status: None,
            code: None,
        })?;
        let content = self.directdl(&magnet_uri).await?;
        let wanted: Vec<DebridFile> = content
            .iter()
            .map(|entry| {
                let path = file_path(entry);
                DebridFile {
                    name: path.rsplit('/').next().unwrap_or_default().to_string(),
                    path,
                    size: entry_size(entry.get("size")),
                    url: entry
                        .get("link")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    r#type: None,
                }
            })
            .filter(|file| opts.file_filter.as_ref().is_none_or(|keep| keep(&file.path)))
            .collect();
        if wanted.is_empty() {
            return Err(DebridError::Service {
                message: "No playable files in this torrent".into(),
                status: None,
                code: None,
            });
        }
        let target = match &opts.pick_file {
            Some(pick) => {
                let choices: Vec<(u64, String, u64)> = wanted
                    .iter()
                    .enumerate()
                    .map(|(index, file)| (index as u64, file.path.clone(), file.size))
                    .collect();
                pick(&choices)?
            }
            // largest file, first on ties, like the JS stable sort
            None => Some(
                wanted
                    .iter()
                    .enumerate()
                    .fold(0, |best, (index, file)| {
                        if file.size > wanted[best].size { index } else { best }
                    }),
            ),
        };
        let max_files = opts.max_files.unwrap_or(self.client.config.max_files);
        let files = window_files(&wanted, target, max_files).to_vec();
        // the JS trusted Premiumize to hand out HTTPS; the port enforces the base
        // contract explicitly, since the player streams these links as they are
        let files = secure_files(files, self.client.config.title)?;
        let name = torrent_name(&files);
        Ok(DebridResolved { hash, name, files })
    }
}

/// The `code` a typed error carries, for the code-grouped handling above.
fn error_code(error: &DebridError) -> Option<&str> {
    match error {
        DebridError::Auth { code, .. } | DebridError::Service { code, .. } => code.as_deref(),
        _ => None,
    }
}

/// JS truthiness for a cache answer, so an API answering 1/"yes" degrades gracefully.
fn truthy(value: &Value) -> bool {
    match value {
        Value::Bool(hit) => *hit,
        Value::Number(number) => number.as_f64().is_some_and(|n| n != 0.0),
        Value::String(text) => !text.is_empty(),
        Value::Null => false,
        _ => true,
    }
}

/// `size` arrives as a number on directdl but as a string on other endpoints.
fn entry_size(value: Option<&Value>) -> u64 {
    match value {
        Some(Value::Number(size)) => size
            .as_u64()
            .or_else(|| size.as_f64().map(|float| float as u64))
            .unwrap_or(0),
        Some(Value::String(size)) => size.parse().unwrap_or(0),
        _ => 0,
    }
}

/// Paths arrive without a leading slash; Shiru's file objects are rooted like the
/// torrent client's.
fn file_path(entry: &Value) -> String {
    let path = entry.get("path").and_then(Value::as_str).unwrap_or_default();
    if path.starts_with('/') { path.to_string() } else { format!("/{path}") }
}

/// A name for the release, which directdl never states: the folder a pack sits under,
/// or the file.
fn torrent_name(files: &[DebridFile]) -> String {
    let first = &files[0];
    let folder = first.path.split('/').nth(1).unwrap_or_default();
    let prefix = format!("/{folder}/");
    if !folder.is_empty() && files.iter().all(|file| file.path.starts_with(&prefix)) {
        folder.to_string()
    } else {
        first.name.clone()
    }
}

/// Unix seconds to an ISO 8601 string, like the JS `Date#toISOString`. No chrono in the
/// tree, and civil-from-days is a dozen lines (Howard Hinnant's algorithm).
fn iso_from_unix_seconds(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let clock = seconds.rem_euclid(86_400);
    let (hour, minute, second) = (clock / 3_600, (clock % 3_600) / 60, clock % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.000Z")
}

// Mirrors test/unit/debrid/premiumize.test.js: no live key exists, so these pin the
// request shapes and the response handling the implementation was written against —
// the flat `{ status }` envelope, the parallel-array cache answer, and the single call
// that returns every stream link at once.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{ManualClock, MockTransport, Route};
    use shiru_networking::Body;

    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn magnet() -> String {
        format!("magnet:?xt=urn:btih:{HASH}&dn=test")
    }

    fn service(routes: Vec<Route>) -> (Premiumize, Arc<MockTransport>) {
        let transport = Arc::new(MockTransport::new(routes));
        let premiumize = Premiumize::new(
            "test-key".into(),
            transport.clone(),
            Arc::new(ManualClock::new()),
        );
        (premiumize, transport)
    }

    /// Premiumize reports failures inside a 200, with the payload at the top level.
    fn fail(code: &str, message: &str) -> String {
        format!(r#"{{"status":"error","message":"{message}","code":"{code}"}}"#)
    }

    fn video_filter() -> ResolveOptions {
        ResolveOptions {
            file_filter: Some(Box::new(|path| {
                path.ends_with(".mkv") || path.ends_with(".mp4")
            })),
            ..Default::default()
        }
    }

    const CONTENT: &str = r#"{"status":"success","content":[
        {"path":"Test Pack/Episode 01.mkv","size":1000,"link":"https://premiumize.test/1.mkv"},
        {"path":"Test Pack/readme.txt","size":10,"link":"https://premiumize.test/readme.txt"},
        {"path":"Test Pack/Episode 02.mkv","size":2000,"link":"https://premiumize.test/2.mkv"}
    ]}"#;

    #[tokio::test]
    async fn the_key_travels_as_a_bearer_header_never_in_the_url() {
        let (premiumize, transport) = service(vec![Route::json(
            "/account/info",
            200,
            r#"{"status":"success","customer_id":"1234567","premium_until":1799999999}"#,
        )]);
        let account = premiumize.validate().await.unwrap();
        let requests = transport.requests.lock().unwrap();
        assert_eq!(
            requests[0].headers.get("Authorization").map(String::as_str),
            Some("Bearer test-key")
        );
        assert!(
            !requests[0].url.contains("test-key"),
            "the key must stay out of logs and CDN caches"
        );
        assert!(account.username.contains("1234567"));
        // the expiry is handed to the UI as an ISO date string (date -u -d @1799999999)
        assert_eq!(account.expires.as_deref(), Some("2027-01-15T07:59:59.000Z"));
    }

    // free accounts stream cached content through the same endpoints, so requiring
    // premium here would lock out accounts that work perfectly well
    #[tokio::test]
    async fn an_account_with_no_premium_still_validates() {
        let (premiumize, _) = service(vec![Route::json(
            "/account/info",
            200,
            r#"{"status":"success","customer_id":"99","premium_until":null}"#,
        )]);
        let account = premiumize.validate().await.unwrap();
        assert_eq!(account.expires, None);
    }

    #[tokio::test]
    async fn a_rejected_key_is_an_auth_error_whatever_the_http_status_says() {
        let (premiumize, _) = service(vec![Route::json(
            "/account/info",
            200,
            &fail("authentication_failed", "Not logged in"),
        )]);
        let error = premiumize.validate().await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
        assert_eq!(error.to_string(), "Invalid Premiumize API key");
    }

    #[tokio::test]
    async fn the_cache_endpoint_answers_a_whole_results_list_in_one_request() {
        let (premiumize, transport) = service(vec![Route::json(
            "/cache/check",
            200,
            r#"{"status":"success","response":[true,false],"filename":["Test",null],"filesize":["1000",0]}"#,
        )]);
        let answers = premiumize
            .check_availability_batch(&[HASH.to_string(), OTHER.to_string()])
            .await
            .unwrap();
        assert_eq!(
            transport.requests.lock().unwrap().len(),
            1,
            "one request, however many hashes"
        );
        assert_eq!(answers.get(HASH), Some(&Availability::Cached));
        assert_eq!(
            answers.get(OTHER),
            Some(&Availability::Available),
            "a miss means it would have to fetch it, not that it cannot"
        );
    }

    // the answer is positional, so sending the hashes any other way silently shifts
    // every result
    #[tokio::test]
    async fn each_hash_is_sent_as_its_own_repeated_parameter_in_order() {
        let (premiumize, transport) = service(vec![Route::json(
            "/cache/check",
            200,
            r#"{"status":"success","response":[false,true]}"#,
        )]);
        let answers = premiumize
            .check_availability_batch(&[HASH.to_string(), OTHER.to_string()])
            .await
            .unwrap();
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests[0].method, Method::Post);
        let Some(Body::Bytes { bytes, .. }) = &requests[0].body else {
            panic!("expected a form body")
        };
        let body = String::from_utf8(bytes.clone()).unwrap();
        let sent: Vec<&str> =
            body.split('&').filter(|field| field.starts_with("items%5B%5D=")).collect();
        assert_eq!(
            sent.len(),
            2,
            "two hashes must arrive as two parameters, not one joined value"
        );
        assert!(sent[0].contains(HASH));
        assert_eq!(
            answers.get(OTHER),
            Some(&Availability::Cached),
            "the second answer belongs to the second hash"
        );
    }

    #[tokio::test]
    async fn resolve_reads_every_stream_link_out_of_one_call_and_adds_nothing() {
        let (premiumize, transport) =
            service(vec![Route::json("/transfer/directdl", 200, CONTENT)]);
        let resolved = premiumize.resolve(&magnet(), &video_filter()).await.unwrap();
        assert_eq!(
            transport.requests.lock().unwrap().len(),
            1,
            "one request is the whole resolve"
        );
        assert_eq!(resolved.hash, HASH);
        assert_eq!(
            resolved.name, "Test Pack",
            "the folder every file sits under names the release"
        );
        let names: Vec<&str> = resolved.files.iter().map(|file| file.name.as_str()).collect();
        assert_eq!(names, ["Episode 01.mkv", "Episode 02.mkv"], "non-video files are filtered out");
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        assert_eq!(
            paths,
            ["/Test Pack/Episode 01.mkv", "/Test Pack/Episode 02.mkv"],
            "paths are rooted like the torrent client's"
        );
        assert_eq!(resolved.files[0].url, "https://premiumize.test/1.mkv");
    }

    #[tokio::test]
    async fn a_single_file_release_is_named_after_the_file_itself() {
        let (premiumize, _) = service(vec![Route::json(
            "/transfer/directdl",
            200,
            r#"{"status":"success","content":[{"path":"Episode 01.mkv","size":1000,"link":"https://premiumize.test/1.mkv"}]}"#,
        )]);
        let resolved = premiumize.resolve(&magnet(), &video_filter()).await.unwrap();
        assert_eq!(resolved.name, "Episode 01.mkv");
        assert_eq!(resolved.files[0].path, "/Episode 01.mkv");
    }

    #[tokio::test]
    async fn the_episode_being_played_picks_the_file_not_the_largest_one() {
        let (premiumize, _) = service(vec![Route::json("/transfer/directdl", 200, CONTENT)]);
        let opts = ResolveOptions {
            pick_file: Some(Box::new(|files| {
                Ok(files.iter().position(|(_, path, _)| path.contains("01")))
            })),
            ..video_filter()
        };
        let resolved = premiumize.resolve(&magnet(), &opts).await.unwrap();
        assert!(resolved.files.iter().any(|file| file.name == "Episode 01.mkv"));
    }

    // directdl only ever reads the cache, so an empty answer is the cache saying no
    #[tokio::test]
    async fn nothing_in_the_cache_reads_as_not_cached_and_playback_can_fall_back() {
        let (premiumize, _) = service(vec![Route::json(
            "/transfer/directdl",
            200,
            r#"{"status":"success","content":[]}"#,
        )]);
        let error = premiumize.resolve(&magnet(), &ResolveOptions::default()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
    }

    #[tokio::test]
    async fn a_source_premiumize_cannot_process_says_so_rather_than_looking_uncached() {
        let (premiumize, _) = service(vec![Route::json(
            "/transfer/directdl",
            200,
            &fail("service_unsupported", "no"),
        )]);
        let error = premiumize.resolve(&magnet(), &ResolveOptions::default()).await.unwrap_err();
        assert!(matches!(error, DebridError::Unavailable { .. }));
    }

    #[tokio::test]
    async fn a_release_premiumize_simply_does_not_hold_is_uncached_not_unavailable() {
        let (premiumize, _) = service(vec![Route::json(
            "/transfer/directdl",
            200,
            &fail("not_found", "no such thing"),
        )]);
        let error = premiumize.resolve(&magnet(), &ResolveOptions::default()).await.unwrap_err();
        assert!(
            matches!(error, DebridError::NotCached { .. }),
            "Premiumize could still fetch it, so this must stay recoverable"
        );
    }

    #[tokio::test]
    async fn a_transient_link_failure_is_left_transient_so_the_release_stays_recheckable() {
        let (premiumize, _) = service(vec![Route::json(
            "/transfer/directdl",
            200,
            &fail("link_generation_failed", "nope"),
        )]);
        let error = premiumize.resolve(&magnet(), &ResolveOptions::default()).await.unwrap_err();
        assert!(
            matches!(error, DebridError::Service { .. }),
            "a bad moment proves nothing about the release"
        );
    }

    #[tokio::test]
    async fn being_rate_limited_stops_a_sweep_rather_than_counting_against_the_release() {
        let (premiumize, _) = service(vec![]);
        let coded = |code: &str| DebridError::Service {
            message: "nope".into(),
            status: Some(200),
            code: Some(code.to_string()),
        };
        assert!(premiumize.throttled(&coded("rate_limit_reached")));
        assert!(premiumize.throttled(&coded("account_limit_reached")));
        assert!(!premiumize.throttled(&coded("link_generation_failed")));
    }

    // the account listing names transfers but never the info hash behind one, so there
    // is nothing to badge from it. It must answer empty rather than error, since the
    // badge refresh calls it
    #[tokio::test]
    async fn the_account_listing_is_empty_rather_than_unimplemented() {
        let (premiumize, transport) = service(vec![]);
        assert!(premiumize.list_availability().await.unwrap().is_empty());
        assert!(transport.requests.lock().unwrap().is_empty(), "and costs no request");
    }

    #[tokio::test]
    async fn resolve_refuses_a_source_it_cannot_turn_into_a_hash_instead_of_guessing() {
        let (premiumize, transport) = service(vec![]);
        let error = premiumize
            .resolve("https://nyaa.si/download/1.torrent", &ResolveOptions::default())
            .await
            .unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }));
        assert!(transport.requests.lock().unwrap().is_empty());
    }
}
