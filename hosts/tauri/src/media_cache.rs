//! The art cache: remote images served through `shiru-media://`, kept as plain files
//! in the platform's real cache directory, under a hard cap this module enforces.
//!
//! WebKit has an HTTP cache, but it is WebKit's: it shares space with every page the
//! extensions ever scraped, its eviction answers to disk heuristics rather than to
//! this app, and (through wry) it does not even live in the cache directory. That is
//! how cover art the user looks at every day kept being refetched. Art URLs are
//! effectively immutable — the CDNs name files by content — so the right cache is
//! the dumbest possible one: fetch once, keep the bytes, never revalidate, and evict
//! the least-recently-shown only when the cap says so.
//!
//! On disk: `<cache dir>/media/<sha256 of the url>` holds the bytes, `<...>.ct` the
//! content type. A read touches the file's mtime, which is the whole LRU bookkeeping.
//! Linux keeps this under `~/.cache/<id>`, Windows under `%LOCALAPPDATA%\<id>`,
//! macOS under `~/Library/Caches/<id>` — wherever Tauri says the cache dir is.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Instant, SystemTime};

/// The scheme the frontend bridge rewrites http(s) image URLs into.
pub const SCHEME: &str = "shiru-media";

/// The cap. Half a gigabyte holds tens of thousands of covers; a library that big is
/// still served, it just stops remembering what has not been on screen the longest.
const CAP_BYTES: u64 = 512 * 1024 * 1024;
/// Where a trim stops, below the cap so one new image does not re-trigger it.
const TRIM_TARGET_BYTES: u64 = CAP_BYTES / 10 * 9;
/// A single "image" larger than this is not an image worth keeping.
const MAX_IMAGE_BYTES: u64 = 24 * 1024 * 1024;
const FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(25);
/// How long a failed fetch is remembered. A dead art URL used to be refetched on every
/// single mount — one missing cover on a grid page was a network round trip per card
/// render, forever. Failures are only ever remembered in memory: a restart forgets them.
const FAILURE_TTL: std::time::Duration = std::time::Duration::from_secs(10 * 60);

/// Fetches in flight, keyed by URL. Two cards showing the same art used to fetch it
/// twice and interleave writes into one shared temp path; now the second waits for the
/// first and reads the stored file.
fn pending() -> &'static Mutex<HashMap<String, tokio::sync::watch::Receiver<()>>> {
    static PENDING: OnceLock<Mutex<HashMap<String, tokio::sync::watch::Receiver<()>>>> = OnceLock::new();
    PENDING.get_or_init(Default::default)
}

/// Recent failures, keyed by URL.
fn failures() -> &'static Mutex<HashMap<String, Instant>> {
    static FAILURES: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    FAILURES.get_or_init(Default::default)
}

/// Whether this URL failed recently enough that asking again is just noise.
fn recently_failed(url: &str) -> bool {
    let mut failed = failures().lock().unwrap();
    match failed.get(url) {
        Some(at) if at.elapsed() < FAILURE_TTL => true,
        Some(_) => {
            failed.remove(url);
            false
        }
        None => false,
    }
}

/// Where the images live: `media/` under the app's cache directory.
pub fn media_dir(app: &tauri::AppHandle) -> Option<PathBuf> {
    use tauri::Manager;
    app.path().app_cache_dir().ok().map(|dir| dir.join("media"))
}

/// The original URL, recovered from the request path the webview sends the scheme
/// handler: `/<percent-encoded url>` (the host part of the URI is decoration on
/// every platform). Anything that does not decode to a public-looking http(s) URL
/// is refused here, before it reaches the network stack.
pub fn url_from_path(path: &str) -> Option<String> {
    let encoded = path.trim_start_matches('/');
    let url = percent_encoding::percent_decode_str(encoded).decode_utf8().ok()?;
    if url.starts_with("http://") || url.starts_with("https://") {
        Some(url.into_owned())
    } else {
        None
    }
}

/// The file a URL is stored at. Content-addressed by the URL itself, so the same art
/// referenced from ten places is one file.
fn file_for(dir: &Path, url: &str) -> PathBuf {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(url.as_bytes());
    let mut name = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write;
        let _ = write!(name, "{byte:02x}");
    }
    dir.join(name)
}

/// The cached bytes and content type, if this URL has been fetched before. Reading
/// is what keeps an entry alive: the mtime it touches is what the janitor sorts by.
fn lookup(dir: &Path, url: &str) -> Option<(Vec<u8>, String)> {
    let file = file_for(dir, url);
    let bytes = std::fs::read(&file).ok()?;
    let content_type = std::fs::read_to_string(meta_path(&file)).unwrap_or_else(|_| "image/jpeg".into());
    if let Ok(handle) = std::fs::File::options().append(true).open(&file) {
        let _ = handle.set_modified(SystemTime::now());
    }
    Some((bytes, content_type))
}

fn meta_path(file: &Path) -> PathBuf {
    let mut meta = file.as_os_str().to_owned();
    meta.push(".ct");
    PathBuf::from(meta)
}

/// Stores fetched bytes. Written beside the final name and renamed into place, so a
/// crash mid-write leaves a stray temp file for the janitor rather than a truncated
/// image that would be served forever.
fn store(dir: &Path, url: &str, bytes: &[u8], content_type: &str) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let file = file_for(dir, url);
    // a name of this writer's own, so two writers can never interleave into one temp
    // file and rename a torn image into place — it would be served forever
    static WRITER: AtomicU64 = AtomicU64::new(0);
    let temp = file.with_extension(format!("tmp{}", WRITER.fetch_add(1, Ordering::Relaxed)));
    if std::fs::write(&temp, bytes).is_ok() && std::fs::rename(&temp, &file).is_ok() {
        let _ = std::fs::write(meta_path(&file), content_type);
    }
}

/// Serves one request: cache, or fetch-and-cache, or an error status the `<img>`
/// element turns into its ordinary fallback behaviour.
pub async fn respond(app: &tauri::AppHandle, request: tauri::http::Request<Vec<u8>>) -> tauri::http::Response<Vec<u8>> {
    let Some(url) = url_from_path(request.uri().path()) else {
        return plain_response(400, "not a cacheable image url");
    };
    if shiru_networking::guard::check_url(&url).is_err() {
        return plain_response(403, "refused destination");
    }
    let dir = match media_dir(app) {
        Some(dir) => dir,
        // no cache directory is no reason to show no art
        None => return fetch_only(&url).await,
    };
    // disk reads and writes run off the async workers: a grid page asks for hundreds
    // of covers at once, and blocking file IO on the executor stalled everything else
    // the runtime was doing, playback commands included
    loop {
        let looked_up = {
            let dir = dir.clone();
            let url = url.clone();
            tauri::async_runtime::spawn_blocking(move || lookup(&dir, &url)).await.ok().flatten()
        };
        if let Some((bytes, content_type)) = looked_up {
            return image_response(bytes, &content_type);
        }
        if recently_failed(&url) {
            return plain_response(502, "image fetch failed recently");
        }
        // one fetch per URL: the first asker owns it, everyone else waits for the file.
        // The claim is decided under the lock but awaited outside it, so the guard never
        // crosses an await
        let claimed = {
            let mut in_flight = pending().lock().unwrap();
            match in_flight.get(&url) {
                Some(receiver) => Err(receiver.clone()),
                None => {
                    let (sender, receiver) = tokio::sync::watch::channel(());
                    in_flight.insert(url.clone(), receiver);
                    Ok(sender)
                }
            }
        };
        let sender = match claimed {
            Err(mut receiver) => {
                let _ = receiver.changed().await; // resolves when the owner finishes, however it went
                continue; // the file is there now, or the failure is remembered
            }
            Ok(sender) => sender,
        };
        let outcome = fetch(&url).await;
        let response = match outcome {
            Ok((bytes, content_type)) => {
                let stored = (dir.clone(), url.clone(), bytes.clone(), content_type.clone());
                let _ = tauri::async_runtime::spawn_blocking(move || store(&stored.0, &stored.1, &stored.2, &stored.3)).await;
                image_response(bytes, &content_type)
            }
            Err(error) => {
                tracing::debug!(target: "media-cache", url = %url, error = %error, "image fetch failed");
                failures().lock().unwrap().insert(url.clone(), Instant::now());
                plain_response(502, "image fetch failed")
            }
        };
        pending().lock().unwrap().remove(&url);
        drop(sender); // waking the waiters only after the entry is gone and the file is down
        return response;
    }
}

/// The no-disk path: still answer, just without remembering.
async fn fetch_only(url: &str) -> tauri::http::Response<Vec<u8>> {
    match fetch(url).await {
        Ok((bytes, content_type)) => image_response(bytes, &content_type),
        Err(_) => plain_response(502, "image fetch failed"),
    }
}

async fn fetch(url: &str) -> Result<(Vec<u8>, String), String> {
    let response = crate::net::client()
        .get(url)
        .timeout(FETCH_TIMEOUT)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    // the redirect chain ends somewhere the caller never named; judge where it landed
    shiru_networking::guard::check_url(response.url().as_str()).map_err(|blocked| blocked.to_string())?;
    if !response.status().is_success() {
        return Err(format!("status {}", response.status()));
    }
    if response.content_length().is_some_and(|length| length > MAX_IMAGE_BYTES) {
        return Err("larger than the image cap".into());
    }
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();
    let bytes = response.bytes().await.map_err(|error| error.to_string())?;
    if bytes.len() as u64 > MAX_IMAGE_BYTES {
        return Err("larger than the image cap".into());
    }
    Ok((bytes.to_vec(), content_type))
}

fn image_response(bytes: Vec<u8>, content_type: &str) -> tauri::http::Response<Vec<u8>> {
    tauri::http::Response::builder()
        .status(200)
        .header("content-type", content_type)
        // the URL names the content, so within a session the webview may hold it in
        // memory and never come back here
        .header("cache-control", "public, max-age=31536000, immutable")
        .body(bytes)
        .expect("static header set")
}

fn plain_response(status: u16, message: &str) -> tauri::http::Response<Vec<u8>> {
    tauri::http::Response::builder()
        .status(status)
        .header("content-type", "text/plain")
        .body(message.as_bytes().to_vec())
        .expect("static header set")
}

/// One cache file, as the janitor sees it.
struct Entry {
    file: PathBuf,
    bytes: u64,
    touched: SystemTime,
}

/// Which files to delete so the cache fits the target: oldest-touched first, and
/// stray temp files from interrupted writes always. Pure, so the rule is testable
/// without a filesystem full of images.
fn trim_plan(entries: &mut Vec<Entry>, cap: u64, target: u64) -> Vec<PathBuf> {
    let mut doomed: Vec<PathBuf> = Vec::new();
    let mut total: u64 = 0;
    entries.retain(|entry| {
        if entry.file.extension().is_some_and(|extension| extension.to_string_lossy().starts_with("tmp")) {
            doomed.push(entry.file.clone());
            false
        } else {
            total += entry.bytes;
            true
        }
    });
    if total <= cap {
        return doomed;
    }
    entries.sort_by_key(|entry| entry.touched);
    for entry in entries.iter() {
        if total <= target {
            break;
        }
        total -= entry.bytes;
        doomed.push(entry.file.clone());
    }
    doomed
}

/// Applies the cap to the directory. `.ct` sidecars ride along with their image and
/// are removed with it.
fn trim(dir: &Path, cap: u64, target: u64) {
    let Ok(listing) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<Entry> = listing
        .flatten()
        .filter(|dir_entry| dir_entry.path().extension().is_none_or(|extension| extension != "ct"))
        .filter_map(|dir_entry| {
            let meta = dir_entry.metadata().ok()?;
            Some(Entry {
                file: dir_entry.path(),
                bytes: meta.len(),
                touched: meta.modified().ok()?,
            })
        })
        .collect();
    let doomed = trim_plan(&mut entries, cap, target);
    if !doomed.is_empty() {
        tracing::info!(target: "media-cache", evicting = doomed.len(), "art cache over its cap, dropping the least recently shown");
    }
    for file in doomed {
        let _ = std::fs::remove_file(meta_path(&file));
        let _ = std::fs::remove_file(file);
    }
}

/// The art cache as a subject, for the diagnostics surface.
#[derive(serde::Serialize)]
pub struct MediaCacheStats {
    /// Files held (images; .ct sidecars excluded).
    pub entries: usize,
    pub size_bytes: u64,
    pub cap_bytes: u64,
    /// Fetches in flight right now.
    pub in_flight: usize,
    /// URLs refused because they failed within the last FAILURE_TTL.
    pub recent_failures: usize,
}

/// Walks the cache directory and counts. Blocking IO — call it off the executor.
pub fn stats(dir: Option<&Path>) -> MediaCacheStats {
    let mut entries = 0;
    let mut size_bytes = 0;
    if let Some(listing) = dir.and_then(|dir| std::fs::read_dir(dir).ok()) {
        for entry in listing.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            size_bytes += meta.len();
            if entry.path().extension().is_none_or(|ext| ext != "ct") {
                entries += 1;
            }
        }
    }
    // expired failures are pruned as counted, so the number means what it says
    let mut failed = failures().lock().unwrap();
    let now = Instant::now();
    failed.retain(|_, at| now.duration_since(*at) < FAILURE_TTL);
    MediaCacheStats {
        entries,
        size_bytes,
        cap_bytes: CAP_BYTES,
        in_flight: pending().lock().unwrap().len(),
        recent_failures: failed.len(),
    }
}

/// Runs the cap once, off the boot path. Once per launch is enough: between
/// launches the cache can only grow by what one session's browsing pulls in.
pub fn spawn_janitor(app: &tauri::AppHandle) {
    if let Some(dir) = media_dir(app) {
        std::thread::spawn(move || trim(&dir, CAP_BYTES, TRIM_TARGET_BYTES));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("zeroshiru-media-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_request_path_recovers_the_original_url() {
        assert_eq!(
            url_from_path("/https%3A%2F%2Fs4.anilist.co%2Ffile%2Fanilistcdn%2Fmedia%2Fcover.jpg").as_deref(),
            Some("https://s4.anilist.co/file/anilistcdn/media/cover.jpg")
        );
        assert_eq!(url_from_path("/no_image_cover.jpg"), None, "local fallbacks never reach the network");
        assert_eq!(url_from_path("/file%3A%2F%2F%2Fetc%2Fpasswd"), None, "and neither does anything that is not http(s)");
        assert_eq!(url_from_path("/"), None);
    }

    #[test]
    fn the_same_url_is_the_same_file_and_different_urls_are_not() {
        let dir = PathBuf::from("/cache");
        assert_eq!(file_for(&dir, "https://a/x.jpg"), file_for(&dir, "https://a/x.jpg"));
        assert_ne!(file_for(&dir, "https://a/x.jpg"), file_for(&dir, "https://a/y.jpg"));
        let name = file_for(&dir, "https://a/x.jpg");
        assert_eq!(name.file_name().unwrap().len(), 64, "a name that cannot collide by accident or escape the directory");
    }

    #[test]
    fn stored_art_is_served_back_and_reading_it_keeps_it_alive() {
        let dir = scratch("roundtrip");
        store(&dir, "https://cdn/cover.png", b"png bytes", "image/png");
        let before = std::fs::metadata(file_for(&dir, "https://cdn/cover.png")).unwrap().modified().unwrap();
        std::thread::sleep(Duration::from_millis(20));
        let (bytes, content_type) = lookup(&dir, "https://cdn/cover.png").expect("stored art is found");
        assert_eq!(bytes, b"png bytes");
        assert_eq!(content_type, "image/png");
        let after = std::fs::metadata(file_for(&dir, "https://cdn/cover.png")).unwrap().modified().unwrap();
        assert!(after > before, "showing an image is what saves it from the janitor");
        assert!(lookup(&dir, "https://cdn/other.png").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn entry(name: &str, bytes: u64, age_secs: u64) -> Entry {
        Entry {
            file: PathBuf::from(name),
            bytes,
            touched: SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000 - age_secs),
        }
    }

    #[test]
    fn a_recent_failure_is_refused_and_an_old_one_is_forgiven() {
        let url = "https://cdn/negative-cache-test.png";
        assert!(!recently_failed(url), "nothing recorded yet");
        failures().lock().unwrap().insert(url.into(), Instant::now());
        assert!(recently_failed(url), "a fresh failure is not worth refetching");
        // a monotonic clock young enough (fresh boot) cannot be backdated; the rule
        // still holds, it just cannot be exercised on such a machine
        if let Some(expired) = Instant::now().checked_sub(FAILURE_TTL * 2) {
            failures().lock().unwrap().insert(url.into(), expired);
            assert!(!recently_failed(url), "an old failure earns another try");
            assert!(!failures().lock().unwrap().contains_key(url), "and its record is cleaned up");
        } else {
            failures().lock().unwrap().remove(url);
        }
    }

    #[test]
    fn a_rewrite_of_the_same_art_leaves_one_file_and_no_temp_droppings() {
        let dir = scratch("rewrite");
        store(&dir, "https://cdn/a.png", b"first", "image/png");
        store(&dir, "https://cdn/a.png", b"second", "image/png");
        let (bytes, _) = lookup(&dir, "https://cdn/a.png").unwrap();
        assert_eq!(bytes, b"second");
        let strays: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext.to_string_lossy().starts_with("tmp")))
            .collect();
        assert!(strays.is_empty(), "every temp name is renamed away or belongs to the janitor");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn under_the_cap_nothing_is_evicted() {
        let mut entries = vec![entry("a", 100, 10), entry("b", 100, 0)];
        assert!(trim_plan(&mut entries, 500, 450).is_empty());
    }

    #[test]
    fn over_the_cap_the_least_recently_shown_go_first_and_only_down_to_the_target() {
        let mut entries = vec![entry("newest", 100, 0), entry("oldest", 100, 100), entry("middle", 100, 50)];
        let doomed = trim_plan(&mut entries, 250, 150);
        assert_eq!(doomed, vec![PathBuf::from("oldest"), PathBuf::from("middle")]);
    }

    #[test]
    fn interrupted_writes_are_always_swept() {
        let mut entries = vec![entry("kept", 10, 0), entry("half-written.tmp3", 10, 0)];
        assert_eq!(trim_plan(&mut entries, u64::MAX, u64::MAX), vec![PathBuf::from("half-written.tmp3")]);
    }

    #[test]
    fn the_cap_is_generous_and_the_target_sits_below_it() {
        let cap = std::hint::black_box(CAP_BYTES);
        let target = std::hint::black_box(TRIM_TARGET_BYTES);
        assert!(cap >= 256 * 1024 * 1024, "a cache that cannot hold a real library is a refetch generator");
        assert!(target < cap, "trimming exactly to the cap re-triggers on the next image");
    }
}
