//! AllDebrid implementation, see https://docs.alldebrid.com/
//! Port of common/modules/debrid/alldebrid.js; test/unit/debrid/alldebrid.test.js
//! is the behavioural reference, mirrored by the tests below.
//!
//! Two API quirks shape this client:
//! - `/magnet/instant` is gone, so availability is read off the upload response, which
//!   answers `ready` per magnet and takes many at once. Cheap in requests, but every hash
//!   checked lands on the account for a moment, hence the small caps below.
//! - `/magnet/status` never says which info hash a magnet came from, so the account is
//!   only good for telling this client's uploads from the user's own, never for badges.
//!
//! Because every batch check lands magnets on the account, the JS marks this service
//! `checkAddsMagnets = true` with `maxAsk = 10` despite being a batch checker.
//! NOTE: check_adds_magnets is now an explicit ProviderConfig field (set true here), so
//! the manager layer must still treat AllDebrid's batch check as magnet-adding: run at
//! most one check at a time, cap asking at 10 hashes, and read an unanswered hash as
//! unknown rather than "not cached".

use crate::client::{DebridClient, Dialect, OrphanOnDrop, RequestOpts};
use crate::error::DebridError;
use crate::platform::Platform;
use crate::window::window_files;
use crate::{
    secure_files, AccountInfo, AuthScheme, AvailabilityCheck, BodyEncoding, DebridProvider,
    ProviderConfig, ResolveOptions, Timeouts,
};
use async_trait::async_trait;
use serde_json::Value;
use shiru_domain::{parse_hash, to_magnet, Availability, DebridFile, DebridResolved};
use shiru_networking::{HttpTransport, Method};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

// magnet status and the file tree moved to v4.1, everything else is still v4
const V4: &str = "https://api.alldebrid.com/v4";
const V41: &str = "https://api.alldebrid.com/v4.1";

/// Error codes worth explaining, anything else falls back to the API's own message.
fn message_for(code: &str) -> Option<&'static str> {
    Some(match code {
        "AUTH_BAD_APIKEY" => "Invalid AllDebrid API key",
        "AUTH_MISSING_APIKEY" => "AllDebrid requires an API key for this request",
        "AUTH_BLOCKED" => "AllDebrid has blocked this API key",
        "AUTH_USER_BANNED" => "This AllDebrid account is banned",
        "MUST_BE_PREMIUM" => "AllDebrid premium is required for this",
        "MAGNET_MUST_BE_PREMIUM" => "AllDebrid premium is required to stream torrents",
        "MAGNET_TOO_MANY_ACTIVE" => "Too many active AllDebrid magnets, wait for one to finish",
        "MAGNET_TOO_LARGE" => "This release is larger than the AllDebrid plan allows",
        "MAGNET_INVALID_URI" => "AllDebrid would not accept this magnet",
        "MAGNET_NO_SERVER" => "No AllDebrid server is available right now",
        "NO_SERVER" => "No AllDebrid server is available right now",
        "LINK_TOO_MANY_DOWNLOADS" => "Too many active AllDebrid downloads, wait for one to finish",
        "LINK_HOST_UNAVAILABLE" => "AllDebrid cannot serve this file right now",
        "LINK_DOWN" => "AllDebrid reports this file as dead",
        "FREE_TRIAL_LIMIT_REACHED" => "This AllDebrid trial has reached its limit",
        _ => return None,
    })
}

/// Only these mean the key or plan is the problem, the rest are per-request.
const AUTH_CODES: [&str; 6] = [
    "AUTH_BAD_APIKEY",
    "AUTH_MISSING_APIKEY",
    "AUTH_BLOCKED",
    "AUTH_USER_BANNED",
    "MUST_BE_PREMIUM",
    "MAGNET_MUST_BE_PREMIUM",
];
/// The account cannot take on more work right now, rather than this release being a problem.
const THROTTLE_CODES: [&str; 4] =
    ["MAGNET_TOO_MANY_ACTIVE", "LINK_TOO_MANY_DOWNLOADS", "MAGNET_NO_SERVER", "NO_SERVER"];
/// AllDebrid will never take this release, whoever asks and whenever.
const DEAD_CODES: [&str; 3] = ["MAGNET_INVALID_URI", "MAGNET_INVALID_FILE", "MAGNET_TOO_LARGE"];

/// statusCode from /magnet/status: 4 is finished, below it the magnet is still being worked
/// on, above it every value is a way of having failed. See the status code table in the docs.
const READY: f64 = 4.0;

/// AllDebrid wraps every response in `{ status, data, error }` and reports failures with a 200.
struct AllDebridDialect;

impl Dialect for AllDebridDialect {
    fn unwrap(&self, json: Value) -> Result<Value, DebridError> {
        let Some(object) = json.as_object() else { return Ok(json) };
        if !object.contains_key("status") {
            return Ok(json);
        }
        if object.get("status").and_then(Value::as_str) != Some("success") {
            return Err(map_error(200, Some(&json)));
        }
        Ok(object.get("data").cloned().unwrap_or(Value::Null))
    }

    fn map_error(&self, status: u16, json: Option<&Value>) -> DebridError {
        map_error(status, json)
    }
}

fn map_error(status: u16, json: Option<&Value>) -> DebridError {
    let code = json
        .and_then(|value| value.get("error"))
        .and_then(|error| error.get("code"))
        .and_then(Value::as_str);
    let message = code
        .and_then(message_for)
        .map(str::to_string)
        .or_else(|| {
            json.and_then(|value| value.get("error"))
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| format!("Request failed with status {status}"));
    let is_auth = code.is_some_and(|code| AUTH_CODES.contains(&code))
        || ((status == 401 || status == 403) && code.is_none());
    let code = code.map(str::to_string);
    if is_auth {
        DebridError::Auth { message, status: Some(status), code }
    } else {
        DebridError::Service { message, status: Some(status), code }
    }
}

/// The typed answer a rejected upload stands for. Only a release it will never take is an answer.
fn upload_error(error: &Value) -> DebridError {
    let code = error.get("code").and_then(Value::as_str);
    let message = code
        .and_then(message_for)
        .or_else(|| error.get("message").and_then(Value::as_str))
        .unwrap_or("AllDebrid would not accept this magnet")
        .to_string();
    if code.is_some_and(|code| DEAD_CODES.contains(&code)) {
        DebridError::Unavailable { message }
    } else {
        DebridError::Service { message, status: None, code: code.map(str::to_string) }
    }
}

/// What the account says about one magnet, per the status code table in the API docs.
fn magnet_availability(magnet: &Value) -> Availability {
    let code = match magnet.get("statusCode") {
        Some(Value::Number(number)) => number.as_f64(),
        Some(Value::String(text)) => text.trim().parse::<f64>().ok(),
        _ => None,
    };
    let Some(code) = code else { return Availability::Unknown };
    if code == READY {
        Availability::Cached
    } else if code < READY {
        Availability::Available
    } else {
        Availability::Unavailable
    }
}

/// One entry of the flattened file tree, still carrying the locked link.
#[derive(Debug, Clone)]
struct TreeFile {
    path: String,
    size: u64,
    link: String,
}

/// Flattens the file tree into rooted paths. `n` name, `s` size, `l` link, `e` folder children.
fn flatten_files(entries: &[Value], prefix: &str, out: &mut Vec<TreeFile>) {
    for entry in entries {
        let name = entry.get("n").and_then(Value::as_str).unwrap_or("");
        let path = format!("{prefix}/{name}");
        if let Some(children) = entry.get("e").and_then(Value::as_array) {
            flatten_files(children, &path, out);
        } else if let Some(link) = entry.get("l").and_then(Value::as_str).filter(|link| !link.is_empty()) {
            let size = entry.get("s").and_then(Value::as_u64).unwrap_or(0);
            out.push(TreeFile { path, size, link: link.to_string() });
        }
    }
}

/// The magnet's id as a string, so ids compare however the API types them.
fn id_string(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// JS truthiness for the `ready` flag, which the docs type as a boolean but APIs drift.
fn truthy(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().is_some_and(|n| n != 0.0),
        Some(Value::String(text)) => !text.is_empty(),
        _ => false,
    }
}

/// encodeURIComponent-alike for the unlock link query parameter.
fn encode_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

pub struct AllDebrid {
    client: DebridClient,
}

impl AllDebrid {
    pub fn new(api_key: &str, transport: Arc<dyn HttpTransport>, platform: Arc<dyn Platform>) -> Self {
        let config = ProviderConfig {
            id: "alldebrid",
            title: "AllDebrid",
            auth: AuthScheme::Bearer,
            auth_param: "apikey",
            encoding: BodyEncoding::Form,
            timeouts: Timeouts::default(),
            nominal_latency: 300,
            max_files: 60,
            // one upload answers many hashes, but each one lands on the account, so the caps stay small
            availability_check: AvailabilityCheck::Batch,
            check_adds_magnets: true,
            max_batch: 10,
            max_probes: 10,
            max_concurrent: 3, // no documented allowance, so be modest
            min_time_ms: 250,
            reservoir: None,
        };
        AllDebrid { client: DebridClient::new(config, api_key.to_string(), transport, platform) }
    }

    /// Whether an error means AllDebrid wants fewer requests rather than that this release
    /// is a problem. A sweep stops on one. Port of the `throttled` override.
    pub fn is_throttled(error: &DebridError) -> bool {
        if error.throttled() {
            return true;
        }
        match error {
            DebridError::Auth { code: Some(code), .. } | DebridError::Service { code: Some(code), .. } => {
                THROTTLE_CODES.contains(&code.as_str())
            }
            _ => false,
        }
    }

    async fn request(&self, url: &str, opts: RequestOpts) -> Result<Value, DebridError> {
        self.client.request(&AllDebridDialect, url, opts).await
    }

    /// Adds magnets, which is also how AllDebrid is asked whether it holds them.
    async fn upload(&self, magnets_or_hashes: &[String]) -> Result<Vec<Value>, DebridError> {
        let magnets = Value::Array(magnets_or_hashes.iter().map(|entry| Value::String(entry.clone())).collect());
        let data = self
            .request(
                &format!("{V4}/magnet/upload"),
                RequestOpts {
                    method: Some(Method::Post),
                    body: Some(vec![("magnets[]".to_string(), magnets)]),
                    ..Default::default()
                },
            )
            .await?;
        // the account now holds magnets the remembered listing does not
        self.client.forget_listing().await;
        Ok(data.get("magnets").and_then(Value::as_array).cloned().unwrap_or_default())
    }

    /// The account's magnets, or one of them by id.
    async fn magnets(&self, id: Option<&str>) -> Result<Vec<Value>, DebridError> {
        let body = match id {
            Some(id) => vec![("id".to_string(), Value::String(id.to_string()))],
            None => vec![],
        };
        let data = self
            .request(
                &format!("{V41}/magnet/status"),
                RequestOpts { method: Some(Method::Post), body: Some(body), ..Default::default() },
            )
            .await?;
        // asking for one id has answered with a bare object rather than a list
        Ok(match data.get("magnets") {
            Some(Value::Array(magnets)) => magnets.clone(),
            Some(Value::Object(_)) => vec![data.get("magnets").cloned().unwrap()],
            _ => vec![],
        })
    }

    /// A magnet's file tree. Status answers with it inline; the files endpoint is the fallback.
    async fn files(&self, magnet_info: &Value) -> Result<Vec<Value>, DebridError> {
        if let Some(files) = magnet_info.get("files").and_then(Value::as_array) {
            if !files.is_empty() {
                return Ok(files.clone());
            }
        }
        let id = id_string(magnet_info.get("id")).unwrap_or_default();
        let data = self
            .request(
                &format!("{V4}/magnet/files"),
                RequestOpts {
                    method: Some(Method::Post),
                    body: Some(vec![("id[]".to_string(), Value::Array(vec![Value::String(id)]))]),
                    ..Default::default()
                },
            )
            .await?;
        Ok(data
            .get("magnets")
            .and_then(Value::as_array)
            .and_then(|magnets| magnets.first())
            .and_then(|magnet| magnet.get("files"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default())
    }

    /// The magnet ids on the account, as strings so they compare however the API types them.
    /// Deliberately a fresh read — both call sites are about to change the account and need to
    /// know what was already on it, and a minute-old answer would have this call delete a
    /// magnet the user added since. It still refreshes the shared listing on the way past.
    async fn account_ids(&self) -> Result<HashSet<String>, DebridError> {
        let listing = self
            .client
            .listing(true, || async { Ok(Value::Array(self.magnets(None).await?)) })
            .await?;
        Ok(listing
            .as_array()
            .map(|entries| entries.iter().filter_map(|entry| id_string(entry.get("id"))).collect())
            .unwrap_or_default())
    }

    /// Turns one wanted file into a direct stream link, or `None` when AllDebrid answers
    /// without one.
    async fn unlock(&self, file: &TreeFile) -> Result<Option<DebridFile>, DebridError> {
        let unlocked = self
            .request(
                &format!("{V4}/link/unlock?link={}", encode_component(&file.link)),
                RequestOpts::default(),
            )
            .await?;
        let Some(link) = unlocked.get("link").and_then(Value::as_str).filter(|link| !link.is_empty())
        else {
            return Ok(None);
        };
        let name = file.path.rsplit('/').next().unwrap_or("").to_string();
        let size = unlocked
            .get("filesize")
            .and_then(Value::as_u64)
            .filter(|size| *size > 0)
            .unwrap_or(file.size);
        Ok(Some(DebridFile { name, path: file.path.clone(), size, url: link.to_string(), r#type: None }))
    }

    /// Turns the wanted files into direct stream links, all at once and paced by the
    /// limiter — a pack unlocked one link at a time costs a full round trip per episode
    /// before playback can start.
    async fn unlock_links(&self, wanted: &[TreeFile]) -> Result<Vec<DebridFile>, DebridError> {
        crate::client::map_files(wanted, |file| self.unlock(file)).await
    }

    /// Best-effort removal, never failing the caller: it runs where an error would mask the
    /// real failure. A removal that fails is remembered by the client and retried before the
    /// next check adds anything, so a dropped link cannot leave a magnet on the account.
    async fn delete(&self, id: &str) {
        let (url, opts) = Self::delete_request(id);
        self.client.release(&AllDebridDialect, &url, opts).await;
    }

    /// The request that removes a magnet from the account, as (url, opts) so it can be
    /// sent now or armed on a drop guard.
    fn delete_request(id: &str) -> (String, RequestOpts) {
        (
            format!("{V4}/magnet/delete"),
            RequestOpts {
                method: Some(Method::Post),
                body: Some(vec![("id".to_string(), Value::String(id.to_string()))]),
                ..Default::default()
            },
        )
    }

    /// The part of resolve that runs once a magnet is on the account, split out so the caller
    /// can clean up a magnet this call added when any of it fails.
    async fn resolve_ready(
        &self,
        uploaded: &Value,
        id: &str,
        hash: &str,
        opts: &ResolveOptions,
    ) -> Result<DebridResolved, DebridError> {
        if !truthy(uploaded.get("ready")) {
            return Err(DebridError::not_cached());
        }
        // Unlike services with a slow add step, the upload answered `ready` synchronously, so
        // there is nothing to poll for here — no budget()/sleep loop like other providers.
        let magnet_info = self
            .magnets(Some(id))
            .await?
            .into_iter()
            .next()
            // the upload already said ready, so an empty read is the request failing, not an answer
            .ok_or_else(|| DebridError::Service {
                message: "AllDebrid did not report the magnet back after adding it".to_string(),
                status: None,
                code: None,
            })?;
        match magnet_availability(&magnet_info) {
            Availability::Cached => {}
            Availability::Unavailable => {
                let status = magnet_info.get("status").and_then(Value::as_str).unwrap_or("failed");
                return Err(DebridError::Unavailable {
                    message: format!("AllDebrid could not process this torrent ({status})"),
                });
            }
            _ => return Err(DebridError::not_cached()),
        }

        let mut wanted = Vec::new();
        flatten_files(&self.files(&magnet_info).await?, "", &mut wanted);
        if let Some(filter) = &opts.file_filter {
            wanted.retain(|file| filter(&file.path));
        }
        if wanted.is_empty() {
            return Err(DebridError::Service {
                message: "No playable files in this torrent".to_string(),
                status: None,
                code: None,
            });
        }

        // the caller picks by index over (id, path, size); AllDebrid files have no id of
        // their own, so the index doubles as one. Default: the largest file, first on ties.
        let target = match &opts.pick_file {
            Some(pick) => {
                let tuples: Vec<(u64, String, u64)> = wanted
                    .iter()
                    .enumerate()
                    .map(|(index, file)| (index as u64, file.path.clone(), file.size))
                    .collect();
                pick(&tuples)?
            }
            None => wanted
                .iter()
                .enumerate()
                .fold(None, |best: Option<(usize, u64)>, (index, file)| match best {
                    Some((_, size)) if size >= file.size => best,
                    _ => Some((index, file.size)),
                })
                .map(|(index, _)| index),
        };

        let max_files = opts.max_files.unwrap_or(self.client.config.max_files);
        let target_path = target.and_then(|index| wanted.get(index)).map(|file| file.path.clone());
        let files = self.unlock_links(window_files(&wanted, target, max_files)).await?;
        if files.is_empty() {
            return Err(DebridError::Service {
                message: "AllDebrid returned no links for this torrent".to_string(),
                status: None,
                code: None,
            });
        }
        let files = secure_files(files, self.client.config.title)?;
        let name = magnet_info.get("filename").and_then(Value::as_str).unwrap_or("").to_string();
        Ok(DebridResolved { hash: hash.to_string(), name, files, target: target_path })
    }
}

#[async_trait]
impl DebridProvider for AllDebrid {
    fn client(&self) -> &crate::client::DebridClient {
        &self.client
    }

    fn config(&self) -> &ProviderConfig {
        &self.client.config
    }

    async fn validate(&self) -> Result<AccountInfo, DebridError> {
        let data = self.request(&format!("{V4}/user"), RequestOpts::default()).await?;
        let user = data.get("user").filter(|user| user.is_object()).ok_or_else(|| DebridError::Auth {
            message: "AllDebrid did not recognise this API key".to_string(),
            status: None,
            code: None,
        })?;
        if !truthy(user.get("isPremium")) && !truthy(user.get("isTrial")) {
            return Err(DebridError::Auth {
                message: "AllDebrid premium is required to stream torrents".to_string(),
                status: None,
                code: None,
            });
        }
        let username = user
            .get("username")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty())
            .or_else(|| user.get("email").and_then(Value::as_str).filter(|email| !email.is_empty()))
            .unwrap_or("AllDebrid user")
            .to_string();
        let expires = user
            .get("premiumUntil")
            .and_then(Value::as_i64)
            .filter(|seconds| *seconds != 0)
            .map(iso_from_unix_seconds);
        Ok(AccountInfo { username, expires })
    }

    /// Nothing to read: account entries carry no info hash, so none can be matched to a release.
    async fn list_availability(&self) -> Result<HashMap<String, Availability>, DebridError> {
        Ok(HashMap::new())
    }

    /// Uploads the hashes, reads the `ready` flag back, and removes everything this call added.
    /// The account is read first because an upload of a magnet it already holds answers with
    /// the existing entry, so without that read the cleanup would delete the user's own magnet.
    async fn check_availability_batch(
        &self,
        hashes: &[String],
    ) -> Result<HashMap<String, Availability>, DebridError> {
        let existing = self.account_ids().await?;
        let uploaded = self.upload(hashes).await?;
        let mut answers = HashMap::new();
        let mut ours = Vec::new();
        // every magnet this call adds is removed again below; if the future is dropped
        // before that loop runs, the guard owes each removal to the orphan list
        let mut cleanup = OrphanOnDrop::unarmed(&self.client);
        for entry in &uploaded {
            if let Some(id) = id_string(entry.get("id")) {
                if !existing.contains(&id) {
                    let (url, opts) = Self::delete_request(&id);
                    cleanup.arm(url, opts);
                    ours.push(id);
                }
            }
            let hash = entry
                .get("hash")
                .and_then(Value::as_str)
                .or_else(|| entry.get("magnet").and_then(Value::as_str))
                .and_then(parse_hash);
            let Some(hash) = hash else { continue };
            // a rejection about the release is an answer, one about the account being busy is not
            if let Some(error) = entry.get("error").filter(|error| error.is_object()) {
                let code = error.get("code").and_then(Value::as_str).unwrap_or("");
                if DEAD_CODES.contains(&code) {
                    answers.insert(hash, Availability::Unavailable);
                }
                continue;
            }
            let state = if truthy(entry.get("ready")) { Availability::Cached } else { Availability::Available };
            answers.insert(hash, state);
        }
        for id in &ours {
            self.delete(id).await;
        }
        cleanup.disarm();
        Ok(answers)
    }

    /// AllDebrid answers availability in batches off the upload response; there is no probe.
    async fn probe_availability(&self, _hash: &str) -> Result<Availability, DebridError> {
        Err(DebridError::Service {
            message: "AllDebrid answers availability in batches, not probes".to_string(),
            status: None,
            code: None,
        })
    }

    async fn resolve(&self, magnet: &str, opts: &ResolveOptions) -> Result<DebridResolved, DebridError> {
        let hash = parse_hash(magnet).unwrap_or_default();
        let magnet_uri = to_magnet(magnet).ok_or_else(|| DebridError::Service {
            message: "AllDebrid needs a magnet link or info hash to resolve".to_string(),
            status: None,
            code: None,
        })?;
        // as in the check: only ids that were not here a moment ago are ours to remove again
        let existing = self.account_ids().await?;
        let uploaded = self
            .upload(std::slice::from_ref(&magnet_uri))
            .await?
            .into_iter()
            .next()
            .unwrap_or(Value::Null);
        if let Some(error) = uploaded.get("error").filter(|error| error.is_object()) {
            return Err(upload_error(error));
        }
        let id = id_string(uploaded.get("id")).ok_or_else(|| DebridError::Service {
            message: "AllDebrid did not report the magnet back after adding it".to_string(),
            status: None,
            code: None,
        })?;
        let added = !existing.contains(&id);
        let mut cleanup = OrphanOnDrop::unarmed(&self.client);
        if added {
            let (url, opts) = Self::delete_request(&id);
            cleanup.arm(url, opts);
        }
        let resolved = self.resolve_ready(&uploaded, &id, &hash, opts).await;
        // the future survived to a verdict: a success keeps its magnet, the error arm
        // below deletes in person — either way the guard's removal is no longer owed
        cleanup.disarm();
        // only clean up a magnet this call put on the account, never the user's own
        if resolved.is_err() && added {
            self.delete(&id).await;
        }
        resolved
    }

    async fn retry_cleanup(&self) {
        self.client.retry_cleanup(&AllDebridDialect).await;
    }

}

/// `premiumUntil` epoch seconds as the ISO string the UI expects, matching JS toISOString.
/// Civil-from-days per Howard Hinnant's algorithms, so this crate stays chrono-free.
fn iso_from_unix_seconds(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let second_of_day = seconds.rem_euclid(86_400);
    let (hour, minute, second) =
        (second_of_day / 3_600, (second_of_day % 3_600) / 60, second_of_day % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = if month_prime < 10 { month_prime + 3 } else { month_prime - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.000Z")
}

// AllDebrid against a scripted transport, mirroring test/unit/debrid/alldebrid.test.js.
// No live key exists yet, so these pin the request shapes and the response handling the
// implementation was written against: the `{ status, data }` envelope, the upload response
// that doubles as the cache answer, and the nested file tree.
//
// The invariant these tests exist for: a check must never delete a magnet the user already had.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{ManualClock, MockTransport, Route};
    use serde_json::json;
    use shiru_networking::Body;

    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn magnet() -> String {
        format!("magnet:?xt=urn:btih:{HASH}&dn=test")
    }

    /// The envelope every AllDebrid response arrives in.
    fn ok(data: Value) -> String {
        json!({ "status": "success", "data": data }).to_string()
    }

    fn fail(code: &str) -> String {
        json!({ "status": "error", "error": { "code": code, "message": "nope" } }).to_string()
    }

    /// The status route, which every path through this client reads first.
    fn status_route(magnets: Value) -> Route {
        Route::json("magnet/status", 200, &ok(json!({ "magnets": magnets })))
    }

    fn delete_route() -> Route {
        Route::json("magnet/delete", 200, &ok(json!({ "message": "Magnet was successfully deleted" })))
    }

    /// The file tree AllDebrid answers with: `n` name, `s` size, `l` link, `e` folder children.
    fn tree() -> Value {
        json!([
            { "n": "Test Pack", "e": [
                { "n": "Episode 01.mkv", "s": 1000, "l": "https://alldebrid.test/f/1" },
                { "n": "readme.txt", "s": 10, "l": "https://alldebrid.test/f/2" }
            ]},
            { "n": "extra.mkv", "s": 2000, "l": "https://alldebrid.test/f/3" }
        ])
    }

    fn provider(routes: Vec<Route>) -> (AllDebrid, Arc<MockTransport>) {
        let transport = Arc::new(MockTransport::new(routes));
        let service = AllDebrid::new("test-key", transport.clone(), Arc::new(ManualClock::new()));
        (service, transport)
    }

    fn video_opts() -> ResolveOptions {
        ResolveOptions {
            file_filter: Some(Box::new(|name| name.ends_with(".mkv") || name.ends_with(".mp4"))),
            ..Default::default()
        }
    }

    fn body_text(request: &shiru_networking::HttpRequest) -> String {
        match &request.body {
            Some(Body::Bytes { bytes, .. }) => String::from_utf8_lossy(bytes).into_owned(),
            Some(Body::Multipart(fields)) => format!("{fields:?}"),
            None => String::new(),
        }
    }

    /// Form-decoded values for one key, e.g. every `magnets[]` a request carried.
    fn form_values(body: &str, key: &str) -> Vec<String> {
        body.split('&')
            .filter_map(|pair| pair.split_once('='))
            .filter(|(name, _)| percent_decode(name) == key)
            .map(|(_, value)| percent_decode(value))
            .collect()
    }

    fn percent_decode(value: &str) -> String {
        let bytes = value.as_bytes();
        let mut out = Vec::new();
        let mut index = 0;
        while index < bytes.len() {
            match bytes[index] {
                b'%' if index + 2 < bytes.len() => {
                    if let Ok(byte) = u8::from_str_radix(&value[index + 1..index + 3], 16) {
                        out.push(byte);
                        index += 3;
                        continue;
                    }
                    out.push(b'%');
                    index += 1;
                }
                b'+' => {
                    out.push(b' ');
                    index += 1;
                }
                byte => {
                    out.push(byte);
                    index += 1;
                }
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    fn requests_matching(transport: &MockTransport, needle: &str) -> Vec<String> {
        transport
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.url.contains(needle))
            .map(body_text)
            .collect()
    }

    #[tokio::test]
    async fn the_key_travels_as_a_bearer_header_never_in_the_url() {
        let (service, transport) = provider(vec![Route::json(
            "/v4/user",
            200,
            &ok(json!({ "user": { "username": "tester", "isPremium": true, "premiumUntil": 1_799_999_999 } })),
        )]);
        let account = service.validate().await.unwrap();
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests[0].headers.get("Authorization").map(String::as_str), Some("Bearer test-key"));
        assert!(!requests[0].url.contains("test-key"), "the key must stay out of logs and CDN caches");
        assert_eq!(account.username, "tester");
        let expires = account.expires.expect("the expiry is handed to the UI as a date string");
        assert!(expires.starts_with("2027-"), "epoch 1799999999 lands in 2027, got {expires}");
    }

    #[tokio::test]
    async fn an_account_without_premium_cannot_stream_torrents_and_is_told_so() {
        let (service, _) = provider(vec![Route::json(
            "/v4/user",
            200,
            &ok(json!({ "user": { "username": "tester", "isPremium": false, "isTrial": false } })),
        )]);
        assert!(matches!(service.validate().await, Err(DebridError::Auth { .. })));
    }

    #[tokio::test]
    async fn a_rejected_key_is_an_auth_error_whatever_the_http_status_says() {
        let (service, _) = provider(vec![Route::json("/v4/user", 200, &fail("AUTH_BAD_APIKEY"))]);
        match service.validate().await {
            Err(DebridError::Auth { message, .. }) => assert!(message.contains("Invalid AllDebrid API key")),
            other => panic!("expected an auth error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn one_upload_answers_a_whole_batch_of_hashes() {
        let (service, transport) = provider(vec![
            status_route(json!([])),
            Route::json(
                "magnet/upload",
                200,
                &ok(json!({ "magnets": [
                    { "hash": HASH, "id": 1, "ready": true },
                    { "hash": OTHER, "id": 2, "ready": false }
                ]})),
            ),
            delete_route(),
        ]);
        let answers = service
            .check_availability_batch(&[HASH.to_string(), OTHER.to_string()])
            .await
            .unwrap();
        assert_eq!(answers.get(HASH), Some(&Availability::Cached));
        assert_eq!(
            answers.get(OTHER),
            Some(&Availability::Available),
            "not ready means it would have to fetch it"
        );
        let uploads = requests_matching(&transport, "magnet/upload");
        assert_eq!(uploads.len(), 1, "both hashes go up in one request");
        assert_eq!(
            form_values(&uploads[0], "magnets[]").len(),
            2,
            "as two parameters, not one joined value"
        );
    }

    // the reason this client reads the account before it uploads anything: an upload of a
    // magnet the account already holds answers with the existing entry, so without that read
    // the cleanup below would delete one of the user's own magnets
    #[tokio::test]
    async fn a_check_removes_only_the_magnets_it_created_never_one_the_user_already_had() {
        let (service, transport) = provider(vec![
            status_route(json!([{ "id": 1, "filename": "Already Here", "statusCode": 4 }])),
            Route::json(
                "magnet/upload",
                200,
                &ok(json!({ "magnets": [
                    { "hash": HASH, "id": 1, "ready": true },
                    { "hash": OTHER, "id": 2, "ready": false }
                ]})),
            ),
            delete_route(),
        ]);
        service.check_availability_batch(&[HASH.to_string(), OTHER.to_string()]).await.unwrap();
        let deleted: Vec<String> = requests_matching(&transport, "magnet/delete")
            .iter()
            .flat_map(|body| form_values(body, "id"))
            .collect();
        assert_eq!(deleted, vec!["2"], "the magnet that was already on the account must survive the check");
    }

    #[tokio::test]
    async fn a_magnet_alldebrid_will_never_take_is_an_answer_and_a_busy_account_is_not() {
        let (service, _) = provider(vec![
            status_route(json!([])),
            Route::json(
                "magnet/upload",
                200,
                &ok(json!({ "magnets": [
                    { "magnet": HASH, "error": { "code": "MAGNET_INVALID_URI", "message": "no" } },
                    { "magnet": OTHER, "error": { "code": "MAGNET_TOO_MANY_ACTIVE", "message": "busy" } }
                ]})),
            ),
            delete_route(),
        ]);
        let answers = service
            .check_availability_batch(&[HASH.to_string(), OTHER.to_string()])
            .await
            .unwrap();
        assert_eq!(answers.get(HASH), Some(&Availability::Unavailable), "a rejected magnet is settled");
        assert!(
            !answers.contains_key(OTHER),
            "a busy account proves nothing about the release, so it stays unknown"
        );
    }

    // unlike a real cache endpoint, an upload answers about exactly the magnets it managed to
    // take, so a hash it never mentions has not been called uncached
    #[tokio::test]
    async fn a_hash_the_upload_never_mentions_stays_unknown_rather_than_being_badged() {
        let (service, _) = provider(vec![
            status_route(json!([])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 1, "ready": true }] }))),
            delete_route(),
        ]);
        let answers = service
            .check_availability_batch(&[HASH.to_string(), OTHER.to_string()])
            .await
            .unwrap();
        assert_eq!(answers.get(HASH), Some(&Availability::Cached));
        assert!(!answers.contains_key(OTHER));
    }

    #[tokio::test]
    async fn a_cached_release_is_uploaded_once_and_then_streamed() {
        let (service, transport) = provider(vec![
            status_route(json!([{ "id": 7, "filename": "Test Pack", "statusCode": 4, "files": tree() }])),
            Route::json(
                "magnet/upload",
                200,
                &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true, "name": "Test Pack" }] })),
            ),
            Route::json("link/unlock", 200, &ok(json!({ "link": "https://cdn.alldebrid.test/ok.mkv", "filesize": 1000 }))),
        ]);
        let resolved = service.resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.hash, HASH);
        assert_eq!(resolved.name, "Test Pack");
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        assert_eq!(
            paths,
            vec!["/Test Pack/Episode 01.mkv", "/extra.mkv"],
            "the file tree flattens into rooted paths, folders and all"
        );
        assert!(
            resolved.files.iter().all(|file| file.url.starts_with("https://cdn.")),
            "every file is unlocked into a direct link"
        );
        assert_eq!(
            requests_matching(&transport, "magnet/delete").len(),
            0,
            "a release that played stays on the account, like every other service"
        );
    }

    // asking about one magnet by id is documented to answer with its files inline; the
    // dedicated endpoint is the fallback for when it does not, since that is the shape most
    // likely to differ from the docs once this runs against a real account
    #[tokio::test]
    async fn a_status_read_without_a_file_tree_falls_back_to_the_files_endpoint() {
        let (service, transport) = provider(vec![
            status_route(json!([{ "id": 7, "filename": "Test Pack", "statusCode": 4 }])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true }] }))),
            Route::json("magnet/files", 200, &ok(json!({ "magnets": [{ "id": "7", "files": tree() }] }))),
            Route::json("link/unlock", 200, &ok(json!({ "link": "https://cdn.alldebrid.test/ok.mkv", "filesize": 1000 }))),
        ]);
        let resolved = service.resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.files.len(), 2);
        let files_bodies = requests_matching(&transport, "magnet/files");
        assert_eq!(form_values(&files_bodies[0], "id[]").len(), 1);
    }

    // the upload already said the release was ready, so an empty status read is the request
    // failing. Reporting that as "not cached" would badge a cached release wrong for the next
    // twenty minutes
    #[tokio::test]
    async fn a_status_read_that_comes_back_empty_is_a_failure_not_an_answer_about_the_release() {
        let (service, _) = provider(vec![
            status_route(json!([])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true }] }))),
            delete_route(),
        ]);
        let error = service.resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }), "got {error:?}");
        assert_eq!(error.proven_availability(), None, "nothing was proved about the release");
    }

    #[tokio::test]
    async fn an_uncached_release_is_taken_back_off_the_account_instead_of_left_downloading() {
        let (service, transport) = provider(vec![
            status_route(json!([])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 9, "ready": false }] }))),
            delete_route(),
        ]);
        let error = service.resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        assert_eq!(error.proven_availability(), Some(Availability::Available));
        let deleted: Vec<String> = requests_matching(&transport, "magnet/delete")
            .iter()
            .flat_map(|body| form_values(body, "id"))
            .collect();
        assert_eq!(deleted, vec!["9"]);
    }

    #[tokio::test]
    async fn a_release_the_account_already_held_is_never_deleted_by_a_failed_resolve() {
        let (service, transport) = provider(vec![
            status_route(json!([{ "id": 9, "filename": "The users own", "statusCode": 1 }])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 9, "ready": false }] }))),
            delete_route(),
        ]);
        let error = service.resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        assert_eq!(requests_matching(&transport, "magnet/delete").len(), 0);
    }

    #[tokio::test]
    async fn a_magnet_that_failed_on_the_account_is_unavailable_not_uncached() {
        let (service, _) = provider(vec![
            status_route(json!([{ "id": 7, "filename": "Broken", "statusCode": 15 }])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true }] }))),
            delete_route(),
        ]);
        let error = service.resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::Unavailable { .. }), "got {error:?}");
        assert_eq!(error.proven_availability(), Some(Availability::Unavailable));
    }

    #[tokio::test]
    async fn one_dead_file_in_a_pack_does_not_sink_the_whole_resolve() {
        // routes match first-wins on a URL substring, so the dead file's encoded link comes first
        let (service, _) = provider(vec![
            status_route(json!([{ "id": 7, "filename": "Test Pack", "statusCode": 4, "files": tree() }])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true }] }))),
            Route::json("f%2F1", 200, &fail("LINK_DOWN")),
            Route::json("link/unlock", 200, &ok(json!({ "link": "https://cdn.alldebrid.test/ok.mkv", "filesize": 1000 }))),
        ]);
        let resolved = service.resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.files.len(), 1, "the file that still works is streamed");
    }

    #[tokio::test]
    async fn an_auth_failure_while_unlocking_still_surfaces_as_an_auth_error() {
        let (service, _) = provider(vec![
            status_route(json!([{ "id": 7, "filename": "Test Pack", "statusCode": 4, "files": tree() }])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true }] }))),
            Route::json("link/unlock", 200, &fail("AUTH_BAD_APIKEY")),
            delete_route(),
        ]);
        let error = service.resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }), "got {error:?}");
    }

    #[test]
    fn being_told_the_account_is_busy_stops_a_sweep_rather_than_counting_against_the_release() {
        let busy = DebridError::Service {
            message: "busy".to_string(),
            status: None,
            code: Some("MAGNET_TOO_MANY_ACTIVE".to_string()),
        };
        assert!(AllDebrid::is_throttled(&busy));
        let limited = DebridError::Service { message: "slow down".to_string(), status: Some(429), code: None };
        assert!(AllDebrid::is_throttled(&limited));
        let dead = DebridError::Service {
            message: "dead".to_string(),
            status: None,
            code: Some("LINK_DOWN".to_string()),
        };
        assert!(!AllDebrid::is_throttled(&dead));
    }

    // magnet/status describes a magnet by name and progress and never says which info hash it
    // came from, so there is nothing to badge from it. It must answer empty rather than throw
    #[tokio::test]
    async fn the_account_listing_yields_no_badges_because_it_carries_no_info_hashes() {
        let (service, transport) = provider(vec![]);
        assert!(service.list_availability().await.unwrap().is_empty());
        assert!(transport.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn resolve_refuses_a_source_it_cannot_turn_into_a_hash_instead_of_guessing() {
        let (service, transport) = provider(vec![]);
        let error = service
            .resolve("https://nyaa.si/download/1.torrent", &ResolveOptions::default())
            .await
            .unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }));
        assert!(transport.requests.lock().unwrap().is_empty(), "it never touches the network");
    }

    #[tokio::test]
    async fn pick_file_windows_the_pack_around_the_chosen_index() {
        // a pack larger than max_files, with the wanted episode near the end
        let entries: Vec<Value> = (1..=8)
            .map(|index| {
                json!({ "n": format!("Episode {index:02}.mkv"), "s": 1000, "l": format!("https://alldebrid.test/f/{index}") })
            })
            .collect();
        let (service, _) = provider(vec![
            status_route(json!([{ "id": 7, "filename": "Big Pack", "statusCode": 4, "files": entries }])),
            Route::json("magnet/upload", 200, &ok(json!({ "magnets": [{ "hash": HASH, "id": 7, "ready": true }] }))),
            Route::json("link/unlock", 200, &ok(json!({ "link": "https://cdn.alldebrid.test/ok.mkv", "filesize": 1000 }))),
        ]);
        let opts = ResolveOptions {
            pick_file: Some(Box::new(|files| {
                Ok(files.iter().position(|(_, path, _)| path.ends_with("Episode 07.mkv")))
            })),
            max_files: Some(3),
            ..Default::default()
        };
        let resolved = service.resolve(&magnet(), &opts).await.unwrap();
        assert_eq!(resolved.files.len(), 3, "the cap holds");
        assert!(
            resolved.files.iter().any(|file| file.path.ends_with("Episode 07.mkv")),
            "the requested episode survives its own window"
        );
    }
}
