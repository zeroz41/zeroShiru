//! The debrid layer: typed errors, provider trait, availability bookkeeping and the
//! pure request-shaping helpers. Providers only talk HTTP through the injected
//! transport, so the same implementations serve native and TV hosts.
//!
//! Port of common/modules/debrid/service.js; the test files under
//! test/unit/debrid/ are the behavioural reference.

pub mod client;
pub mod limiter;
pub mod manager;
pub mod error;
pub mod platform;
pub mod window;
pub mod providers;
#[cfg(test)]
pub mod testing;

pub use client::{map_files, DebridClient, Dialect, PlainDialect, RequestOpts};
pub use error::DebridError;
pub use manager::{create_provider, ManagedProvider};
pub use platform::Platform;
pub use window::window_files;

use async_trait::async_trait;
use shiru_domain::{Availability, DebridResolved};
use std::collections::HashMap;

/// How the API key travels: an Authorization header or a query parameter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthScheme {
    Bearer,
    Query,
}

/// How request bodies are encoded, overridable per request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BodyEncoding {
    Form,
    Json,
    Multipart,
}

/// How the service can be asked about a release it has not seen. `Batch` answers many
/// hashes per request, `Probe` adds the magnet and reads the status back, `None`
/// leaves badges to the account listing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AvailabilityCheck {
    Batch,
    Probe,
    None,
}

/// Time limits in milliseconds. All but `request` are poll budgets.
#[derive(Debug, Clone, Copy)]
pub struct Timeouts {
    /// Hard ceiling on one round trip, deliberately does not stretch.
    pub request: u64,
    /// Waiting for the service to accept a magnet and expose its file list.
    pub select: u64,
    /// Waiting for a cached torrent to report ready, anything slower is a fresh download.
    pub ready: u64,
    /// Gap between status polls.
    pub poll: u64,
    /// Tighter than `select`: a probe that drags on spends requests playback needs.
    pub probe: u64,
    /// The whole of one resolve, end to end. Every other budget here bounds a single
    /// round trip, and a resolve is many of them — add the magnet, poll until it settles,
    /// then a link request per file. A service answering slowly, or not at all, could
    /// therefore keep somebody staring at a black screen for minutes with nothing said.
    /// Generous, because a slow service is still worth waiting for; finite, because a
    /// silent one is not.
    pub resolve: u64,
}

impl Default for Timeouts {
    fn default() -> Self {
        Timeouts { request: 30_000, select: 12_000, ready: 5_000, poll: 1_000, probe: 10_000, resolve: 60_000 }
    }
}

/// A provider's static configuration — the statics on the JS DebridService subclasses.
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    /// Unique lowercase identifier, e.g. "realdebrid".
    pub id: &'static str,
    /// Human readable service name.
    pub title: &'static str,
    pub auth: AuthScheme,
    /// Query parameter name used when `auth` is `Query`.
    pub auth_param: &'static str,
    pub encoding: BodyEncoding,
    pub timeouts: Timeouts,
    /// Round trip time the limits above are written for, in milliseconds.
    pub nominal_latency: u64,
    /// Most files one resolve turns into stream links, guards against huge season packs.
    pub max_files: usize,
    pub availability_check: AvailabilityCheck,
    /// Whether asking about a release puts a magnet on the account rather than reading a
    /// cache index. Usually implied by Probe mode, but AllDebrid's batch check uploads
    /// magnets too. Two things follow: only one such check may be in flight, and a hash
    /// the answer leaves out is unasked rather than "not cached".
    pub check_adds_magnets: bool,
    /// Hashes per batch request.
    pub max_batch: usize,
    /// Most probes one results list may cost, since each is several requests.
    pub max_probes: usize,
    /// Max concurrent requests / min gap between requests, for the rate limiter.
    pub max_concurrent: usize,
    pub min_time_ms: u64,
    /// The allowance a service publishes, as `(requests, window_ms)`. `None` where the
    /// service documents none and the concurrency/spacing limits are the whole story.
    pub reservoir: Option<(u32, u64)>,
}

impl ProviderConfig {
    /// How far down a results list this service looks. Checks that own a magnet per
    /// answer are capped like probes, whatever mode carries them.
    pub fn max_ask(&self) -> usize {
        if self.availability_check == AvailabilityCheck::Probe || self.check_adds_magnets {
            self.max_probes
        } else {
            usize::MAX
        }
    }
}

/// Chooses the file playback wants out of a pack's (id, path, size) list.
/// `Ok(None)` means "no opinion, window from the front"; an error refuses the
/// release outright, which is how "this pack does not hold that episode" travels.
pub type PickFile = Box<dyn Fn(&[(u64, String, u64)]) -> Result<Option<usize>, DebridError> + Send + Sync>;
pub type FileFilter = Box<dyn Fn(&str) -> bool + Send + Sync>;

/// Options for a resolve call.
#[derive(Default)]
pub struct ResolveOptions {
    /// Keeps only files playback can use (video/subtitle/font names).
    pub file_filter: Option<FileFilter>,
    /// Picks the file playback wants out of a pack's file list.
    pub pick_file: Option<PickFile>,
    pub max_files: Option<usize>,
}

/// What a provider must implement. Everything stateful (rate limiting, availability
/// memory, listing cache) lives in the shared `DebridManager` layer, so providers
/// stay thin HTTP mappings.
#[async_trait]
pub trait DebridProvider: Send + Sync {
    fn config(&self) -> &ProviderConfig;

    /// The shared client, for the manager layer's availability memory and budgets.
    fn client(&self) -> &client::DebridClient;

    /// Verifies the API key and that the account can stream torrents.
    async fn validate(&self) -> Result<AccountInfo, DebridError>;

    /// Reads the account's torrent listing: hash -> availability, the free badge source.
    async fn list_availability(&self) -> Result<HashMap<String, Availability>, DebridError>;

    /// Asks about many releases at once, for APIs with a cache endpoint.
    async fn check_availability_batch(
        &self,
        hashes: &[String],
    ) -> Result<HashMap<String, Availability>, DebridError>;

    /// What the service can do with one release, for APIs with no cache endpoint.
    /// Must leave the account exactly as it found it.
    async fn probe_availability(&self, hash: &str) -> Result<Availability, DebridError>;

    /// Resolves a magnet to direct stream URLs. URLs must be HTTPS.
    async fn resolve(&self, magnet: &str, opts: &ResolveOptions) -> Result<DebridResolved, DebridError>;

    /// Retries removals this client owes the account. Providers that put magnets on the
    /// account while answering implement it; the rest have nothing to undo. The manager
    /// calls it before a check adds anything new.
    async fn retry_cleanup(&self) {}

    /// Whether an error means the service wants fewer requests rather than that this
    /// release is a problem — a sweep stops on one. A `429` always counts; providers
    /// whose APIs say it in their own error codes instead override this and say so.
    fn throttled(&self, error: &DebridError) -> bool {
        error.throttled()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountInfo {
    pub username: String,
    pub expires: Option<String>,
}

/// Drops any link that is not HTTPS. Debrid links are account bound, so a cleartext one
/// would put the user's traffic and their link on the wire in the clear.
pub fn secure_files(
    files: Vec<shiru_domain::DebridFile>,
    title: &str,
) -> Result<Vec<shiru_domain::DebridFile>, DebridError> {
    let secure: Vec<_> = files
        .into_iter()
        .filter(|file| {
            let url = file.url.as_str();
            url.len() >= 8 && url[..8].eq_ignore_ascii_case("https://")
        })
        .collect();
    if secure.is_empty() {
        return Err(DebridError::Service { message: format!("{title} returned no secure stream links"), status: None, code: None });
    }
    Ok(secure)
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiru_domain::DebridFile;

    fn file(url: &str) -> DebridFile {
        DebridFile { name: "a.mkv".into(), path: "/a.mkv".into(), size: 1, url: url.into(), r#type: None }
    }

    // mirrors test/unit/debrid/secure.test.js
    #[test]
    fn secure_files_drops_cleartext_and_keeps_https() {
        let kept = secure_files(vec![file("https://cdn/a.mkv"), file("http://cdn/a.mkv")], "Svc").unwrap();
        assert_eq!(kept.len(), 1);
        assert!(kept[0].url.starts_with("https://"));
    }

    #[test]
    fn secure_files_errors_when_nothing_secure_remains() {
        assert!(secure_files(vec![file("http://cdn/a.mkv")], "Svc").is_err());
        assert!(secure_files(vec![], "Svc").is_err());
    }

    #[test]
    fn probe_configs_add_magnets_and_cap_asking() {
        let mut config = ProviderConfig {
            id: "x", title: "X", auth: AuthScheme::Bearer, auth_param: "apikey",
            encoding: BodyEncoding::Form, timeouts: Timeouts::default(), nominal_latency: 300,
            max_files: 60, availability_check: AvailabilityCheck::Probe, check_adds_magnets: true, max_batch: 100,
            max_probes: 10, max_concurrent: 4, min_time_ms: 250, reservoir: None,
        };
        assert!(config.check_adds_magnets);
        assert_eq!(config.max_ask(), 10);
        config.availability_check = AvailabilityCheck::Batch;
        config.check_adds_magnets = false;
        assert_eq!(config.max_ask(), usize::MAX);
        // AllDebrid's shape: a batch endpoint that still owns a magnet per answer
        config.check_adds_magnets = true;
        assert_eq!(config.max_ask(), 10);
    }
}
