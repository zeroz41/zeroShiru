//! Real-Debrid implementation, see https://api.real-debrid.com/
//! Port of common/modules/debrid/realdebrid.js; test/unit/debrid/realdebrid.test.js
//! (plus the Real-Debrid halves of slowlink.test.js) is the behavioural reference.
//!
//! Two API quirks shape this client:
//! - `/torrents/instantAvailability` is disabled (403 `disabled_endpoint`), so a release can
//!   only be asked about by adding the magnet and reading the status back. Hence
//!   `probe_availability`, and the config cap on how many of those a search may cost.
//! - Selecting multiple files can serve one RAR archive instead of individual links, so when
//!   that happens the torrent is re-added selecting only the target file.

use crate::client::{DebridClient, Dialect, RequestOpts};
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
use std::collections::HashMap;
use std::sync::Arc;

const API: &str = "https://api.real-debrid.com/rest/1.0";
/// The whole account in one request, newest first.
const LIST_LIMIT: u32 = 1_000;

/// Status reads a probe gives a magnet still converting before giving up.
///
/// Real-Debrid holds the metadata for anything cached, so a cached release reaches file
/// selection within a read or two; one still converting is telling us it is not. Counted in
/// reads rather than seconds so a slow link does not change how many chances it gets. Giving
/// up leaves the release unknown, so the next sweep asks again.
const PROBE_CONVERSION_READS: u32 = 2;

/// What each torrent status means for playback. Magnet conversion and file selection are left
/// out on purpose: they are moments in a torrent's life, not outcomes, so they answer nothing.
fn status_availability(status: &str) -> Option<Availability> {
    match status {
        "downloaded" => Some(Availability::Cached),
        // being fetched fresh, so Real-Debrid can serve it eventually but not now
        "queued" | "downloading" | "uploading" | "compressing" => Some(Availability::Available),
        // will never complete
        "magnet_error" | "error" | "virus" | "dead" => Some(Availability::Unavailable),
        _ => None,
    }
}

/// The typed answer a settled status stands for, or `None` while the torrent is still deciding.
fn unstreamable(status: &str) -> Option<DebridError> {
    match status_availability(status) {
        Some(Availability::Unavailable) => Some(DebridError::Unavailable {
            message: format!("Real-Debrid could not process this torrent ({status})"),
        }),
        Some(Availability::Available) => Some(DebridError::not_cached()),
        _ => None,
    }
}

/// error_code values worth explaining, anything else falls back to the API's own message.
fn error_message(code: i64) -> Option<&'static str> {
    Some(match code {
        8 => "Invalid Real-Debrid API key",
        9 => "Real-Debrid denied the request, check the account permissions",
        21 => "Too many active Real-Debrid downloads, wait for one to finish",
        23 => "This Real-Debrid account has exhausted its traffic",
        34 => "Real-Debrid is rate limiting this account, try again shortly",
        35 => "Real-Debrid will not serve this file, pick a different release",
        36 => "Real-Debrid fair usage limit reached",
        _ => return None,
    })
}

/// Real-Debrid's response conventions: raw JSON bodies, `error_code`-driven error mapping.
struct RdDialect;

impl Dialect for RdDialect {
    fn map_error(&self, status: u16, json: Option<&Value>) -> DebridError {
        let code = json.and_then(|value| value.get("error_code")).and_then(Value::as_i64);
        let message = code
            .and_then(error_message)
            .map(str::to_string)
            .or_else(|| {
                json.and_then(|value| value.get("error")).and_then(Value::as_str).map(str::to_string)
            })
            .unwrap_or_else(|| format!("Request failed with status {status}"));
        let code_text = code.map(|code| code.to_string());
        // only codes 8 and 9 mean the key or account is the problem, the rest are per-request.
        // A blocked or unavailable file also answers 403, and must stay a plain error: an auth
        // error aborts the whole resolve, where one bad file in a pack should only be skipped
        if matches!(code, Some(8) | Some(9)) || ((status == 401 || status == 403) && code.is_none())
        {
            DebridError::Auth { message, status: Some(status), code: code_text }
        } else {
            DebridError::Service { message, status: Some(status), code: code_text }
        }
    }
}

/// A torrent as `/torrents/info` reports it, reduced to the fields this client reads.
#[derive(Debug, Clone)]
struct TorrentInfo {
    id: String,
    /// Lowercased on parse, the API reports uppercase.
    hash: String,
    filename: String,
    status: String,
    files: Vec<TorrentFile>,
    links: Vec<String>,
}

#[derive(Debug, Clone)]
struct TorrentFile {
    id: u64,
    path: String,
    bytes: u64,
    selected: bool,
}

/// A file playback may want, carried between selection and unrestricting.
#[derive(Debug, Clone)]
struct Wanted {
    id: u64,
    path: String,
    size: u64,
}

/// One link to unrestrict, with the file it maps to when the lists align.
struct Candidate {
    link: String,
    path: Option<String>,
    size: u64,
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

fn truthy(value: &Value) -> bool {
    value.as_bool().unwrap_or_else(|| value.as_i64().unwrap_or(0) != 0)
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Archives Real-Debrid may serve instead of streamable files, when it repacks a selection.
fn is_archive(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".rar") || lower.ends_with(".zip") || lower.ends_with(".7z")
}

fn parse_info(value: &Value) -> TorrentInfo {
    let files = value
        .get("files")
        .and_then(Value::as_array)
        .map(|files| {
            files
                .iter()
                .map(|file| TorrentFile {
                    id: file.get("id").and_then(Value::as_u64).unwrap_or(0),
                    path: text(file, "path").unwrap_or_default(),
                    bytes: file.get("bytes").and_then(Value::as_u64).unwrap_or(0),
                    selected: file.get("selected").map(truthy).unwrap_or(false),
                })
                .collect()
        })
        .unwrap_or_default();
    let links = value
        .get("links")
        .and_then(Value::as_array)
        .map(|links| links.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    TorrentInfo {
        id: text(value, "id").unwrap_or_default(),
        hash: text(value, "hash").unwrap_or_default().to_ascii_lowercase(),
        filename: text(value, "filename").unwrap_or_default(),
        status: text(value, "status").unwrap_or_default(),
        files,
        links,
    }
}

pub struct RealDebrid {
    client: DebridClient,
}

impl RealDebrid {
    pub fn new(api_key: &str, transport: Arc<dyn HttpTransport>, platform: Arc<dyn Platform>) -> Self {
        let config = ProviderConfig {
            id: "realdebrid",
            title: "Real-Debrid",
            auth: AuthScheme::Bearer,
            auth_param: "apikey",
            encoding: BodyEncoding::Form,
            timeouts: Timeouts::default(),
            nominal_latency: 300,
            max_files: 60,
            // no cache endpoint any more, so availability has to be probed a hash at a time
            availability_check: AvailabilityCheck::Probe,
            check_adds_magnets: true,
            max_batch: 100,
            max_probes: 10,
            // documented allowance is 250 requests per minute; 200 keeps the headroom the
            // JS limiter kept, since a probe sweep and a resolve can want the account at once
            max_concurrent: 4,
            min_time_ms: 150,
            reservoir: Some((200, 60_000)),
        };
        RealDebrid { client: DebridClient::new(config, api_key.to_string(), transport, platform) }
    }

    /// Whether an error means Real-Debrid wants fewer requests rather than that a release is
    /// a problem: rate limited (34), or at its active torrent cap (21). The sweep layer stops
    /// on one. Port of the JS `throttled` override.
    pub fn throttled(error: &DebridError) -> bool {
        if error.throttled() {
            return true;
        }
        matches!(
            error,
            DebridError::Service { code: Some(code), .. } | DebridError::Auth { code: Some(code), .. }
                if code == "21" || code == "34"
        )
    }

    async fn get(&self, url: &str) -> Result<Value, DebridError> {
        self.client.request(&RdDialect, url, RequestOpts::default()).await
    }

    async fn post(&self, url: &str, body: Vec<(String, Value)>) -> Result<Value, DebridError> {
        let opts = RequestOpts { method: Some(Method::Post), body: Some(body), ..Default::default() };
        self.client.request(&RdDialect, url, opts).await
    }

    /// Undoes a torrent this client put on the account. Never fails: it runs from error paths
    /// where a failure would mask the real one. A removal that fails is remembered by the
    /// client and retried before the next check adds anything — the likeliest cause is the
    /// link dropping mid-probe, and a magnet left behind is the one trace a check can leave.
    async fn release(&self, torrent_id: &str) {
        let url = format!("{API}/torrents/delete/{torrent_id}");
        let opts = RequestOpts { method: Some(Method::Delete), ..Default::default() };
        self.client.release(&RdDialect, &url, opts).await;
    }

    /// The account's torrent listing, the whole account in one request, read at most
    /// once a minute and shared between the badge refresh and every resolve. Reading it
    /// per play put a full account listing ahead of the links the user is waiting for.
    async fn fetch_listing(&self) -> Result<Value, DebridError> {
        let url = format!("{API}/torrents?limit={LIST_LIMIT}");
        self.client.listing(false, || self.get(&url)).await
    }

    /// The account's entry for an info hash, or `None`. Read back by id because the listing
    /// can be a minute stale, so one deleted elsewhere must read as absent rather than fail
    /// the resolve.
    async fn existing_torrent(&self, hash: Option<&str>) -> Result<Option<TorrentInfo>, DebridError> {
        let Some(hash) = hash else { return Ok(None) };
        let listing = self.fetch_listing().await?;
        let listed_id = listing.as_array().and_then(|torrents| {
            torrents.iter().find_map(|torrent| {
                let matches = text(torrent, "hash")
                    .map(|listed| listed.eq_ignore_ascii_case(hash))
                    .unwrap_or(false);
                if matches { text(torrent, "id") } else { None }
            })
        });
        let Some(id) = listed_id else { return Ok(None) };
        match self.get(&format!("{API}/torrents/info/{id}")).await {
            Ok(info) => Ok(Some(parse_info(&info))),
            // the account listing named a torrent that is gone, so it is describing an
            // account that no longer exists: add the magnet, and pay for the next read
            Err(error) if error.status() == Some(404) => {
                self.client.forget_listing().await;
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    /// Selects the given file ids, or everything when there are none to name.
    async fn select_files(&self, torrent_id: &str, ids: &[u64]) -> Result<(), DebridError> {
        let files = if ids.is_empty() {
            "all".to_string()
        } else {
            ids.iter().map(u64::to_string).collect::<Vec<_>>().join(",")
        };
        self.post(
            &format!("{API}/torrents/selectFiles/{torrent_id}"),
            vec![("files".into(), Value::String(files))],
        )
        .await
        .map(|_| ())
    }

    /// Adds a magnet and selects either the files matching the filter or one specific file.
    /// `reads` caps how many status reads the magnet gets to convert, for probes.
    /// Returns the new torrent id; on failure this call has undone itself.
    async fn add_and_select(
        &self,
        magnet_uri: &str,
        file_filter: Option<&(dyn Fn(&str) -> bool + Sync)>,
        file_id: Option<u64>,
        reads: Option<u32>,
    ) -> Result<String, DebridError> {
        let added = self
            .post(&format!("{API}/torrents/addMagnet"), vec![("magnet".into(), Value::String(magnet_uri.to_string()))])
            .await?;
        let Some(torrent_id) = text(&added, "id") else {
            return Err(DebridError::Service {
                message: "Real-Debrid returned no torrent id".into(),
                status: None,
                code: None,
            });
        };
        // the account now has a torrent the remembered listing does not
        self.client.forget_listing().await;
        let selected = async {
            let budget = self.client.budget(self.client.config.timeouts.select);
            let info = self.await_status(&torrent_id, "waiting_files_selection", budget, reads).await?;
            if info.status == "waiting_files_selection" {
                let ids: Vec<u64> = match file_id {
                    Some(id) => vec![id],
                    None => info
                        .files
                        .iter()
                        .filter(|file| file_filter.map_or(true, |filter| filter(&file.path)))
                        .map(|file| file.id)
                        .collect(),
                };
                self.select_files(&torrent_id, &ids).await?;
            }
            Ok(())
        }
        .await;
        match selected {
            Ok(()) => Ok(torrent_id),
            Err(error) => {
                // awaited, so this call has undone itself by the time it reports failure
                self.release(&torrent_id).await;
                Err(error)
            }
        }
    }

    /// Polls torrent info until it reaches the wanted status. `reads` caps the number of
    /// status reads, for callers that want a fixed number of chances.
    async fn await_status(
        &self,
        id: &str,
        wanted: &str,
        timeout_ms: u64,
        reads: Option<u32>,
    ) -> Result<TorrentInfo, DebridError> {
        let platform = self.client.platform();
        let started = platform.now_ms();
        let mut read: u32 = 0;
        loop {
            read += 1;
            let info = parse_info(&self.get(&format!("{API}/torrents/info/{id}")).await?);
            if info.status == wanted
                || (wanted == "waiting_files_selection" && info.status == "downloaded")
            {
                return Ok(info);
            }
            if let Some(settled) = unstreamable(&info.status) {
                return Err(settled);
            }
            // a rare release can sit in magnet_conversion a while, so running out of time
            // proves nothing about it. Callers decide: playback treats it as uncached, a
            // probe leaves it re-checkable
            if reads.is_some_and(|max| read >= max)
                || platform.now_ms().saturating_sub(started) > timeout_ms
            {
                return Err(DebridError::Timeout {
                    message: format!("Timed out waiting for Real-Debrid ({})", info.status),
                });
            }
            platform.sleep(self.client.config.timeouts.poll).await;
        }
    }

    /// Unrestricts a torrent's links into direct stream files. The cached copy may serve
    /// fewer links than files selected, so filter by path when the lists align and by
    /// filename otherwise. Archives are dropped; the caller recovers via single file
    /// selection.
    async fn unrestrict_links(
        &self,
        info: &TorrentInfo,
        file_filter: &(dyn Fn(&str) -> bool + Sync),
        max_files: usize,
        target: Option<&Wanted>,
    ) -> Result<Vec<DebridFile>, DebridError> {
        if info.links.is_empty() {
            return Err(DebridError::Service {
                message: "Real-Debrid returned no links for this torrent".into(),
                status: None,
                code: None,
            });
        }
        let selected: &Vec<&TorrentFile> =
            &info.files.iter().filter(|file| file.selected).collect();
        let aligned = info.links.len() == selected.len();
        let candidates: Vec<Candidate> = if aligned {
            selected
                .iter()
                .zip(&info.links)
                .filter(|(file, _)| file_filter(&file.path))
                .map(|(file, link)| Candidate {
                    link: link.clone(),
                    path: Some(file.path.clone()),
                    size: file.bytes,
                })
                .collect()
        } else {
            info.links.iter().map(|link| Candidate { link: link.clone(), path: None, size: 0 }).collect()
        };
        let target_index = target
            .and_then(|wanted| candidates.iter().position(|candidate| candidate.path.as_deref() == Some(wanted.path.as_str())));
        let windowed = window_files(&candidates, target_index, max_files);
        // one round trip per link, all of them at once and paced by the limiter: a pack
        // unrestricted one link at a time costs a full round trip per episode before
        // playback can start, which on a slow link is most of a minute of black screen
        crate::client::map_files(windowed, |candidate| async move {
            let unrestricted = self
                .post(&format!("{API}/unrestrict/link"), vec![("link".into(), Value::String(candidate.link.clone()))])
                .await?;
            let name = candidate
                .path
                .as_deref()
                .map(basename)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
                .or_else(|| text(&unrestricted, "filename"))
                .unwrap_or_default();
            if name.is_empty() {
                return Ok(None);
            }
            if candidate.path.is_none() && !file_filter(&name) {
                return Ok(None);
            }
            // RD packed the selection into an archive
            if is_archive(&name) && !selected.iter().any(|file| file.path.ends_with(&name)) {
                return Ok(None);
            }
            Ok(Some(DebridFile {
                path: candidate.path.clone().unwrap_or_else(|| format!("/{name}")),
                size: unrestricted
                    .get("filesize")
                    .and_then(Value::as_u64)
                    .filter(|size| *size != 0)
                    .unwrap_or(candidate.size),
                url: text(&unrestricted, "download").unwrap_or_default(),
                r#type: text(&unrestricted, "mimeType"),
                name,
            }))
        })
        .await
    }

    /// The resolve body; `added` carries the id of any torrent this call put on the account,
    /// so the outer `resolve` can clean up on failure.
    async fn resolve_inner(
        &self,
        magnet: &str,
        opts: &ResolveOptions,
        added: &mut Option<String>,
    ) -> Result<DebridResolved, DebridError> {
        let hash = parse_hash(magnet);
        let magnet_uri = to_magnet(magnet).ok_or_else(|| DebridError::Service {
            message: "Not a usable info hash".into(),
            status: None,
            code: None,
        })?;
        let filter = |name: &str| opts.file_filter.as_ref().map_or(true, |filter| filter(name));
        let filter: &(dyn Fn(&str) -> bool + Sync) = &filter;
        let max_files = opts.max_files.unwrap_or(self.client.config.max_files);

        // reuse a torrent that is already on the account instead of adding a duplicate
        let existing = self.existing_torrent(hash.as_deref()).await?;
        let (mut torrent_id, info) = match existing {
            Some(torrent) if torrent.status == "waiting_files_selection" => {
                // a stale add that never got its files selected, finish the job
                let ids: Vec<u64> = torrent
                    .files
                    .iter()
                    .filter(|file| filter(&file.path))
                    .map(|file| file.id)
                    .collect();
                self.select_files(&torrent.id, &ids).await?;
                (torrent.id, None)
            }
            // mid-conversion counts as not cached here: playback cannot wait for it either way
            Some(torrent) if torrent.status != "downloaded" => {
                return Err(unstreamable(&torrent.status).unwrap_or_else(DebridError::not_cached));
            }
            // already confirmed downloaded, with its files and links
            Some(torrent) => (torrent.id.clone(), Some(torrent)),
            None => {
                let id = self.add_and_select(&magnet_uri, Some(filter), None, None).await?;
                *added = Some(id.clone());
                (id, None)
            }
        };
        let ready = self.client.budget(self.client.config.timeouts.ready);
        let mut info = match info {
            Some(info) => info,
            None => self.await_status(&torrent_id, "downloaded", ready, None).await?,
        };

        // work out which file playback is after before unrestricting, so a capped pack never
        // drops the wanted episode and archives can be recovered from
        let wanted: Vec<Wanted> = info
            .files
            .iter()
            .filter(|file| filter(&file.path))
            .map(|file| Wanted { id: file.id, path: file.path.clone(), size: file.bytes })
            .collect();
        let target: Option<Wanted> = if wanted.is_empty() {
            None
        } else if let Some(pick) = &opts.pick_file {
            let choices: Vec<(u64, String, u64)> =
                wanted.iter().map(|file| (file.id, file.path.clone(), file.size)).collect();
            pick(&choices)?.and_then(|index| wanted.get(index)).cloned()
        } else {
            // no picker means the caller wants the main file: the largest one
            wanted.iter().reduce(|best, file| if file.size > best.size { file } else { best }).cloned()
        };

        let mut files = self.unrestrict_links(&info, filter, max_files, target.as_ref()).await?;
        if let Some(wanted_file) = &target {
            if !files.iter().any(|file| file.name == basename(&wanted_file.path)) {
                // RD served the selection as an archive: re-add selecting only the target file
                let retry_id = self.add_and_select(&magnet_uri, None, Some(wanted_file.id), None).await?;
                // the JS fires this delete without awaiting because the player is already
                // waiting; awaited best-effort here, the difference is milliseconds
                if added.is_some() {
                    self.release(&torrent_id).await;
                }
                torrent_id = retry_id;
                *added = Some(torrent_id.clone());
                let ready = self.client.budget(self.client.config.timeouts.ready);
                info = self.await_status(&torrent_id, "downloaded", ready, None).await?;
                files = self.unrestrict_links(&info, filter, 1, None).await?;
                if files.is_empty() {
                    return Err(DebridError::Service {
                        message: "Real-Debrid only serves this torrent as an archive".into(),
                        status: None,
                        code: None,
                    });
                }
            }
        }
        if files.is_empty() {
            return Err(DebridError::Service {
                message: "No playable files in this torrent".into(),
                status: None,
                code: None,
            });
        }
        // debrid links are account bound, so a cleartext one has no business reaching the player
        let files = secure_files(files, self.client.config.title)?;
        Ok(DebridResolved { hash: info.hash.clone(), name: info.filename.clone(), files })
    }
}

#[async_trait]
impl DebridProvider for RealDebrid {
    fn client(&self) -> &crate::client::DebridClient {
        &self.client
    }

    fn config(&self) -> &ProviderConfig {
        &self.client.config
    }

    async fn validate(&self) -> Result<AccountInfo, DebridError> {
        let user = self.get(&format!("{API}/user")).await?;
        if text(&user, "type").as_deref() != Some("premium") {
            return Err(DebridError::Auth {
                message: "Real-Debrid premium is required to stream torrents".into(),
                status: None,
                code: None,
            });
        }
        Ok(AccountInfo {
            username: text(&user, "username").unwrap_or_default(),
            expires: text(&user, "expiration"),
        })
    }

    /// The account list is free badge data for all three answers, not just for what it holds.
    async fn list_availability(&self) -> Result<HashMap<String, Availability>, DebridError> {
        let torrents = self.fetch_listing().await?;
        let mut known = HashMap::new();
        for torrent in torrents.as_array().map(Vec::as_slice).unwrap_or_default() {
            let Some(state) = text(torrent, "status").as_deref().and_then(status_availability) else {
                continue;
            };
            if let Some(hash) = text(torrent, "hash") {
                known.insert(hash.to_ascii_lowercase(), state);
            }
        }
        Ok(known)
    }

    async fn check_availability_batch(
        &self,
        _hashes: &[String],
    ) -> Result<HashMap<String, Availability>, DebridError> {
        // `/torrents/instantAvailability` is disabled; availability is probed a hash at a time
        Err(DebridError::Service {
            message: "Real-Debrid has no cache endpoint, availability is probed per hash".into(),
            status: None,
            code: None,
        })
    }

    /// The only way Real-Debrid can still be asked about a release: add the magnet and read
    /// the status it settles on. A cached torrent reports 'downloaded' within a second of
    /// file selection. Costs about five requests, hence `max_probes` in the config.
    ///
    /// The torrent is always removed again, and adding a hash the account already holds
    /// creates a separate entry, so this can never delete the user's own download.
    async fn probe_availability(&self, hash: &str) -> Result<Availability, DebridError> {
        let magnet_uri = to_magnet(hash).ok_or_else(|| DebridError::Service {
            // no answer, rather than a made up one
            message: "Not a usable info hash".into(),
            status: None,
            code: None,
        })?;
        // a failed add has already undone itself, so only a returned id needs cleaning up
        let torrent_id = self
            .add_and_select(&magnet_uri, Some(&(|_: &str| true)), None, Some(PROBE_CONVERSION_READS))
            .await?;
        let budget = self.client.budget(self.client.config.timeouts.probe);
        let result = self.await_status(&torrent_id, "downloaded", budget, None).await;
        // awaited, so the account is as we found it by the time this answers. Playback and
        // teardown both wait on it, so neither can trip over a half-finished probe
        self.release(&torrent_id).await;
        result.map(|_| Availability::Cached)
    }

    async fn resolve(&self, magnet: &str, opts: &ResolveOptions) -> Result<DebridResolved, DebridError> {
        let mut added: Option<String> = None;
        match self.resolve_inner(magnet, opts, &mut added).await {
            Ok(resolved) => Ok(resolved),
            Err(error) => {
                // only clean up torrents this call added, never the user's own downloads
                if let Some(torrent_id) = added {
                    self.release(&torrent_id).await;
                }
                // playback has waited as long as it can, so a magnet still converting is one
                // it cannot use. A probe leaves the same timeout unanswered instead, since
                // Real-Debrid may just be slow
                Err(match error {
                    DebridError::Timeout { .. } => DebridError::not_cached(),
                    other => other,
                })
            }
        }
    }

    async fn retry_cleanup(&self) {
        self.client.retry_cleanup(&RdDialect).await;
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{ManualClock, MockTransport, Route};
    use serde_json::json;
    use shiru_networking::{Body, HttpRequest, HttpResponse, TransportError};
    use std::sync::Mutex;

    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const HASH_UPPER: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    fn magnet() -> String {
        format!("magnet:?xt=urn:btih:{HASH}&dn=test")
    }

    fn video_filter() -> Box<dyn Fn(&str) -> bool + Send + Sync> {
        Box::new(|name| {
            let lower = name.to_ascii_lowercase();
            lower.ends_with(".mkv") || lower.ends_with(".mp4")
        })
    }

    fn video_opts() -> ResolveOptions {
        ResolveOptions { file_filter: Some(video_filter()), pick_file: None, max_files: None }
    }

    fn downloaded_info(id: &str, status: &str) -> Value {
        json!({
            "id": id,
            "hash": HASH_UPPER,
            "filename": "Test Torrent",
            "status": status,
            "files": [
                { "id": 1, "path": "/Test/Episode 01.mkv", "bytes": 1000, "selected": 1 },
                { "id": 2, "path": "/Test/readme.txt", "bytes": 10, "selected": 1 },
                { "id": 3, "path": "/Test/Episode 02.mkv", "bytes": 2000, "selected": 1 }
            ],
            "links": ["https://rd/link1", "https://rd/link2", "https://rd/link3"]
        })
    }

    fn unrestricted_body() -> String {
        json!({
            "filename": "direct.mkv",
            "filesize": 1000,
            "download": "https://rd/direct.mkv",
            "mimeType": "video/x-matroska"
        })
        .to_string()
    }

    fn rd<T: HttpTransport + 'static>(transport: &Arc<T>) -> RealDebrid {
        RealDebrid::new("test-key", transport.clone(), Arc::new(ManualClock::new()))
    }

    /// Decoded form bodies of every request whose URL contains `fragment`, in order.
    fn bodies_of(requests: &Mutex<Vec<HttpRequest>>, fragment: &str) -> Vec<String> {
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.url.contains(fragment))
            .map(|request| match &request.body {
                Some(Body::Bytes { bytes, .. }) => String::from_utf8_lossy(bytes).into_owned(),
                _ => String::new(),
            })
            .collect()
    }

    type RouteFn = Box<dyn Fn(usize) -> (u16, String) + Send + Sync>;

    /// Like MockTransport but bodies may vary per hit, for status polling and paging.
    /// First matching URL substring wins, so order routes carefully.
    struct Script {
        routes: Vec<(&'static str, RouteFn)>,
        hits: Mutex<HashMap<&'static str, usize>>,
        requests: Mutex<Vec<HttpRequest>>,
    }

    impl Script {
        fn new(routes: Vec<(&'static str, RouteFn)>) -> Arc<Self> {
            Arc::new(Script { routes, hits: Mutex::new(HashMap::new()), requests: Mutex::new(vec![]) })
        }

        fn urls(&self) -> Vec<String> {
            self.requests.lock().unwrap().iter().map(|request| request.url.clone()).collect()
        }
    }

    fn fixed(status: u16, body: Value) -> RouteFn {
        let body = body.to_string();
        Box::new(move |_| (status, body.clone()))
    }

    #[async_trait]
    impl HttpTransport for Script {
        async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
            let url = request.url.clone();
            self.requests.lock().unwrap().push(request);
            let (pattern, respond) = self
                .routes
                .iter()
                .find(|(pattern, _)| url.contains(pattern))
                .ok_or_else(|| TransportError::Network(format!("no scripted answer for {url}")))?;
            let hit = {
                let mut hits = self.hits.lock().unwrap();
                let count = hits.entry(pattern).or_insert(0);
                let hit = *count;
                *count += 1;
                hit
            };
            let (status, body) = respond(hit);
            Ok(HttpResponse { status, headers: HashMap::new(), body: body.into_bytes() })
        }
    }

    // ---- error mapping -----------------------------------------------------------------

    #[test]
    fn auth_codes_and_bare_403s_map_to_auth_errors() {
        let dialect = RdDialect;
        let bad_key = dialect.map_error(401, Some(&json!({ "error": "bad_token", "error_code": 8 })));
        assert!(matches!(&bad_key, DebridError::Auth { message, .. } if message == "Invalid Real-Debrid API key"));
        let denied = dialect.map_error(403, Some(&json!({ "error_code": 9 })));
        assert!(matches!(denied, DebridError::Auth { .. }));
        // a 401/403 with no error_code at all still means the key is the problem
        let bare = dialect.map_error(403, None);
        assert!(matches!(bare, DebridError::Auth { .. }));
    }

    #[test]
    fn per_request_codes_stay_plain_service_errors() {
        let dialect = RdDialect;
        // a blocked or unavailable file also answers 403, and must stay a plain error: an
        // auth error aborts the whole resolve, where one bad file should only be skipped
        let blocked = dialect.map_error(403, Some(&json!({ "error": "file_unavailable", "error_code": 35 })));
        assert!(matches!(&blocked, DebridError::Service { message, code: Some(code), .. }
            if message == "Real-Debrid will not serve this file, pick a different release" && code == "35"));
        let capped = dialect.map_error(509, Some(&json!({ "error_code": 21 })));
        assert!(matches!(capped, DebridError::Service { .. }));
        assert!(RealDebrid::throttled(&capped), "code 21 means back off, not broken");
        let plain = dialect.map_error(500, Some(&json!({ "error": "internal" })));
        assert!(matches!(&plain, DebridError::Service { message, .. } if message == "internal"));
    }

    // ---- validate ----------------------------------------------------------------------

    #[tokio::test]
    async fn validate_accepts_premium_accounts() {
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "/user",
            200,
            &json!({ "username": "tester", "type": "premium", "expiration": "2030-01-01" }).to_string(),
        )]));
        let account = rd(&transport).validate().await.unwrap();
        assert_eq!(account.username, "tester");
        assert_eq!(account.expires.as_deref(), Some("2030-01-01"));
    }

    #[tokio::test]
    async fn validate_rejects_free_accounts() {
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "/user",
            200,
            &json!({ "username": "tester", "type": "free" }).to_string(),
        )]));
        let error = rd(&transport).validate().await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
    }

    #[tokio::test]
    async fn validate_maps_auth_failures() {
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "/user",
            401,
            &json!({ "error": "bad_token", "error_code": 8 }).to_string(),
        )]));
        let error = rd(&transport).validate().await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
    }

    #[tokio::test]
    async fn requires_an_api_key() {
        let transport = Arc::new(MockTransport::new(vec![]));
        let service = RealDebrid::new("", transport, Arc::new(ManualClock::new()));
        let error = service.validate().await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
    }

    // ---- listing -----------------------------------------------------------------------

    #[tokio::test]
    async fn list_availability_reads_every_status_as_what_it_means_for_playback() {
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "/torrents?limit",
            200,
            &json!([
                { "hash": HASH_UPPER, "status": "downloaded" },
                { "hash": "b".repeat(40), "status": "downloading" },
                { "hash": "c".repeat(40), "status": "magnet_error" },
                { "hash": "d".repeat(40), "status": "virus" },
                { "hash": "e".repeat(40), "status": "magnet_conversion" }
            ])
            .to_string(),
        )]));
        let known = rd(&transport).list_availability().await.unwrap();
        assert_eq!(known.get(HASH), Some(&Availability::Cached), "lowercased, and instantly streamable");
        assert_eq!(known.get(&"b".repeat(40)), Some(&Availability::Available), "still being fetched");
        assert_eq!(known.get(&"c".repeat(40)), Some(&Availability::Unavailable));
        assert_eq!(known.get(&"d".repeat(40)), Some(&Availability::Unavailable));
        assert!(!known.contains_key(&"e".repeat(40)), "mid-conversion is a moment, not an outcome");
        // the whole account must be badged in one request, so the limit beats the page size
        let urls = transport.urls();
        assert_eq!(urls.len(), 1);
        assert!(urls[0].contains("limit=1000"), "asked with {}", urls[0]);
    }

    #[tokio::test]
    async fn batch_checking_is_not_a_thing_real_debrid_offers() {
        let transport = Arc::new(MockTransport::new(vec![]));
        let error = rd(&transport).check_availability_batch(&[HASH.to_string()]).await.unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }));
        assert!(transport.urls().is_empty(), "and it must not invent a request to answer with");
    }

    // ---- resolve -----------------------------------------------------------------------

    #[tokio::test]
    async fn resolve_adds_selects_and_unrestricts_with_aligned_links() {
        let transport = Script::new(vec![
            ("/torrents/addMagnet", fixed(201, json!({ "id": "TORRENT1" }))),
            ("/torrents/selectFiles/TORRENT1", fixed(204, json!(null))),
            ("/torrents/info/TORRENT1", {
                let waiting = downloaded_info("TORRENT1", "waiting_files_selection");
                let done = downloaded_info("TORRENT1", "downloaded");
                Box::new(move |hit| {
                    (200, if hit == 0 { waiting.to_string() } else { done.to_string() })
                })
            }),
            ("/unrestrict/link", fixed(200, serde_json::from_str(&unrestricted_body()).unwrap())),
            ("/torrents?limit", fixed(200, json!([]))),
        ]);
        let resolved = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.hash, HASH, "the API's uppercase hash comes back lowercased");
        assert_eq!(resolved.name, "Test Torrent");
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        assert_eq!(paths, ["/Test/Episode 01.mkv", "/Test/Episode 02.mkv"]);
        assert!(resolved.files.iter().all(|file| file.url == "https://rd/direct.mkv"));
        // only the filtered files were selected
        assert_eq!(bodies_of(&transport.requests, "/torrents/selectFiles"), ["files=1%2C3"]);
        // the readme's link must be skipped via alignment, not position guessing
        assert_eq!(
            bodies_of(&transport.requests, "/unrestrict/link"),
            ["link=https%3A%2F%2Frd%2Flink1", "link=https%3A%2F%2Frd%2Flink3"]
        );
    }

    #[tokio::test]
    async fn resolve_reuses_a_downloaded_torrent_already_on_the_account() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/info/TORRENT9", 200, &downloaded_info("TORRENT9", "downloaded").to_string()),
            Route::json("/torrents?limit", 200, &json!([{ "id": "TORRENT9", "hash": HASH, "status": "downloaded" }]).to_string()),
            Route::json("/unrestrict/link", 200, &unrestricted_body()),
        ]));
        let resolved = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.files.len(), 2);
        assert!(!transport.urls().iter().any(|url| url.contains("addMagnet")), "must not add a duplicate torrent");
    }

    #[tokio::test]
    async fn resolve_deletes_its_own_magnet_when_the_torrent_is_not_cached() {
        // after selection the torrent goes to queued, i.e. a fresh download
        let transport = Script::new(vec![
            ("/torrents/addMagnet", fixed(201, json!({ "id": "TORRENT1" }))),
            ("/torrents/selectFiles/TORRENT1", fixed(204, json!(null))),
            ("/torrents/info/TORRENT1", {
                let waiting = downloaded_info("TORRENT1", "waiting_files_selection");
                let queued = downloaded_info("TORRENT1", "queued");
                Box::new(move |hit| (200, if hit == 0 { waiting.to_string() } else { queued.to_string() }))
            }),
            ("/torrents/delete/TORRENT1", fixed(204, json!(null))),
            ("/torrents?limit", fixed(200, json!([]))),
        ]);
        let error = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        assert_eq!(error.proven_availability(), Some(Availability::Available));
        assert!(transport.urls().iter().any(|url| url.contains("/torrents/delete/TORRENT1")),
            "the magnet it added is taken back off the account");
    }

    // found against the live API: a hash Real-Debrid cannot find peers for sits in
    // magnet_conversion until the budget runs out. Playback cannot wait, so it has to read
    // as "not cached" and fall back to the torrent, rather than as a raw error.
    #[tokio::test]
    async fn a_magnet_that_never_converts_is_not_cached_as_far_as_playback_is_concerned() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/addMagnet", 201, &json!({ "id": "TORRENT1" }).to_string()),
            Route::json("/torrents/info/TORRENT1", 200,
                &json!({ "id": "TORRENT1", "status": "magnet_conversion", "files": [], "links": [] }).to_string()),
            Route::json("/torrents/delete/TORRENT1", 204, ""),
            Route::json("/torrents?limit", 200, "[]"),
        ]));
        let error = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }), "a timeout playback cannot wait out reads as uncached");
        assert!(transport.urls().iter().any(|url| url.contains("/torrents/delete/TORRENT1")));
    }

    // the same timeout during a badge check proves nothing: Real-Debrid may simply be slow,
    // and calling it a miss is what empties the badges on exactly the rarer titles
    #[tokio::test]
    async fn the_same_timeout_during_a_probe_leaves_the_release_unanswered_instead() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/addMagnet", 201, &json!({ "id": "TORRENT1" }).to_string()),
            Route::json("/torrents/info/TORRENT1", 200,
                &json!({ "id": "TORRENT1", "status": "magnet_conversion", "files": [], "links": [] }).to_string()),
            Route::json("/torrents/delete/TORRENT1", 204, ""),
        ]));
        let error = rd(&transport).probe_availability(HASH).await.unwrap_err();
        assert_eq!(error.proven_availability(), None, "no answer is not a negative answer");
        // a stalled magnet gets a fixed number of reads, not a fixed number of seconds
        let info_reads = transport.urls().iter().filter(|url| url.contains("/torrents/info/")).count();
        assert_eq!(info_reads as u32, PROBE_CONVERSION_READS);
        let deletes = transport.urls().iter().filter(|url| url.contains("/torrents/delete/")).count();
        assert_eq!(deletes, 1, "and the account is left as it was found");
    }

    // ---- probe -------------------------------------------------------------------------

    // Regression (JS): the probe used to fire its delete without awaiting it, so it answered
    // while it still owned a torrent on the account.
    #[tokio::test]
    async fn a_probe_removes_its_torrent_before_it_answers() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/addMagnet", 201, &json!({ "id": "PROBE1" }).to_string()),
            Route::json("/torrents/info/PROBE1", 200, &downloaded_info("PROBE1", "downloaded").to_string()),
            Route::json("/torrents/delete/PROBE1", 204, ""),
        ]));
        let state = rd(&transport).probe_availability(HASH).await.unwrap();
        assert_eq!(state, Availability::Cached);
        let urls = transport.urls();
        assert!(urls.last().unwrap().contains("/torrents/delete/PROBE1"), "the probe must clean up after itself");
        assert_eq!(urls.iter().filter(|url| url.contains("/torrents/delete/")).count(), 1);
    }

    #[tokio::test]
    async fn a_cached_release_still_answers_within_the_conversion_reads() {
        // mirrors slowlink.test.js: waiting_files_selection on the first read, downloaded after
        let transport = Script::new(vec![
            ("/torrents/addMagnet", fixed(201, json!({ "id": "PROBE1" }))),
            ("/torrents/selectFiles/PROBE1", fixed(204, json!(null))),
            ("/torrents/info/PROBE1", {
                let waiting = downloaded_info("PROBE1", "waiting_files_selection");
                let done = downloaded_info("PROBE1", "downloaded");
                Box::new(move |hit| (200, if hit == 0 { waiting.to_string() } else { done.to_string() }))
            }),
            ("/torrents/delete/PROBE1", fixed(204, json!(null))),
        ]);
        assert_eq!(rd(&transport).probe_availability(HASH).await.unwrap(), Availability::Cached);
        assert!(transport.urls().last().unwrap().contains("/torrents/delete/PROBE1"));
    }

    // probing tells the two negatives apart, which is the whole reason a Real-Debrid search
    // can show more than "cached or who knows"
    #[tokio::test]
    async fn a_probe_separates_a_release_rd_would_fetch_from_one_it_can_never_serve() {
        for (status, expected) in [
            ("downloading", Availability::Available),
            ("queued", Availability::Available),
            ("magnet_error", Availability::Unavailable),
            ("dead", Availability::Unavailable),
        ] {
            let transport = Arc::new(MockTransport::new(vec![
                Route::json("/torrents/addMagnet", 201, &json!({ "id": "PROBE2" }).to_string()),
                Route::json("/torrents/info/PROBE2", 200, &downloaded_info("PROBE2", status).to_string()),
                Route::json("/torrents/delete/PROBE2", 204, ""),
            ]));
            let error = rd(&transport).probe_availability(HASH).await.unwrap_err();
            assert_eq!(error.proven_availability(), Some(expected), "status {status}");
            let deletes = transport.urls().iter().filter(|url| url.contains("/torrents/delete/")).count();
            assert_eq!(deletes, 1, "a {status} probe must not leave a torrent on the account");
        }
    }

    #[tokio::test]
    async fn a_probe_refuses_to_invent_an_answer_for_an_unusable_hash() {
        let transport = Arc::new(MockTransport::new(vec![]));
        let error = rd(&transport).probe_availability("not-a-hash").await.unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }));
        assert_eq!(error.proven_availability(), None);
        assert!(transport.urls().is_empty());
    }

    // ---- account torrents in other states ------------------------------------------------

    // playback reads the same typed errors the probe does, so a fallback and a badge agree
    #[tokio::test]
    async fn resolve_reports_a_dead_account_torrent_as_unavailable_rather_than_uncached() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/info/TORRENT9", 200, &downloaded_info("TORRENT9", "error").to_string()),
            Route::json("/torrents?limit", 200, &json!([{ "id": "TORRENT9", "hash": HASH, "status": "error" }]).to_string()),
        ]));
        let error = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::Unavailable { .. }));
        assert_eq!(error.proven_availability(), Some(Availability::Unavailable));
        assert!(!transport.urls().iter().any(|url| url.contains("/delete/")),
            "must never delete torrents it did not add");
    }

    #[tokio::test]
    async fn resolve_treats_an_account_torrent_still_downloading_as_not_cached_without_deleting_it() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/info/TORRENT9", 200, &downloaded_info("TORRENT9", "downloading").to_string()),
            Route::json("/torrents?limit", 200, &json!([{ "id": "TORRENT9", "hash": HASH, "status": "downloading" }]).to_string()),
        ]));
        let error = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::NotCached { .. }));
        assert!(!transport.urls().iter().any(|url| url.contains("/delete/")));
    }

    #[tokio::test]
    async fn resolve_fails_when_the_torrent_has_no_links_at_all() {
        let mut no_links = downloaded_info("TORRENT9", "downloaded");
        no_links["links"] = json!([]);
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/info/TORRENT9", 200, &no_links.to_string()),
            Route::json("/torrents?limit", 200, &json!([{ "id": "TORRENT9", "hash": HASH, "status": "downloaded" }]).to_string()),
        ]));
        let error = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::Service { .. }));
    }

    // the listing is shared and up to a minute old, so an id it names may already be gone.
    // That has to read as "not on the account" and add the magnet, not fail the play.
    #[tokio::test]
    async fn a_torrent_deleted_since_the_listing_was_read_is_added_again_rather_than_failing_playback() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents/info/GONE", 404, &json!({ "error": "unknown_ressource", "error_code": 7 }).to_string()),
            Route::json("/torrents/addMagnet", 201, &json!({ "id": "FRESH" }).to_string()),
            Route::json("/torrents/info/FRESH", 200, &downloaded_info("FRESH", "downloaded").to_string()),
            Route::json("/unrestrict/link", 200, &unrestricted_body()),
            Route::json("/torrents?limit", 200, &json!([{ "id": "GONE", "hash": HASH, "status": "downloaded" }]).to_string()),
        ]));
        let resolved = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.files.len(), 2, "playback still gets its files");
        let urls = transport.urls();
        assert!(urls.iter().any(|url| url.contains("addMagnet")), "the magnet is added instead of reusing a dead id");
        assert!(!urls.iter().any(|url| url.contains("/delete/")), "and nothing is deleted on the way");
    }

    // ---- packs and windowing -------------------------------------------------------------

    fn pack_info(count: usize) -> Value {
        let files: Vec<Value> = (1..=count)
            .map(|index| json!({
                "id": index,
                "path": format!("/Pack/Episode {index:03}.mkv"),
                "bytes": 1000,
                "selected": 1
            }))
            .collect();
        let links: Vec<String> = (1..=count).map(|index| format!("https://rd/link{index}")).collect();
        json!({ "id": "PACK1", "hash": HASH_UPPER, "filename": "Big Pack", "status": "downloaded", "files": files, "links": links })
    }

    // A pack larger than max_files cannot be unrestricted whole. Truncating to the first N
    // used to drop the requested episode, which then triggered a re-add and left a duplicate
    // torrent on the account on every play of a late episode.
    #[tokio::test]
    async fn a_capped_pack_keeps_the_requested_episode_instead_of_the_first_n_files() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents?limit", 200, &json!([{ "id": "PACK1", "hash": HASH, "status": "downloaded" }]).to_string()),
            Route::json("/torrents/info/", 200, &pack_info(150).to_string()),
            Route::json("/unrestrict/link", 200, &json!({ "download": "https://cdn/file.mkv", "filesize": 1000 }).to_string()),
        ]));
        let opts = ResolveOptions {
            file_filter: Some(video_filter()),
            pick_file: Some(Box::new(|files| Ok(files.iter().position(|(_, path, _)| path == "/Pack/Episode 100.mkv")))),
            max_files: Some(60),
        };
        let resolved = rd(&transport).resolve(&magnet(), &opts).await.unwrap();
        assert_eq!(resolved.files.len(), 60, "the cap is still respected");
        let paths: Vec<&str> = resolved.files.iter().map(|file| file.path.as_str()).collect();
        assert!(paths.contains(&"/Pack/Episode 100.mkv"), "the requested episode must survive the cap");
        // neighbours are kept so in-player next/previous still works around the playing episode
        assert!(paths.contains(&"/Pack/Episode 099.mkv"));
        assert!(paths.contains(&"/Pack/Episode 101.mkv"));
        let mut sorted = paths.clone();
        sorted.sort();
        assert_eq!(paths, sorted, "files stay in torrent order for episode navigation");
        assert!(!transport.urls().iter().any(|url| url.contains("addMagnet")),
            "a reused account torrent must never be re-added");
    }

    #[tokio::test]
    async fn a_pack_within_the_cap_is_returned_whole() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents?limit", 200, &json!([{ "id": "PACK1", "hash": HASH, "status": "downloaded" }]).to_string()),
            Route::json("/torrents/info/", 200, &pack_info(10).to_string()),
            Route::json("/unrestrict/link", 200, &json!({ "download": "https://cdn/file.mkv", "filesize": 1000 }).to_string()),
        ]));
        let opts = ResolveOptions { file_filter: Some(video_filter()), pick_file: None, max_files: Some(60) };
        let resolved = rd(&transport).resolve(&magnet(), &opts).await.unwrap();
        assert_eq!(resolved.files.len(), 10);
    }

    // real RD behavior: the cached copy may serve fewer links than files selected, e.g. 3
    // selected files but a single link for just the video
    #[tokio::test]
    async fn resolve_unrestricts_all_links_and_filters_by_filename_when_counts_differ() {
        let mut two_links = downloaded_info("TORRENT9", "downloaded");
        two_links["links"] = json!(["https://rd/video", "https://rd/poster"]);
        let transport = Script::new(vec![
            ("/torrents/info/TORRENT9", fixed(200, two_links)),
            ("/torrents?limit", fixed(200, json!([{ "id": "TORRENT9", "hash": HASH, "status": "downloaded" }]))),
            ("/unrestrict/link", Box::new(|hit| {
                let body = if hit == 0 {
                    json!({ "filename": "Episode 01.mkv", "filesize": 1000, "download": "https://rd/direct.mkv", "mimeType": "video/x-matroska" })
                } else {
                    json!({ "filename": "poster.jpg", "filesize": 50, "download": "https://rd/poster.jpg", "mimeType": "image/jpeg" })
                };
                (200, body.to_string())
            })),
        ]);
        let opts = ResolveOptions {
            file_filter: Some(video_filter()),
            pick_file: Some(Box::new(|files| Ok(files.iter().position(|(_, path, _)| path.contains("Episode 01"))))),
            max_files: None,
        };
        let resolved = rd(&transport).resolve(&magnet(), &opts).await.unwrap();
        let names: Vec<&str> = resolved.files.iter().map(|file| file.name.as_str()).collect();
        assert_eq!(names, ["Episode 01.mkv"]);
        assert_eq!(transport.urls().iter().filter(|url| url.contains("/unrestrict/link")).count(), 2);
    }

    // Real packs contain the odd dead file: a live 150-file pack returned RD error_code 19
    // (hoster_unavailable, HTTP 503) on one link, which used to fail the entire resolve.
    #[tokio::test]
    async fn one_dead_file_in_a_pack_does_not_sink_the_whole_resolve() {
        let transport = Script::new(vec![
            ("/torrents?limit", fixed(200, json!([{ "id": "PACK1", "hash": HASH, "status": "downloaded" }]))),
            ("/torrents/info/", fixed(200, downloaded_info("PACK1", "downloaded"))),
            ("/unrestrict/link", Box::new(|hit| {
                if hit == 0 {
                    (503, json!({ "error": "hoster_unavailable", "error_code": 19 }).to_string())
                } else {
                    (200, json!({ "download": "https://cdn/file.mkv", "filesize": 1000 }).to_string())
                }
            })),
        ]);
        let resolved = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap();
        assert_eq!(resolved.files.len(), 1, "the surviving file must still play");
    }

    // every link would fail for the same reason, so this is not a per file problem to skip
    #[tokio::test]
    async fn an_auth_failure_while_unrestricting_still_surfaces_as_an_auth_error() {
        let transport = Arc::new(MockTransport::new(vec![
            Route::json("/torrents?limit", 200, &json!([{ "id": "PACK1", "hash": HASH, "status": "downloaded" }]).to_string()),
            Route::json("/torrents/info/", 200, &downloaded_info("PACK1", "downloaded").to_string()),
            Route::json("/unrestrict/link", 401, &json!({ "error": "bad_token", "error_code": 8 }).to_string()),
        ]));
        let error = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap_err();
        assert!(matches!(error, DebridError::Auth { .. }));
    }

    // real RD behavior: selecting multiple files can serve one RAR archive, the client must
    // re-add the torrent selecting only the target file
    #[tokio::test]
    async fn resolve_recovers_from_an_rd_generated_archive_by_re_adding_with_a_single_file() {
        let mut first = downloaded_info("FIRST", "downloaded");
        first["links"] = json!(["https://rd/archive"]); // 3 selected files, 1 link: unaligned
        let retry = json!({
            "id": "RETRY", "hash": HASH_UPPER, "filename": "Test Torrent", "status": "downloaded",
            "files": [{ "id": 3, "path": "/Test/Episode 02.mkv", "bytes": 2000, "selected": 1 }],
            "links": ["https://rd/single"]
        });
        let transport = Script::new(vec![
            ("/torrents/addMagnet", Box::new(|hit| {
                (201, json!({ "id": if hit == 0 { "FIRST" } else { "RETRY" } }).to_string())
            })),
            ("/torrents/info/FIRST", fixed(200, first)),
            ("/torrents/info/RETRY", fixed(200, retry)),
            ("/torrents/delete/FIRST", fixed(204, json!(null))),
            ("/unrestrict/link", Box::new(|hit| {
                let body = if hit == 0 {
                    json!({ "filename": "Test.rar", "filesize": 3000, "download": "https://rd/archive.rar", "mimeType": "application/x-rar-compressed" })
                } else {
                    json!({ "filename": "Episode 02.mkv", "filesize": 2000, "download": "https://rd/direct2.mkv", "mimeType": "video/x-matroska" })
                };
                (200, body.to_string())
            })),
            ("/torrents?limit", fixed(200, json!([]))),
        ]);
        let resolved = rd(&transport).resolve(&magnet(), &video_opts()).await.unwrap();
        let names: Vec<&str> = resolved.files.iter().map(|file| file.name.as_str()).collect();
        assert_eq!(names, ["Episode 02.mkv"]);
        assert_eq!(resolved.files[0].url, "https://rd/direct2.mkv");
        let urls = transport.urls();
        assert!(urls.iter().any(|url| url.contains("/torrents/delete/FIRST")), "replaced torrent must be cleaned up");
        assert_eq!(urls.iter().filter(|url| url.contains("addMagnet")).count(), 2, "one add, one single-file retry");
        // the retry named the file outright rather than re-filtering
        assert!(bodies_of(&transport.requests, "/torrents/selectFiles").is_empty()
            || bodies_of(&transport.requests, "/torrents/selectFiles").iter().all(|body| body == "files=3"));
    }
}
