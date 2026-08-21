//! TorBox implementation, see https://api-docs.torbox.app/
//! Port of common/modules/debrid/torbox.js; test/unit/debrid/torbox*.test.js are the
//! behavioural reference.
//!
//! Three things shape this client: `/torrents/checkcached` answers many hashes in one
//! request, every response is wrapped in `{ success, data }` with failures arriving
//! inside a 200, and `/torrents/requestdl` authenticates with a `token` query parameter
//! rather than a bearer header.

use crate::client::{DebridClient, Dialect, RequestOpts};
use crate::error::DebridError;
use crate::platform::Platform;
use crate::window::window_files;
use crate::{
    AccountInfo, AuthScheme, AvailabilityCheck, BodyEncoding, DebridProvider, ProviderConfig,
    ResolveOptions, Timeouts,
};
use async_trait::async_trait;
use serde_json::Value;
use shiru_domain::{parse_hash, to_magnet, Availability, DebridFile, DebridResolved};
use shiru_networking::{HttpTransport, Method};
use std::collections::HashMap;
use std::sync::Arc;

const API: &str = "https://api.torbox.app/v1/api";

/// How long TorBox account reads are given. They normally answer in well under a second, and
/// have repeatedly accepted a connection without returning a body. Account reads sit ahead of
/// both validation and cold-start playback, so they get a smaller budget than a media link.
const ACCOUNT_TIMEOUT_MS: u64 = 10_000;
/// Once the selected file has a direct URL, neighboring pack links may use this much
/// more time for subtitles and in-player navigation. A silent neighbor must never hide
/// an already playable episode until the manager's 60-second deadline.
const OPTIONAL_LINK_GRACE_MS: u64 = 2_000;
/// The whole account in one request; the API pages at 1000.
const LIST_LIMIT: u64 = 1_000;
/// 1 auto, 2 always, 3 never. Shiru only streams, so never seed.
const SEED_NEVER: u64 = 3;

/// Error codes worth explaining, anything else falls back to the API's own detail line.
fn explain(code: &str) -> Option<&'static str> {
    Some(match code {
        "BAD_TOKEN" => "Invalid TorBox API key",
        "AUTH_ERROR" => "TorBox rejected the API key",
        "NO_AUTH" => "TorBox requires an API key for this request",
        "PLAN_RESTRICTED_FEATURE" => "This TorBox plan does not include the feature Shiru needs",
        "ACTIVE_LIMIT" => "Too many active TorBox downloads, wait for one to finish",
        "MONTHLY_LIMIT" => "This TorBox account has reached its monthly limit",
        "COOLDOWN_LIMIT" => "TorBox is cooling this account down, try again shortly",
        "DOWNLOAD_TOO_LARGE" => "This release is larger than the TorBox plan allows",
        "DOWNLOAD_SERVER_ERROR" => "TorBox could not reach its download server, try again shortly",
        "NO_SERVERS_AVAILABLE_ERROR" => "No TorBox download servers are available right now",
        _ => return None,
    })
}

/// Only these mean the key or plan is the problem, the rest are per-request.
fn is_auth_code(code: &str) -> bool {
    matches!(code, "BAD_TOKEN" | "AUTH_ERROR" | "NO_AUTH" | "PLAN_RESTRICTED_FEATURE")
}

/// `download_state` values that mean the torrent will never finish on its own.
/// Ports the JS `/(stalled|error|failed|missing)/i` substring test without a regex.
fn is_dead_state(state: &str) -> bool {
    let lower = state.to_ascii_lowercase();
    ["stalled", "error", "failed", "missing"].iter().any(|dead| lower.contains(dead))
}

struct TorBoxDialect;

impl Dialect for TorBoxDialect {
    /// Failures arrive inside a 200, so success is decided here rather than by the status code.
    fn unwrap(&self, json: Value) -> Result<Value, DebridError> {
        let Some(envelope) = json.as_object() else { return Ok(json) };
        if !envelope.contains_key("success") {
            return Ok(json);
        }
        if !envelope.get("success").and_then(Value::as_bool).unwrap_or(false) {
            return Err(self.map_error(200, Some(&json)));
        }
        Ok(envelope.get("data").cloned().unwrap_or(Value::Null))
    }

    fn map_error(&self, status: u16, json: Option<&Value>) -> DebridError {
        let code = json.and_then(|value| value.get("error")).and_then(Value::as_str);
        // `detail` is usually a sentence, but a rejected request answers with a list of field
        // problems instead, which is for the log rather than the user
        let detail = json
            .and_then(|value| value.get("detail"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let message = code
            .and_then(explain)
            .map(str::to_string)
            .or_else(|| (!detail.is_empty()).then(|| detail.to_string()))
            .or_else(|| code.map(str::to_string))
            .unwrap_or_else(|| format!("Request failed with status {status}"));
        let code_owned = code.map(str::to_string);
        if code.is_some_and(is_auth_code) || ((status == 401 || status == 403) && code.is_none()) {
            DebridError::Auth { message, status: Some(status), code: code_owned }
        } else {
            DebridError::Service { message, status: Some(status), code: code_owned }
        }
    }
}

pub struct TorBox {
    client: DebridClient,
}

/// One torrent file worth linking: the API id, the rooted path, size and MIME type.
struct WantedFile {
    id: u64,
    path: String,
    size: u64,
    mime: Option<String>,
}

impl TorBox {
    pub fn new(api_key: String, transport: Arc<dyn HttpTransport>, platform: Arc<dyn Platform>) -> Self {
        let config = ProviderConfig {
            id: "torbox",
            title: "TorBox",
            auth: AuthScheme::Bearer,
            auth_param: "token",
            encoding: BodyEncoding::Form,
            timeouts: Timeouts::default(),
            nominal_latency: 300,
            // measured live: a 60-link burst against /torrents/requestdl earned a 429 with
            // retry-after: 300 — five minutes of the account frozen mid-play. A dozen links
            // keeps next/previous episode working while staying far inside the real allowance
            max_files: 12,
            // a real cache endpoint, so badges cost one request for the whole results list
            availability_check: AvailabilityCheck::Batch,
            check_adds_magnets: false,
            // hashes travel as repeated query parameters, so the chunk size keeps the URL sane
            max_batch: 75,
            max_probes: 10,
            max_concurrent: 3,
            min_time_ms: 200,
            // documented allowance is 300 a minute per endpoint; spending it as if it
            // covered all of them keeps a season pack's worth of link requests well inside
            reservoir: Some((300, 60_000)),
        };
        TorBox { client: DebridClient::new(config, api_key, transport, platform) }
    }

    async fn request(&self, url: &str, opts: RequestOpts) -> Result<Value, DebridError> {
        self.client.request(&TorBoxDialect, url, opts).await
    }

    /// The account's torrents. TorBox caches this itself, which is faster for the badge
    /// listing; `bypass_cache` is only worth its latency when polling a change just made.
    async fn account_torrents(&self, id: Option<&Value>, fresh: bool) -> Result<Vec<Value>, DebridError> {
        let mut query = format!("limit={LIST_LIMIT}");
        if let Some(id) = id {
            query.push_str(&format!("&id={}", value_text(id)));
        }
        if fresh {
            query.push_str("&bypass_cache=true");
        }
        let opts = RequestOpts { timeout_ms: Some(ACCOUNT_TIMEOUT_MS), ..RequestOpts::default() };
        let data = self.request(&format!("{API}/torrents/mylist?{query}"), opts).await?;
        // asking for one id answers with a bare object rather than a list
        Ok(match data {
            Value::Null => vec![],
            Value::Array(items) => items,
            other => vec![other],
        })
    }

    /// The whole account, read at most once a minute and shared between the badge
    /// refresh and every resolve. Reading it per play put a thousand-entry response on
    /// the play path, ahead of the link requests the user is actually waiting for.
    async fn listing(&self) -> Result<Vec<Value>, DebridError> {
        let cached = self
            .client
            .listing(false, || async {
                Ok(Value::Array(self.account_torrents(None, false).await?))
            })
            .await?;
        Ok(cached.as_array().cloned().unwrap_or_default())
    }

    /// The account's entry for an info hash, which is how a release already there is reused
    /// rather than added twice. The normal listing is already TTL-bound and `requestdl` is the
    /// authoritative test of whether its id still streams. Do not put a `bypass_cache` read in
    /// front of every play: TorBox has accepted that request and then stayed silent while both
    /// the listing and link endpoints remained healthy, turning a cached episode into a 60s
    /// resolve timeout.
    async fn existing_torrent(&self, hash: &str) -> Result<Option<Value>, DebridError> {
        Ok(self
            .listing()
            .await?
            .into_iter()
            .find(|torrent| torrent_hash(torrent).as_deref() == Some(hash)))
    }

    /// Adds a magnet and reads back the account entry for it. The returned flag reports
    /// whether this call is what put it there, which is the only thing that makes it ours
    /// to remove again.
    async fn add(&self, magnet_uri: &str, hash: &str) -> Result<(Value, bool), DebridError> {
        // allow_zip off keeps a pack as individual files rather than one archive the player
        // cannot seek in
        let created = match self
            .request(
                &format!("{API}/torrents/createtorrent"),
                RequestOpts {
                    method: Some(Method::Post),
                    encoding: Some(BodyEncoding::Multipart),
                    body: Some(vec![
                        ("magnet".into(), Value::String(magnet_uri.into())),
                        ("seed".into(), Value::from(SEED_NEVER)),
                        ("allow_zip".into(), Value::Bool(false)),
                    ]),
                    ..RequestOpts::default()
                },
            )
            .await
        {
            Ok(value) => Some(value),
            // the account already held it, which is an answer rather than a failure
            Err(error) if error_code(&error) == Some("DUPLICATE_ITEM") => None,
            Err(error) => return Err(error),
        };
        let id = created
            .as_ref()
            .and_then(|value| value.get("torrent_id"))
            .filter(|value| !value.is_null())
            .cloned();
        match self.await_torrent(id.as_ref(), hash).await {
            Ok(torrent) => {
                // the account changed by exactly this entry, and this is that entry read
                // back — amend the remembered listing rather than dropping it, so the
                // next episode's resolve does not pay a fresh thousand-entry read for a
                // change this client just made itself
                self.client
                    .amend_listing(torrent.clone(), |ours, theirs| {
                        torrent_hash(ours).is_some() && torrent_hash(ours) == torrent_hash(theirs)
                    })
                    .await;
                Ok((torrent, id.is_some()))
            }
            Err(error) => {
                // awaited, so this call has undone itself by the time it reports failure
                if let Some(id) = id.as_ref() {
                    self.delete(id).await;
                    // if the delete quietly failed the account holds a torrent the
                    // listing does not; the next read is worth paying for
                    self.client.forget_listing().await;
                }
                Err(error)
            }
        }
    }

    /// Waits for a freshly added torrent to show up and settle. A cached release is complete
    /// the moment TorBox accepts it, so anything slower reads as a fresh download.
    async fn await_torrent(&self, id: Option<&Value>, hash: &str) -> Result<Value, DebridError> {
        let started = self.client.platform().now_ms();
        loop {
            // deliberately uncached: this is polling a change made a moment ago
            let torrent = match id {
                Some(id) => self.account_torrents(Some(id), true).await?.into_iter().next(),
                None => self
                    .account_torrents(None, true)
                    .await?
                    .into_iter()
                    .find(|entry| torrent_hash(entry).as_deref() == Some(hash)),
            };
            if let Some(found) = &torrent {
                if torrent_availability(found) != Availability::Available {
                    return Ok(torrent.unwrap());
                }
            }
            let elapsed = self.client.platform().now_ms().saturating_sub(started);
            if elapsed > self.client.budget(self.client.config.timeouts.ready) {
                return torrent.ok_or_else(|| DebridError::Service {
                    message: "TorBox did not report the torrent back after adding it".into(),
                    status: None,
                    code: None,
                });
            }
            self.client.platform().sleep(self.client.config.timeouts.poll).await;
        }
    }

    /// Turns one torrent file into a direct stream link. This one endpoint takes the key
    /// as a query parameter instead of the bearer header used by the rest of TorBox.
    async fn request_link(
        &self,
        torrent_id: &Value,
        file: &WantedFile,
    ) -> Result<Option<DebridFile>, DebridError> {
        let url = format!(
            "{API}/torrents/requestdl?torrent_id={}&file_id={}&redirect=false",
            value_text(torrent_id),
            file.id
        );
        let opts = RequestOpts {
            auth: Some(AuthScheme::Query),
            auth_param: Some("token"),
            ..RequestOpts::default()
        };
        let Value::String(link) = self.request(&url, opts).await? else { return Ok(None) };
        Ok(Some(DebridFile {
            name: file.path.rsplit('/').next().unwrap_or("").to_string(),
            path: file.path.clone(),
            size: file.size,
            url: link,
            r#type: file.mime.clone(),
        }))
    }

    /// Turns the wanted files into direct stream links, skipping dead ones. The played file's
    /// request goes to the front of the queue: TorBox rate limits this endpoint well below its
    /// documented allowance, and when a batch trips that, the episode the user asked for must
    /// be the one request that already went through. Neighbor requests still overlap it, but
    /// after it answers they only get a short grace period to finish.
    async fn request_links(
        &self,
        torrent_id: &Value,
        wanted: &[WantedFile],
        target_path: Option<&str>,
    ) -> Result<Vec<DebridFile>, DebridError> {
        let target_index = target_path
            .and_then(|target| wanted.iter().position(|file| file.path == target))
            .unwrap_or(0);
        let target = &wanted[target_index];
        let neighbors: Vec<&WantedFile> = wanted
            .iter()
            .enumerate()
            .filter_map(|(index, file)| (index != target_index).then_some(file))
            .collect();

        // Poll the target side first so it takes the first limiter ticket. The neighbor
        // side is polled in the same turn, retaining the concurrency that makes packs fast.
        let target_work = Box::pin(self.request_link(torrent_id, target));
        let completed_neighbors = Arc::new(std::sync::Mutex::new(Vec::new()));
        let neighbor_results = completed_neighbors.clone();
        let neighbors_work = Box::pin(crate::client::map_files(&neighbors, |file| {
            let neighbor_results = neighbor_results.clone();
            async move {
                let linked = self.request_link(torrent_id, file).await?;
                if let Some(linked) = linked.as_ref() {
                    neighbor_results
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .push(linked.clone());
                }
                Ok(linked)
            }
        }));
        let (target_link, neighbor_links) = match futures::future::select(target_work, neighbors_work).await {
            futures::future::Either::Left((target_link, neighbors_work)) => {
                let target_link = target_link?;
                let grace = Box::pin(self.client.platform().sleep(OPTIONAL_LINK_GRACE_MS));
                let neighbors = match futures::future::select(neighbors_work, grace).await {
                    futures::future::Either::Left((links, _)) => links?,
                    futures::future::Either::Right((_, mut neighbors_work)) => {
                        // A limiter sleep or response can wake on the same turn as the
                        // deadline. Give already-runnable work enough cooperative polls to
                        // empty its queue; this adds no wall-clock wait and a genuinely
                        // silent request remains pending and is dropped below.
                        let mut ready = None;
                        for _ in 0..(neighbors.len() * 2 + 1) {
                            match futures::poll!(neighbors_work.as_mut()) {
                                std::task::Poll::Ready(links) => {
                                    ready = Some(links?);
                                    break;
                                }
                                std::task::Poll::Pending => self.client.platform().sleep(0).await,
                            }
                        }
                        tracing::debug!(target: "debrid", "returning the selected TorBox link without a silent pack neighbor");
                        ready.unwrap_or_else(|| {
                            completed_neighbors
                                .lock()
                                .unwrap_or_else(|poisoned| poisoned.into_inner())
                                .clone()
                        })
                    }
                };
                (target_link, neighbors)
            }
            futures::future::Either::Right((neighbors, target_work)) => (target_work.await?, neighbors?),
        };
        let Some(target_link) = target_link else {
            return Err(DebridError::Service {
                message: "TorBox returned no link for the selected file".into(),
                status: None,
                code: None,
            });
        };
        let mut files = Vec::with_capacity(neighbor_links.len() + 1);
        files.push(target_link);
        files.extend(neighbor_links);
        // hand the caller torrent order back, whatever order the requests went out in
        let position: HashMap<&str, usize> = wanted
            .iter()
            .enumerate()
            .map(|(index, file)| (file.path.as_str(), index))
            .collect();
        files.sort_by_key(|file| position.get(file.path.as_str()).copied().unwrap_or(usize::MAX));
        Ok(files)
    }

    /// Best-effort removal of a torrent this call created, never surfacing its own failure.
    /// A removal that fails is remembered by the client and retried before the next check
    /// adds anything, so a dropped link cannot leave a torrent on the account.
    async fn delete(&self, id: &Value) {
        self.client
            .release(
                &TorBoxDialect,
                &format!("{API}/torrents/controltorrent"),
                RequestOpts {
                    method: Some(Method::Post),
                    encoding: Some(BodyEncoding::Json),
                    body: Some(vec![
                        ("torrent_id".into(), id.clone()),
                        ("operation".into(), Value::String("delete".into())),
                    ]),
                    ..RequestOpts::default()
                },
            )
            .await;
    }

    /// The resolve body; `resolve` wraps it so a failure after adding still cleans up.
    async fn resolve_inner(
        &self,
        hash: &str,
        magnet_uri: &str,
        torrent: &mut Option<Value>,
        added: &mut bool,
        opts: &ResolveOptions,
    ) -> Result<DebridResolved, DebridError> {
        if torrent.is_none() {
            // ask before adding: the answer is free, and adding an uncached torrent spends
            // from a much tighter allowance (60 an hour) than a cached add does. The sweep
            // that filled the badge the user just clicked already asked, so a remembered
            // Cached answer skips the roundtrip — if it went stale inside its TTL the add
            // below still fails as not-cached, one hop later and rarely
            if self.client.recall(hash) != Some(Availability::Cached) {
                let answers = self.check_availability_batch(&[hash.to_string()]).await?;
                if answers.get(hash) != Some(&Availability::Cached) {
                    return Err(DebridError::not_cached());
                }
            }
            let (found, was_added) = self.add(magnet_uri, hash).await?;
            *torrent = Some(found);
            *added = was_added;
        }
        let torrent = torrent.as_ref().expect("ensured above");
        let state = torrent_availability(torrent);
        if state == Availability::Unavailable {
            let download_state = torrent.get("download_state").and_then(Value::as_str).unwrap_or("failed");
            return Err(DebridError::Unavailable {
                message: format!("TorBox could not process this torrent ({download_state})"),
            });
        }
        if state != Availability::Cached {
            return Err(DebridError::not_cached());
        }

        let empty = vec![];
        let wanted: Vec<WantedFile> = torrent
            .get("files")
            .and_then(Value::as_array)
            .unwrap_or(&empty)
            .iter()
            .filter(|file| {
                let path = file_path(file);
                opts.file_filter.as_ref().is_none_or(|filter| filter(&path))
            })
            .map(|file| WantedFile {
                id: file.get("id").and_then(Value::as_u64).unwrap_or(0),
                path: file_path(file),
                size: file.get("size").and_then(Value::as_u64).unwrap_or(0),
                mime: file.get("mimetype").and_then(Value::as_str).map(str::to_string),
            })
            .collect();
        if wanted.is_empty() {
            return Err(DebridError::Service {
                message: "No playable files in this torrent".into(),
                status: None,
                code: None,
            });
        }

        let candidates: Vec<(u64, String, u64)> =
            wanted.iter().map(|file| (file.id, file.path.clone(), file.size)).collect();
        let target = match &opts.pick_file {
            Some(pick) => pick(&candidates)?,
            // largest file, first on a tie, like the JS stable size sort
            None => {
                let mut best = 0;
                for (index, file) in wanted.iter().enumerate() {
                    if file.size > wanted[best].size {
                        best = index;
                    }
                }
                Some(best)
            }
        };
        let max_files = opts.max_files.unwrap_or(self.client.config.max_files);
        let windowed = window_files(&wanted, target, max_files);
        let target_path = target.and_then(|index| wanted.get(index)).map(|file| file.path.clone());
        let torrent_id = torrent.get("id").cloned().unwrap_or(Value::Null);
        let files = self.request_links(&torrent_id, windowed, target_path.as_deref()).await?;
        if files.is_empty() {
            return Err(DebridError::Service {
                message: "TorBox returned no links for this torrent".into(),
                status: None,
                code: None,
            });
        }
        let resolved_hash = torrent_hash(torrent).unwrap_or_else(|| hash.to_string());
        let name = torrent.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        Ok(DebridResolved { hash: resolved_hash, name, files, target: target_path })
    }
}

#[async_trait]
impl DebridProvider for TorBox {
    fn client(&self) -> &crate::client::DebridClient {
        &self.client
    }

    fn config(&self) -> &ProviderConfig {
        &self.client.config
    }

    async fn validate(&self) -> Result<AccountInfo, DebridError> {
        let opts = RequestOpts { timeout_ms: Some(ACCOUNT_TIMEOUT_MS), ..RequestOpts::default() };
        let user = match self.request(&format!("{API}/user/me?settings=false"), opts).await {
            Ok(user) => user,
            // TorBox has had `/user/me` accept authenticated requests and never answer them while
            // the rest of the API kept working. The question being asked is only "does this key
            // work", and a listing that comes back answers it: the key is good and the account is
            // reachable, we just cannot name the plan it is on. Refusing to configure a working
            // key because one endpoint is unwell helps nobody — but a key the service actively
            // refuses is still refused, which is the arm below.
            Err(error @ (DebridError::Timeout { .. } | DebridError::Service { .. })) => {
                self.listing().await.map_err(|_| error)?;
                return Ok(AccountInfo { username: "TorBox user".into(), expires: None });
            }
            Err(error) => return Err(error),
        };
        if user.is_null() {
            return Err(DebridError::Auth {
                message: "TorBox did not recognise this API key".into(),
                status: None,
                code: None,
            });
        }
        let username = user
            .get("email")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .or_else(|| user.get("customer").and_then(Value::as_str).filter(|value| !value.is_empty()))
            .unwrap_or("TorBox user")
            .to_string();
        let expires = user.get("premium_expires_at").and_then(Value::as_str).map(str::to_string);
        Ok(AccountInfo { username, expires })
    }

    async fn list_availability(&self) -> Result<HashMap<String, Availability>, DebridError> {
        let mut known = HashMap::new();
        for torrent in self.listing().await? {
            let Some(hash) = torrent_hash(&torrent) else { continue };
            known.insert(hash.clone(), torrent_availability(&torrent));
            if let Some(name) = torrent.get("name").and_then(Value::as_str) {
                self.client.remember_release(&hash, name);
            }
        }
        Ok(known)
    }

    /// One request answers the whole results list. Hashes left out are not cached, which
    /// reads as available: TorBox would fetch them, not that it cannot.
    async fn check_availability_batch(
        &self,
        hashes: &[String],
    ) -> Result<HashMap<String, Availability>, DebridError> {
        let query: String = hashes.iter().map(|hash| format!("hash={hash}")).collect::<Vec<_>>().join("&");
        let data = self
            .request(&format!("{API}/torrents/checkcached?{query}&format=list"), RequestOpts::default())
            .await?;
        // the endpoint has answered in both shapes over its life: a list of entries, or an
        // object keyed by hash. Either way it only ever says "TorBox holds this one"
        let entries: Vec<Value> = match data {
            Value::Array(items) => items,
            Value::Object(map) => map
                .into_iter()
                .map(|(hash, entry)| {
                    let mut entry = if entry.is_object() { entry } else { Value::Object(Default::default()) };
                    if let Some(fields) = entry.as_object_mut() {
                        // like the JS `{ hash, ...entry }` spread, an entry's own hash wins
                        fields.entry("hash").or_insert(Value::String(hash));
                    }
                    entry
                })
                .collect(),
            _ => vec![],
        };
        let mut answers: HashMap<String, Availability> =
            hashes.iter().map(|hash| (hash.clone(), Availability::Available)).collect();
        for entry in entries {
            let key = entry
                .get("hash")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let Some(state) = answers.get_mut(&key) else { continue };
            *state = Availability::Cached;
            // the endpoint names the release it is answering about, which is worth far more
            // than the title a search source made up for it
            if let Some(name) = entry.get("name").and_then(Value::as_str) {
                self.client.remember_release(&key, name);
            }
        }
        Ok(answers)
    }

    /// TorBox has a real cache endpoint, so the batch path answers everything; the JS base
    /// class would never route a probe to a batch service.
    async fn probe_availability(&self, _hash: &str) -> Result<Availability, DebridError> {
        Err(DebridError::Service {
            message: "TorBox answers availability in batches, probing is never needed".into(),
            status: None,
            code: None,
        })
    }

    async fn resolve(&self, magnet: &str, opts: &ResolveOptions) -> Result<DebridResolved, DebridError> {
        let Some(hash) = parse_hash(magnet) else {
            return Err(DebridError::Service {
                message: "TorBox needs a magnet link or info hash to resolve".into(),
                status: None,
                code: None,
            });
        };
        let magnet_uri = to_magnet(magnet).expect("parse_hash found a hash");
        let mut torrent = self.existing_torrent(&hash).await?;
        let mut added = false;
        let result = self.resolve_inner(&hash, &magnet_uri, &mut torrent, &mut added, opts).await;
        if result.is_err() && added {
            // only clean up a torrent this call put on the account, never the user's own
            if let Some(id) = torrent.as_ref().and_then(|entry| entry.get("id")).filter(|id| !id.is_null()) {
                self.delete(id).await;
            }
        }
        result
    }

    async fn retry_cleanup(&self) {
        self.client.retry_cleanup(&TorBoxDialect).await;
    }

}

/// What the account says about one of its torrents. `download_present` means the data really
/// is on TorBox's servers, which is the only thing that makes a release streamable now.
fn torrent_availability(torrent: &Value) -> Availability {
    let finished = truthy(torrent.get("download_finished"))
        && torrent.get("progress").and_then(Value::as_f64) == Some(1.0);
    if truthy(torrent.get("download_present")) || finished {
        return Availability::Cached;
    }
    if is_dead_state(torrent.get("download_state").and_then(Value::as_str).unwrap_or("")) {
        return Availability::Unavailable;
    }
    Availability::Available
}

/// Full path is in `name`, bare filename in `short_name`, neither rooted. Shiru's file
/// objects are.
fn file_path(file: &Value) -> String {
    let path = file
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .or_else(|| file.get("short_name").and_then(Value::as_str).filter(|value| !value.is_empty()))
        .unwrap_or("");
    if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    }
}

/// A torrent's lowercase info hash, `None` when the entry has none.
fn torrent_hash(torrent: &Value) -> Option<String> {
    torrent
        .get("hash")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase)
}

/// JS truthiness for the flags TorBox sends as booleans, numbers or nothing at all.
fn truthy(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().is_some_and(|value| value != 0.0),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Null) | None => false,
        Some(_) => true,
    }
}

/// A JSON scalar as query-parameter text: strings bare, numbers as printed.
fn value_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// The API error code a typed error carries, when it carries one.
fn error_code(error: &DebridError) -> Option<&str> {
    match error {
        DebridError::Auth { code, .. } | DebridError::Service { code, .. } => code.as_deref(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{ManualClock, MockTransport, Route};
    use serde_json::json;
    use shiru_networking::Body;

    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const MAGNET: &str = "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=test";

    /// The envelope every TorBox response arrives in.
    fn ok(data: Value) -> String {
        json!({ "success": true, "error": null, "detail": "ok", "data": data }).to_string()
    }

    fn fail(error: &str, detail: &str) -> String {
        json!({ "success": false, "error": error, "detail": detail, "data": null }).to_string()
    }

    fn torrent(overrides: Value) -> Value {
        let mut base = json!({
            "id": 42,
            "hash": HASH.to_uppercase(),
            "name": "Test Torrent",
            "download_state": "completed",
            "download_finished": true,
            "download_present": true,
            "progress": 1,
            "files": [
                { "id": 0, "name": "Test/Episode 01.mkv", "short_name": "Episode 01.mkv", "size": 1000, "mimetype": "video/x-matroska" },
                { "id": 1, "name": "Test/readme.txt", "short_name": "readme.txt", "size": 10, "mimetype": "text/plain" },
                { "id": 2, "name": "Test/Episode 02.mkv", "short_name": "Episode 02.mkv", "size": 2000, "mimetype": "video/x-matroska" }
            ]
        });
        for (key, value) in overrides.as_object().cloned().unwrap_or_default() {
            base[key] = value;
        }
        base
    }

    fn service(routes: Vec<Route>) -> (TorBox, Arc<MockTransport>) {
        let transport = Arc::new(MockTransport::new(routes));
        let clock = Arc::new(ManualClock::new());
        (TorBox::new("test-key".into(), transport.clone(), clock), transport)
    }

    fn video_filter() -> ResolveOptions {
        ResolveOptions {
            file_filter: Some(Box::new(|name: &str| {
                let lower = name.to_ascii_lowercase();
                lower.ends_with(".mkv") || lower.ends_with(".mp4")
            })),
            ..ResolveOptions::default()
        }
    }

    // --- the { success, data } envelope, which decides success rather than the status code ---

    #[test]
    fn unwrap_hands_back_the_data_of_a_successful_envelope() {
        let data = TorBoxDialect.unwrap(json!({ "success": true, "data": { "email": "a@b" } })).unwrap();
        assert_eq!(data, json!({ "email": "a@b" }));
    }

    #[test]
    fn unwrap_passes_a_non_envelope_body_through_untouched() {
        let body = json!({ "torrent_id": 42 });
        assert_eq!(TorBoxDialect.unwrap(body.clone()).unwrap(), body);
    }

    #[test]
    fn a_failure_inside_a_200_becomes_a_typed_error() {
        let error = TorBoxDialect
            .unwrap(json!({ "success": false, "error": "BAD_TOKEN", "detail": "nope", "data": null }))
            .unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }), "a bad key must abort rather than be retried");
        assert!(error.to_string().contains("API key"));
    }

    #[test]
    fn a_bare_401_with_no_code_still_reads_as_an_auth_failure() {
        let error = TorBoxDialect.map_error(401, None);
        assert!(matches!(error, DebridError::Auth { .. }));
    }

    #[test]
    fn an_unknown_error_code_still_reports_what_the_api_said() {
        let json = json!({ "success": false, "error": "SOME_NEW_CODE", "detail": "the disk fell over" });
        let error = TorBoxDialect.map_error(500, Some(&json));
        assert!(matches!(error, DebridError::Service { .. }));
        assert!(error.to_string().contains("disk fell over"));
    }

    #[tokio::test]
    async fn a_key_still_validates_when_only_the_account_endpoint_is_unwell() {
        // TorBox, live on 2026-08-19: `/user/me` accepted authenticated requests and never
        // answered them, while `/torrents/mylist` kept working. The key was fine; the app just
        // could not be told so, and the settings screen refused to accept it.
        let (torbox, _) = service(vec![
            Route::timeout("/user/me", 30_000),
            Route::json("/torrents/mylist", 200, &ok(json!([]))),
        ]);
        let account = torbox.validate().await.expect("a listing that answers proves the key works");
        assert_eq!(account.username, "TorBox user", "the plan cannot be named, but the key is good");
    }

    #[tokio::test]
    async fn a_key_the_service_refuses_is_still_refused() {
        let (torbox, _) = service(vec![
            Route::timeout("/user/me", 30_000),
            Route::offline("/torrents/mylist"),
        ]);
        assert!(torbox.validate().await.is_err(), "nothing answered, so nothing was proven");
    }

    #[tokio::test]
    async fn validate_reads_the_account_behind_the_key() {
        let (torbox, _) = service(vec![Route::json(
            "/user/me",
            200,
            &ok(json!({ "email": "tester@example.test", "plan": 2, "premium_expires_at": "2030-01-01" })),
        )]);
        let account = torbox.validate().await.unwrap();
        assert_eq!(account.username, "tester@example.test");
        assert_eq!(account.expires.as_deref(), Some("2030-01-01"));
    }

    #[tokio::test]
    async fn a_per_request_failure_stays_a_plain_error_not_a_bad_key() {
        let (torbox, _) = service(vec![Route::json("/user/me", 200, &fail("ACTIVE_LIMIT", "nope"))]);
        let error = torbox.validate().await.unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }), "one bad call cannot look like a bad key");
        assert!(error.to_string().contains("active TorBox downloads"));
    }

    // --- the cache endpoint, the reason TorBox is worth having ---

    #[tokio::test]
    async fn the_cache_endpoint_answers_many_hashes_in_a_single_request() {
        let hashes: Vec<String> = (0..5).map(|index| format!("{index}").repeat(40)).collect();
        let cached = hashes[1].to_uppercase();
        let (torbox, transport) = service(vec![Route::json(
            "checkcached",
            200,
            &ok(json!([{ "hash": cached, "name": "Cached One", "size": 1 }])),
        )]);
        let answers = torbox.check_availability_batch(&hashes).await.unwrap();
        let urls = transport.urls();
        assert_eq!(urls.len(), 1, "a batch service must not be asked per hash");
        assert_eq!(urls[0].matches("hash=").count(), 5, "every hash travels in the one request");
        assert_eq!(answers.get(&hashes[1]), Some(&Availability::Cached));
        for index in [0, 2, 3, 4] {
            assert_eq!(
                answers.get(&hashes[index]),
                Some(&Availability::Available),
                "not cached means TorBox would fetch it, not that it cannot"
            );
        }
        // the endpoint names the release it is answering about, and that name is remembered
        assert_eq!(torbox.client.release_name(&hashes[1]).as_deref(), Some("Cached One"));
        assert_eq!(torbox.client.release_name(&hashes[0]), None, "nothing invented for a release never mentioned");
    }

    #[tokio::test]
    async fn the_cache_endpoint_is_understood_when_it_answers_keyed_by_hash() {
        let (torbox, _) = service(vec![Route::json(
            "checkcached",
            200,
            &ok(json!({ HASH: { "name": "Cached One", "size": 1 } })),
        )]);
        let answers = torbox.check_availability_batch(&[HASH.to_string()]).await.unwrap();
        assert_eq!(answers.get(HASH), Some(&Availability::Cached));
        assert_eq!(torbox.client.release_name(HASH).as_deref(), Some("Cached One"));
    }

    #[tokio::test]
    async fn an_empty_cache_answer_is_an_answer_not_a_failure() {
        let (torbox, _) = service(vec![Route::json("checkcached", 200, &ok(Value::Null))]);
        let answers = torbox.check_availability_batch(&[HASH.to_string()]).await.unwrap();
        assert_eq!(answers.get(HASH), Some(&Availability::Available));
    }

    #[tokio::test]
    async fn list_availability_reads_every_account_torrent_as_what_it_means_for_playback() {
        let downloading = "b".repeat(40);
        let stalled = "c".repeat(40);
        let (torbox, _) = service(vec![Route::json(
            "mylist",
            200,
            &ok(json!([
                torrent(json!({})),
                torrent(json!({ "id": 2, "hash": downloading, "download_present": false, "download_finished": false, "progress": 0.3, "download_state": "downloading" })),
                torrent(json!({ "id": 3, "hash": stalled, "download_present": false, "download_finished": false, "download_state": "stalled (no seeds)" }))
            ])),
        )]);
        let known = torbox.list_availability().await.unwrap();
        assert_eq!(known.get(HASH), Some(&Availability::Cached), "held, and lowercased");
        assert_eq!(known.get(&downloading), Some(&Availability::Available));
        assert_eq!(known.get(&stalled), Some(&Availability::Unavailable), "a stalled torrent never finishes on its own");
        assert_eq!(torbox.client.release_name(HASH).as_deref(), Some("Test Torrent"));
    }

    // --- resolve ---

    #[tokio::test]
    async fn resolve_streams_a_torrent_the_account_already_holds_without_adding_it_again() {
        let (torbox, transport) = service(vec![
            // per-file link routes must come before anything matching the broader URL
            Route::json("file_id=0", 200, &ok(json!("https://torbox.test/dl/0"))),
            Route::json("file_id=2", 200, &ok(json!("https://torbox.test/dl/2"))),
            Route::json("mylist", 200, &ok(json!([torrent(json!({}))]))),
        ]);
        let resolved = torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        assert_eq!(resolved.hash, HASH, "the hash comes back lowercased, the key everything else is stored under");
        assert_eq!(resolved.name, "Test Torrent");
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        assert_eq!(paths, ["/Test/Episode 01.mkv", "/Test/Episode 02.mkv"], "rooted paths, readme filtered out, torrent order");
        let names: Vec<&str> = resolved.files.iter().map(|file| file.name.as_str()).collect();
        assert_eq!(names, ["Episode 01.mkv", "Episode 02.mkv"]);
        let types: Vec<Option<&str>> = resolved.files.iter().map(|file| file.r#type.as_deref()).collect();
        assert_eq!(types, [Some("video/x-matroska"), Some("video/x-matroska")]);
        assert!(resolved.files.iter().all(|file| file.url.starts_with("https://")));
        let urls = transport.urls();
        assert!(!urls.iter().any(|url| url.contains("createtorrent")), "a torrent already on the account must be reused");
        // no picker given, so the largest file is played and its link is requested first
        let links: Vec<&String> = urls.iter().filter(|url| url.contains("requestdl")).collect();
        assert!(links[0].contains("file_id=2"), "the played file's link goes out before any neighbor's");
        assert!(links[1].contains("file_id=0"));
    }

    #[tokio::test]
    async fn the_link_endpoint_carries_the_key_the_way_it_expects_and_no_other_one_does() {
        let (torbox, transport) = service(vec![
            Route::json("requestdl", 200, &ok(json!("https://torbox.test/dl/0"))),
            Route::json("mylist", 200, &ok(json!([torrent(json!({}))]))),
        ]);
        torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        let requests = transport.requests.lock().unwrap();
        let list = requests.iter().find(|request| request.url.contains("mylist")).unwrap();
        let link = requests.iter().find(|request| request.url.contains("requestdl")).unwrap();
        assert_eq!(
            list.timeout_ms, ACCOUNT_TIMEOUT_MS,
            "an unhealthy account endpoint must not spend the player's full request budget"
        );
        assert_eq!(list.headers.get("Authorization").map(String::as_str), Some("Bearer test-key"));
        assert!(!list.url.contains("test-key"), "a bearer key must never leak into a URL");
        assert!(link.url.contains("token=test-key"), "this one endpoint takes the key as a query parameter");
        assert!(!link.headers.contains_key("Authorization"), "and must not also send a header");
    }

    #[tokio::test]
    async fn an_uncached_release_is_refused_before_anything_lands_on_the_account() {
        let (torbox, transport) = service(vec![
            Route::json("checkcached", 200, &ok(json!([]))),
            Route::json("mylist", 200, &ok(json!([]))),
        ]);
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        assert_eq!(error.proven_availability(), Some(Availability::Available));
        assert!(
            !transport.urls().iter().any(|url| url.contains("createtorrent")),
            "asking is free, so nothing is queued onto the account to find out"
        );
    }

    #[tokio::test]
    async fn a_cached_release_is_added_and_then_streamed() {
        let (torbox, transport) = service(vec![
            Route::json("checkcached", 200, &ok(json!([{ "hash": HASH }]))),
            Route::json("createtorrent", 200, &ok(json!({ "torrent_id": 42, "hash": HASH }))),
            Route::json("requestdl", 200, &ok(json!("https://torbox.test/dl/0"))),
            // the poll by id must outrank the plain listing, which answers empty
            Route::json("id=42", 200, &ok(torrent(json!({})))),
            Route::json("mylist", 200, &ok(json!([]))),
        ]);
        let resolved = torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        assert_eq!(resolved.files.len(), 2);
        let requests = transport.requests.lock().unwrap();
        let create = requests.iter().find(|request| request.url.contains("createtorrent")).unwrap();
        let Some(Body::Multipart(fields)) = &create.body else {
            panic!("createtorrent documents multipart");
        };
        let field = |name: &str| fields.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str());
        assert_eq!(field("magnet"), Some(MAGNET));
        assert_eq!(field("seed"), Some("3"), "Shiru only streams, it must never leave the account seeding");
        assert_eq!(field("allow_zip"), Some("false"), "a zipped pack is not something the player can seek in");
        // polling a fresh add bypasses TorBox's listing cache, or it would spin forever
        let poll = requests.iter().find(|request| request.url.contains("id=42") && !request.url.contains("requestdl")).unwrap();
        assert!(poll.url.contains("bypass_cache=true"));
    }

    #[tokio::test]
    async fn a_release_the_sweep_already_proved_cached_is_not_rechecked_on_resolve() {
        // the badge the user clicked was filled in by the availability sweep moments
        // ago; asking the same question again put a roundtrip on the play path.
        // No checkcached route at all: reaching for it would fail the resolve
        let (torbox, transport) = service(vec![
            Route::json("createtorrent", 200, &ok(json!({ "torrent_id": 42, "hash": HASH }))),
            Route::json("requestdl", 200, &ok(json!("https://torbox.test/dl/0"))),
            Route::json("id=42", 200, &ok(torrent(json!({})))),
            Route::json("mylist", 200, &ok(json!([]))),
        ]);
        torbox.client.remember(HASH, Availability::Cached);
        let resolved = torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        assert_eq!(resolved.files.len(), 2);
        assert!(
            !transport.urls().iter().any(|url| url.contains("checkcached")),
            "the sweep's remembered answer is the same answer the roundtrip would give"
        );
    }

    #[tokio::test]
    async fn the_next_episode_reuses_the_listing_the_last_add_amended() {
        // adding used to drop the remembered listing, so back-to-back episode plays
        // each paid a fresh thousand-entry account read for a change this client made
        let (torbox, transport) = service(vec![
            Route::json("checkcached", 200, &ok(json!([{ "hash": HASH }]))),
            Route::json("createtorrent", 200, &ok(json!({ "torrent_id": 42, "hash": HASH }))),
            Route::json("requestdl", 200, &ok(json!("https://torbox.test/dl/0"))),
            Route::json("id=42", 200, &ok(torrent(json!({})))),
            Route::json("mylist", 200, &ok(json!([]))),
        ]);
        torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        let full_reads = transport
            .urls()
            .iter()
            .filter(|url| url.contains("mylist") && !url.contains("id="))
            .count();
        assert_eq!(full_reads, 1, "the second play finds the torrent in the listing the first play amended");
        let creates = transport.urls().iter().filter(|url| url.contains("createtorrent")).count();
        assert_eq!(creates, 1, "and so it never adds the same torrent twice");
    }

    #[tokio::test]
    async fn a_torrent_the_account_holds_but_cannot_finish_is_unavailable_not_uncached() {
        let (torbox, _) = service(vec![Route::json(
            "mylist",
            200,
            &ok(json!([torrent(json!({ "download_present": false, "download_finished": false, "download_state": "error" }))])),
        )]);
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(matches!(error, DebridError::Unavailable { .. }));
        assert_eq!(error.proven_availability(), Some(Availability::Unavailable));
    }

    #[tokio::test]
    async fn a_torrent_still_downloading_on_the_account_is_not_deleted_out_from_under_the_user() {
        let (torbox, transport) = service(vec![Route::json(
            "mylist",
            200,
            &ok(json!([torrent(json!({ "download_present": false, "download_finished": false, "progress": 0.5, "download_state": "downloading" }))])),
        )]);
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        assert!(
            !transport.urls().iter().any(|url| url.contains("controltorrent")),
            "only torrents this client added may be removed"
        );
    }

    #[tokio::test]
    async fn an_added_torrent_that_never_shows_up_is_errored_and_taken_back_off_the_account() {
        let (torbox, transport) = service(vec![
            Route::json("checkcached", 200, &ok(json!([{ "hash": HASH }]))),
            Route::json("createtorrent", 200, &ok(json!({ "torrent_id": 42, "hash": HASH }))),
            Route::json("controltorrent", 200, &ok(json!(true))),
            Route::json("id=42", 200, &ok(Value::Null)),
            Route::json("mylist", 200, &ok(json!([]))),
        ]);
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(error.to_string().contains("did not report the torrent back"));
        assert!(
            transport.urls().iter().any(|url| url.contains("controltorrent")),
            "the ghost add must not be left on the account"
        );
    }

    #[tokio::test]
    async fn a_cached_add_that_turns_out_to_be_a_fresh_download_is_refused_and_cleaned_up() {
        // the cache check said yes, but the account entry never reports the data present —
        // waiting for a real download would hold the player open for minutes
        let (torbox, transport) = service(vec![
            Route::json("checkcached", 200, &ok(json!([{ "hash": HASH }]))),
            Route::json("createtorrent", 200, &ok(json!({ "torrent_id": 42, "hash": HASH }))),
            Route::json("controltorrent", 200, &ok(json!(true))),
            Route::json(
                "id=42",
                200,
                &ok(torrent(json!({ "download_present": false, "download_finished": false, "progress": 0.1, "download_state": "downloading" }))),
            ),
            Route::json("mylist", 200, &ok(json!([]))),
        ]);
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        let cleanup_urls = transport.urls();
        assert!(
            cleanup_urls.iter().any(|url| url.contains("controltorrent")),
            "the torrent this call added is downloading against the user's quota and must go"
        );
        let requests = transport.requests.lock().unwrap();
        let cleanup = requests.iter().find(|request| request.url.contains("controltorrent")).unwrap();
        let Some(Body::Bytes { content_type, bytes }) = &cleanup.body else { panic!("controltorrent takes json") };
        assert_eq!(content_type, "application/json");
        assert_eq!(
            serde_json::from_slice::<Value>(bytes).unwrap(),
            json!({ "torrent_id": 42, "operation": "delete" })
        );
    }

    #[tokio::test]
    async fn one_dead_file_in_a_pack_does_not_sink_the_whole_resolve() {
        let (torbox, _) = service(vec![
            Route::json("file_id=0", 500, &fail("DOWNLOAD_SERVER_ERROR", "nope")),
            Route::json("file_id=2", 200, &ok(json!("https://torbox.test/dl/2"))),
            Route::json("mylist", 200, &ok(json!([torrent(json!({}))]))),
        ]);
        let resolved = torbox.resolve(MAGNET, &video_filter()).await.unwrap();
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        assert_eq!(paths, ["/Test/Episode 02.mkv"], "the surviving file must still play");
    }

    /// TorBox can produce the selected episode's URL and other pack links while one
    /// neighboring file never answers. Playback must not wait for that optional neighbor
    /// until the manager's whole 60-second resolve budget expires, or discard links that
    /// already finished while it was waiting.
    struct SilentNeighbor {
        listing: String,
    }

    #[async_trait::async_trait]
    impl HttpTransport for SilentNeighbor {
        async fn execute(
            &self,
            request: shiru_networking::HttpRequest,
        ) -> Result<shiru_networking::HttpResponse, shiru_networking::TransportError> {
            let body = if request.url.contains("file_id=2") {
                ok(json!("https://torbox.test/dl/2"))
            } else if request.url.contains("file_id=1") {
                ok(json!("https://torbox.test/dl/1"))
            } else if request.url.contains("requestdl") {
                return futures::future::pending().await;
            } else {
                self.listing.clone()
            };
            Ok(shiru_networking::HttpResponse { status: 200, headers: HashMap::new(), body: body.into_bytes() })
        }
    }

    #[tokio::test]
    async fn a_silent_neighbor_does_not_hide_the_selected_episode_link() {
        let transport = Arc::new(SilentNeighbor { listing: ok(json!([torrent(json!({}))])) });
        let torbox = TorBox::new("test-key".into(), transport, Arc::new(ManualClock::new()));
        let resolved = tokio::time::timeout(
            std::time::Duration::from_millis(500),
            torbox.resolve(MAGNET, &ResolveOptions::default()),
        )
        .await
        .expect("a neighboring link held the selected episode hostage")
        .unwrap();
        assert!(resolved.files.iter().any(|file| file.path == "/Test/Episode 02.mkv"));
        assert!(resolved.files.iter().any(|file| file.path == "/Test/readme.txt"));
    }

    /// TorBox's uncached account read has accepted the connection and then stayed silent while
    /// its normal listing and download-link endpoints remained healthy. A torrent the listing
    /// already identifies must reach `requestdl` instead of putting that unreliable confirmation
    /// in front of every play.
    struct SilentFreshListing {
        listing: String,
    }

    #[async_trait::async_trait]
    impl HttpTransport for SilentFreshListing {
        async fn execute(
            &self,
            request: shiru_networking::HttpRequest,
        ) -> Result<shiru_networking::HttpResponse, shiru_networking::TransportError> {
            let body = if request.url.contains("mylist") && request.url.contains("bypass_cache=true") {
                return futures::future::pending().await;
            } else if request.url.contains("requestdl") {
                ok(json!("https://torbox.test/dl/episode"))
            } else {
                self.listing.clone()
            };
            Ok(shiru_networking::HttpResponse { status: 200, headers: HashMap::new(), body: body.into_bytes() })
        }
    }

    #[tokio::test]
    async fn a_cached_account_entry_does_not_wait_for_a_fresh_listing_to_stream() {
        let transport = Arc::new(SilentFreshListing { listing: ok(json!([torrent(json!({}))])) });
        let torbox = TorBox::new("test-key".into(), transport, Arc::new(ManualClock::new()));
        let resolved = tokio::time::timeout(
            std::time::Duration::from_millis(500),
            torbox.resolve(MAGNET, &ResolveOptions::default()),
        )
        .await
        .expect("a silent fresh account read blocked a link the normal listing already described")
        .unwrap();
        assert!(resolved.files.iter().any(|file| file.path == "/Test/Episode 02.mkv"));
    }

    #[tokio::test]
    async fn an_auth_failure_while_fetching_links_still_surfaces_as_an_auth_error() {
        let (torbox, _) = service(vec![
            Route::json("requestdl", 403, &fail("BAD_TOKEN", "nope")),
            Route::json("mylist", 200, &ok(json!([torrent(json!({}))]))),
        ]);
        // every link would fail for the same reason, so this is not a per-file problem to skip
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
    }

    #[tokio::test]
    async fn a_pack_is_capped_around_the_episode_being_played_and_requested_first() {
        let files: Vec<Value> = (0..150)
            .map(|index| json!({ "id": index, "name": format!("Pack/Episode {:03}.mkv", index + 1), "size": 1000, "mimetype": "video/x-matroska" }))
            .collect();
        let (torbox, transport) = service(vec![
            Route::json("requestdl", 200, &ok(json!("https://torbox.test/dl/x"))),
            Route::json("mylist", 200, &ok(json!([torrent(json!({ "name": "Big Pack", "files": files }))]))),
        ]);
        let opts = ResolveOptions {
            file_filter: video_filter().file_filter,
            pick_file: Some(Box::new(|candidates| {
                Ok(candidates.iter().position(|(_, path, _)| path == "/Pack/Episode 100.mkv"))
            })),
            max_files: None,
        };
        let resolved = torbox.resolve(MAGNET, &opts).await.unwrap();
        let links: Vec<String> = transport.urls().into_iter().filter(|url| url.contains("requestdl")).collect();
        assert!(links.len() <= 12, "a {}-link burst is how the live account earned a five minute ban", links.len());
        assert!(links[0].contains("file_id=99&"), "the played episode's link must be requested before any neighbor's");
        assert!(resolved.files.iter().any(|file| file.path == "/Pack/Episode 100.mkv"), "and it must be in the result");
        assert!(resolved.files.iter().any(|file| file.path == "/Pack/Episode 099.mkv"), "and its neighbours, for in-player navigation");
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        let mut sorted = paths.clone();
        sorted.sort();
        assert_eq!(paths, sorted, "files still come back in torrent order");
        // torrent order means the played file is NOT first, and pack links land on different
        // CDN nodes — whoever probes or warms "the" stream has to be told which one it is
        assert_eq!(resolved.target.as_deref(), Some("/Pack/Episode 100.mkv"), "the resolve says which file it picked");
    }

    #[tokio::test]
    async fn a_torrent_with_nothing_playable_in_it_says_so() {
        let (torbox, _) = service(vec![Route::json(
            "mylist",
            200,
            &ok(json!([torrent(json!({ "files": [{ "id": 0, "name": "Test/readme.txt", "size": 10 }] }))])),
        )]);
        let error = torbox.resolve(MAGNET, &video_filter()).await.unwrap_err();
        assert!(error.to_string().contains("No playable files"));
    }

    #[tokio::test]
    async fn resolve_refuses_a_source_it_cannot_turn_into_a_hash_instead_of_guessing() {
        let (torbox, transport) = service(vec![]);
        let error = torbox.resolve("https://nyaa.si/download/1.torrent", &ResolveOptions::default()).await.unwrap_err();
        assert!(error.to_string().contains("magnet link or info hash"));
        assert!(transport.urls().is_empty(), "nothing to ask about, so nothing is asked");
    }

    #[tokio::test]
    async fn requires_an_api_key() {
        let transport = Arc::new(MockTransport::new(vec![]));
        let torbox = TorBox::new(String::new(), transport, Arc::new(ManualClock::new()));
        let error = torbox.validate().await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
    }
}
