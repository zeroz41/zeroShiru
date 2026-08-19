//! Manual smoke test: adds a well-seeded legal torrent, waits for metadata, and
//! reads the first bytes through the loopback gateway with a Range request.
//! Run: cargo run -p shiru-torrent --features native --example smoke [torrent-url]

use shiru_torrent::{RqbitEngine, TorrentEngine};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = std::env::args().nth(1).unwrap_or_else(|| {
        "https://archlinux.org/releng/releases/2026.08.01/torrent/".to_string()
    });
    let dir = std::env::temp_dir().join("shiru-torrent-smoke");
    let engine = RqbitEngine::new(dir).await?;
    println!("adding {url}");
    let hash = engine.add(&url).await?;
    println!("added {hash}, waiting for metadata...");
    let metadata = engine.metadata(&hash).await?;
    println!("name: {} files: {}", metadata.name, metadata.files.len());
    for file in metadata.files.iter().take(5) {
        println!("  [{}] {} ({} bytes)", file.index, file.path, file.size);
    }
    let source = engine.playback_source(&hash, 0).await?;
    let shiru_domain::PlaybackSource::Torrent { url: stream_url, .. } = &source else {
        panic!("unexpected source: {source:?}")
    };
    println!("gateway: {stream_url}");

    let started = std::time::Instant::now();
    let response = reqwest::Client::new()
        .get(stream_url)
        .header("Range", "bytes=0-65535")
        .timeout(std::time::Duration::from_secs(120))
        .send()
        .await?;
    println!("status: {} content-range: {:?}", response.status(), response.headers().get("content-range"));
    let bytes = response.bytes().await?;
    println!("read {} bytes in {:?}", bytes.len(), started.elapsed());
    let status = engine.status(&hash).await?;
    println!("status: {status:?}");
    engine.remove(&hash).await?;
    assert_eq!(bytes.len(), 65536);
    println!("SMOKE OK");
    Ok(())
}
