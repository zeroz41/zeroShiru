//! Loopback media gateway (migration report section 34): 127.0.0.1, ephemeral
//! port, random session token, media-only endpoints with range support. Purpose
//! built — this must never grow into a general local HTTP server.

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use axum::routing::get;
use axum::Router;
use librqbit::api::TorrentIdOrHash;
use librqbit::Session;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::io::{AsyncSeekExt, SeekFrom};

#[derive(Clone)]
struct GatewayState {
    session: Arc<Session>,
    token: String,
}

pub struct Gateway {
    addr: SocketAddr,
    token: String,
}

impl Gateway {
    pub async fn spawn(session: Arc<Session>) -> anyhow::Result<Gateway> {
        let token = random_token();
        let state = GatewayState { session, token: token.clone() };
        let router = Router::new()
            .route("/{token}/{hash}/{file}", get(stream_file))
            .with_state(state);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });
        Ok(Gateway { addr, token })
    }

    pub fn url_for(&self, info_hash: &str, file_index: u32) -> String {
        format!("http://{}/{}/{}/{}", self.addr, self.token, info_hash, file_index)
    }
}

fn random_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 24];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The one range shape media players send: `bytes=start-` or `bytes=start-end`.
/// Multi-range requests are answered whole — no player uses them.
fn parse_range(headers: &HeaderMap, total: u64) -> Option<(u64, u64)> {
    let value = headers.get(header::RANGE)?.to_str().ok()?;
    let spec = value.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (start, end) = spec.split_once('-')?;
    let start: u64 = start.parse().ok()?;
    let end: u64 = match end {
        "" => total.checked_sub(1)?,
        text => text.parse().ok()?,
    };
    (start <= end && end < total).then_some((start, end))
}

async fn stream_file(
    Path((token, hash, file)): Path<(String, String, usize)>,
    State(state): State<GatewayState>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    if token != state.token {
        return Err(StatusCode::NOT_FOUND); // no oracle: a bad token looks like a bad path
    }
    let id = TorrentIdOrHash::parse(&hash).map_err(|_| StatusCode::NOT_FOUND)?;
    let handle = state.session.get(id).ok_or(StatusCode::NOT_FOUND)?;
    let mut stream = handle.stream(file).await.map_err(|_| StatusCode::NOT_FOUND)?;
    let total = stream.len();

    let range = parse_range(&headers, total);
    let (start, end) = range.unwrap_or((0, total.saturating_sub(1)));
    if start > 0 {
        stream
            .seek(SeekFrom::Start(start))
            .await
            .map_err(|_| StatusCode::RANGE_NOT_SATISFIABLE)?;
    }
    let length = end - start + 1;
    let body = Body::from_stream(tokio_util::io::ReaderStream::new(
        tokio::io::AsyncReadExt::take(stream, length),
    ));

    let mut response = Response::builder()
        .status(if range.is_some() { StatusCode::PARTIAL_CONTENT } else { StatusCode::OK })
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, length)
        .header(header::CONTENT_TYPE, "application/octet-stream");
    if range.is_some() {
        response = response.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{total}"));
    }
    response.body(body).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(range: &str) -> HeaderMap {
        let mut map = HeaderMap::new();
        map.insert(header::RANGE, range.parse().unwrap());
        map
    }

    #[test]
    fn open_ended_and_bounded_ranges_parse() {
        assert_eq!(parse_range(&headers("bytes=0-"), 100), Some((0, 99)));
        assert_eq!(parse_range(&headers("bytes=10-19"), 100), Some((10, 19)));
        assert_eq!(parse_range(&headers("bytes=99-"), 100), Some((99, 99)));
    }

    #[test]
    fn junk_and_out_of_bounds_ranges_read_as_no_range() {
        assert_eq!(parse_range(&HeaderMap::new(), 100), None);
        assert_eq!(parse_range(&headers("bytes=100-"), 100), None);
        assert_eq!(parse_range(&headers("bytes=20-10"), 100), None);
        assert_eq!(parse_range(&headers("bytes=x-y"), 100), None);
        assert_eq!(parse_range(&headers("items=0-1"), 100), None);
    }

    #[test]
    fn tokens_are_long_and_unique() {
        let one = random_token();
        let two = random_token();
        assert_eq!(one.len(), 48);
        assert_ne!(one, two);
    }
}
