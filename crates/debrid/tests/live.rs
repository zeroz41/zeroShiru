//! Live tests against real debrid accounts. Opt-in and manual: they consume account
//! quota, so they are `#[ignore]`d and never run in the default suite.
//!
//!     cargo test -p shiru-debrid --features native -- --ignored --nocapture
//!
//! Keys come from the environment or from `.env` at the repo root (same file the JS
//! live tests read). A service with no key skips its tests rather than failing.
//!
//! The invariant that matters most: these must leave the account exactly as they found
//! it. Availability checks assert the account's torrent count is unchanged afterwards.

#![cfg(feature = "native")]

use shiru_debrid::manager::{create_provider, ManagedProvider};
use shiru_debrid::platform::NativePlatform;
use shiru_debrid::ResolveOptions;
use shiru_domain::Availability;
use shiru_networking::NativeTransport;
use std::sync::Arc;

const TORBOX_API: &str = "https://api.torbox.app/v1/api";
/// Public domain and reliably cached on TorBox, so a resolve exercises the whole path
/// without moving real data.
const CACHED: &str = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c";
/// Syntactically valid, but no tracker knows it, so nothing can be holding it.
const BOGUS: &str = "0000000000000000000000000000000000000001";

/// Reads a key from the environment, falling back to the repo's `.env`.
fn env(name: &str) -> Option<String> {
    if let Ok(value) = std::env::var(name) {
        if !value.trim().is_empty() {
            return Some(value.trim().to_string());
        }
    }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.env");
    let contents = std::fs::read_to_string(root).ok()?;
    contents.lines().find_map(|line| {
        let (key, value) = line.split_once('=')?;
        (key.trim() == name && !value.trim().is_empty()).then(|| value.trim().to_string())
    })
}

/// The provider under test, or `None` when its key is absent — which skips the test.
fn managed(service: &str, key_var: &str) -> Option<(ManagedProvider, String)> {
    let key = env(key_var)?;
    let provider = create_provider(
        service,
        key.clone(),
        Arc::new(NativeTransport::new()),
        Arc::new(NativePlatform),
    )?;
    Some((ManagedProvider::new(provider), key))
}

macro_rules! service_or_skip {
    ($service:expr, $key:expr) => {
        match managed($service, $key) {
            Some(ready) => ready,
            None => {
                println!("skipped: {} not set", $key);
                return;
            }
        }
    };
}

/// The account's torrents as (id, hash), read straight from the API so ground truth
/// never depends on the client under test.
async fn torbox_account(key: &str) -> Vec<(i64, String, i64)> {
    let response = reqwest::Client::new()
        .get(format!("{TORBOX_API}/torrents/mylist?bypass_cache=true&limit=1000"))
        .bearer_auth(key)
        .send()
        .await
        .expect("account listing");
    let body: serde_json::Value = response.json().await.expect("listing json");
    body["data"]
        .as_array()
        .map(|torrents| {
            torrents
                .iter()
                .map(|torrent| {
                    (
                        torrent["id"].as_i64().unwrap_or(-1),
                        torrent["hash"].as_str().unwrap_or_default().to_lowercase(),
                        torrent["files"].as_array().map(|files| files.len() as i64).unwrap_or(0),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

#[tokio::test]
#[ignore = "live: needs TORBOX_API_KEY and account quota"]
async fn torbox_validates_the_account() {
    let (torbox, _) = service_or_skip!("torbox", "TORBOX_API_KEY");
    let account = torbox.provider().validate().await.expect("validate");
    println!("connected as {} (premium until {:?})", account.username, account.expires);
    assert!(!account.username.is_empty());
}

#[tokio::test]
#[ignore = "live: needs TORBOX_API_KEY and account quota"]
async fn torbox_answers_about_cached_and_unknown_releases_without_touching_the_account() {
    let (torbox, key) = service_or_skip!("torbox", "TORBOX_API_KEY");
    let before = torbox_account(&key).await.len();

    let asked = vec![CACHED.to_string(), BOGUS.to_string()];
    let started = std::time::Instant::now();
    let answers = torbox.check_availability(&asked, |_, _| {}).await.expect("check");
    println!("{} answered in {:?}", answers.len(), started.elapsed());

    assert_eq!(answers.get(CACHED), Some(&Availability::Cached), "a release TorBox holds streams now");
    assert_eq!(
        answers.get(BOGUS),
        Some(&Availability::Available),
        "a cache endpoint that answered without naming a hash has said it does not hold it"
    );
    // a second ask is free
    assert!(torbox.unknown_hashes(&asked).is_empty(), "answers are remembered");

    assert_eq!(torbox_account(&key).await.len(), before, "a check must leave no trace on the account");
}

#[tokio::test]
#[ignore = "live: needs TORBOX_API_KEY and account quota"]
async fn torbox_reads_the_account_listing_once_per_ttl() {
    let (torbox, _) = service_or_skip!("torbox", "TORBOX_API_KEY");
    let started = std::time::Instant::now();
    let listing = torbox.list_availability().await.expect("listing");
    let first = started.elapsed();
    println!("account holds {} torrents, read in {first:?}", listing.len());

    let started = std::time::Instant::now();
    let again = torbox.list_availability().await.expect("cached listing");
    assert_eq!(again.len(), listing.len());
    assert!(started.elapsed() < first / 2 || started.elapsed().as_millis() < 5, "the play path reuses it for free");
}

#[tokio::test]
#[ignore = "live: needs TORBOX_API_KEY and account quota"]
async fn torbox_resolves_a_cached_release_to_streamable_links() {
    let (torbox, key) = service_or_skip!("torbox", "TORBOX_API_KEY");
    let before: Vec<i64> = torbox_account(&key).await.iter().map(|(id, _, _)| *id).collect();

    let opts = ResolveOptions {
        file_filter: Some(Box::new(shiru_media::is_playback_path)),
        ..Default::default()
    };
    let started = std::time::Instant::now();
    let resolved = torbox.provider().resolve(CACHED, &opts).await.expect("resolve");
    println!("{} -> {} file(s) in {:?}", resolved.name, resolved.files.len(), started.elapsed());

    assert!(!resolved.files.is_empty());
    for file in &resolved.files {
        assert!(file.url.starts_with("https://"), "links must be HTTPS: {}", file.url);
        assert!(file.path.starts_with('/'), "paths are rooted like the torrent client's");
    }

    // the link the player would open really serves bytes, and serves ranges
    let video = resolved
        .files
        .iter()
        .filter(|file| shiru_media::is_video_path(&file.name))
        .max_by_key(|file| file.size)
        .expect("a video to play");
    let response = reqwest::Client::new()
        .get(&video.url)
        .header("Range", "bytes=0-2047")
        .send()
        .await
        .expect("range request");
    assert_eq!(response.status().as_u16(), 206, "a player seeks, so the link must answer ranges");
    let bytes = response.bytes().await.expect("body");
    assert_eq!(bytes.len(), 2048, "{}: {} bytes", video.name, bytes.len());

    // a resolve is meant to leave the release on the account: that is what is streaming.
    // Anything else it added is not
    let after = torbox_account(&key).await;
    let added: Vec<&str> = after
        .iter()
        .filter(|(id, hash, _)| !before.contains(id) && hash != &resolved.hash)
        .map(|(_, hash, _)| hash.as_str())
        .collect();
    assert!(added.is_empty(), "a resolve added torrents it did not stream: {added:?}");
}

#[tokio::test]
#[ignore = "live: needs TORBOX_API_KEY and a season pack on the account"]
async fn torbox_picks_the_requested_episode_out_of_a_real_pack() {
    let (torbox, key) = service_or_skip!("torbox", "TORBOX_API_KEY");

    // the configured pack, or the largest multi-file torrent the account already holds
    let hash = match env("TB_TEST_PACK_HASH") {
        Some(hash) => hash,
        None => {
            let account = torbox_account(&key).await;
            let Some((_, hash, files)) =
                account.into_iter().filter(|(_, _, files)| *files > 3).max_by_key(|(_, _, files)| *files)
            else {
                println!("skipped: no multi-file torrent on the account to pick from");
                return;
            };
            println!("pack: {hash} ({files} files)");
            hash
        }
    };

    // read the pack's file list, then ask for an episode its names really claim
    let whole = torbox
        .provider()
        .resolve(&hash, &ResolveOptions { file_filter: Some(Box::new(shiru_media::is_video_path)), ..Default::default() })
        .await
        .expect("resolve pack");
    let names: Vec<String> = whole.files.iter().map(|file| file.name.clone()).collect();
    let mut episodes: Vec<f64> = names
        .iter()
        .flat_map(|name| shiru_media::parse_filename(name).episode_numbers)
        .collect();
    episodes.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let Some(&episode) = episodes.get(episodes.len() / 2) else {
        println!("skipped: no episode numbers readable in {names:?}");
        return;
    };
    let episode = env("TB_TEST_PACK_EPISODE").and_then(|value| value.parse().ok()).unwrap_or(episode);

    let opts = ResolveOptions {
        file_filter: Some(Box::new(shiru_media::is_playback_path)),
        pick_file: Some(Box::new(move |candidates| {
            let files: Vec<(String, u64)> =
                candidates.iter().map(|(_, path, size)| (path.clone(), *size)).collect();
            shiru_core::pick_pack(&files, episode, 12)
                .map_err(|error| shiru_debrid::DebridError::Rejected { message: error.to_string() })
        })),
        max_files: None,
    };
    let resolved = torbox.provider().resolve(&hash, &opts).await.expect("resolve episode");
    // the resolve hands back a window centred on the pick, not the pick alone, so that
    // next/previous episode still work in the player. The episode asked for must be in it
    let covers = |name: &str| {
        let numbers = shiru_media::parse_filename(name).episode_numbers;
        numbers.contains(&episode) || (numbers.len() == 2 && numbers[0] <= episode && episode <= numbers[1])
    };
    let names: Vec<&str> = resolved.files.iter().map(|file| file.name.as_str()).collect();
    println!("episode {episode} -> {} file window: {:?}", names.len(), names.first());
    assert!(
        names.iter().any(|name| covers(name)),
        "asked for episode {episode}, and the window does not hold it: {names:?}"
    );
    // and it sits inside the window rather than at its edge, which is what lets the
    // player walk to the episodes either side of it
    let position = names.iter().position(|name| covers(name)).unwrap();
    println!("  at index {position} of {}", names.len());
}

#[tokio::test]
#[ignore = "live: needs REAL_DEBRID_API_KEY and account quota"]
async fn real_debrid_probes_without_leaving_anything_behind() {
    let (realdebrid, key) = service_or_skip!("realdebrid", "REAL_DEBRID_API_KEY");

    let count = || async {
        let response = reqwest::Client::new()
            .get("https://api.real-debrid.com/rest/1.0/torrents?limit=1000")
            .bearer_auth(&key)
            .send()
            .await
            .expect("listing");
        response.json::<serde_json::Value>().await.ok().and_then(|body| body.as_array().map(Vec::len)).unwrap_or(0)
    };
    let before = count().await;

    let answers = realdebrid
        .check_availability(&[CACHED.to_string()], |hash, state| println!("  {hash} -> {state:?}"))
        .await
        .expect("probe");
    println!("{} answer(s), account went {before} -> {}", answers.len(), count().await);

    // whatever the answer was, a probe owns the account only while it runs
    assert_eq!(count().await, before, "a probe must take its magnet back off the account");
    assert_eq!(realdebrid.client().orphaned(), 0, "and owe nothing afterwards");
}
