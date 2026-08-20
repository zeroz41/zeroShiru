//! Connectivity, answered natively. Thin: the policy is `shiru_networking::reachability`.

use shiru_networking::{reachability, NativeTransport};
use std::sync::OnceLock;

/// One client for the life of the process. The probe runs on a timer, and a fresh
/// connection pool per probe would mean a fresh TLS handshake per probe — which is
/// exactly the cost a struggling link can least afford.
fn transport() -> &'static NativeTransport {
    static TRANSPORT: OnceLock<NativeTransport> = OnceLock::new();
    TRANSPORT.get_or_init(NativeTransport::new)
}

/// `online` | `portal` | `offline` | `unknown`. `unknown` is not an answer: the
/// renderer keeps the state it had rather than reporting an outage.
#[tauri::command]
pub async fn probe_network(timeout_ms: Option<u64>) -> &'static str {
    let result = reachability::probe(transport(), timeout_ms.unwrap_or(reachability::MIN_TIMEOUT_MS)).await;
    tracing::debug!(result = result.as_str(), "network probe");
    result.as_str()
}

/// One request the renderer asked the host to make on its behalf.
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FetchRequest {
    pub url: String,
    pub method: Option<String>,
    pub headers: Option<std::collections::HashMap<String, String>>,
    pub body: Option<String>,
    pub timeout_ms: Option<u64>,
}

/// What came back, shaped like the parts of a `Response` the callers actually read.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FetchResponse {
    /// Where the response came from, which is not the requested URL if it redirected.
    pub url: String,
    pub status: u16,
    pub ok: bool,
    pub headers: std::collections::HashMap<String, String>,
    pub body: String,
    /// The body was not text; `body` is then a lossy reading of it.
    pub binary: bool,
}

/// Bodies larger than this are refused rather than held in memory and copied over IPC.
const MAX_BODY: u64 = 8 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS: u64 = 20_000;
/// Generous on purpose: a slow source is still a source, and a search that would have
/// answered in 12 seconds is worth more than a timeout at 5.
const MAX_TIMEOUT_MS: u64 = 60_000;

/// Fetches a public http(s) URL natively, for page content that a browser would not let read
/// the answer: an extension scraping a site that sends no CORS headers, which is most of them.
///
/// Native HTTP has no same-origin rules, so this command is the only thing standing between
/// page content and the local network — every destination, including each redirect hop, is
/// checked against `shiru_networking::guard`.
#[tauri::command]
pub async fn http_request(request: FetchRequest) -> Result<FetchResponse, String> {
    use shiru_networking::guard;

    guard::check_url(&request.url).map_err(|blocked| blocked.to_string())?;
    let method = method_for(request.method.as_deref())?;
    let timeout = timeout_for(request.timeout_ms);

    let mut builder = client().request(method, &request.url).timeout(timeout);
    for (name, value) in request.headers.unwrap_or_default() {
        if !header_allowed(&name) {
            continue;
        }
        builder = builder.header(name, value);
    }
    if let Some(body) = request.body {
        builder = builder.body(body);
    }

    let response = builder.send().await.map_err(|error| {
        if error.is_timeout() {
            format!("timed out after {}ms", timeout.as_millis())
        } else {
            error.to_string()
        }
    })?;

    // a redirect chain ends somewhere the caller never named, so judge where it actually landed
    let final_url = response.url().to_string();
    guard::check_url(&final_url).map_err(|blocked| format!("redirected somewhere unreachable: {blocked}"))?;
    if response.content_length().is_some_and(|length| length > MAX_BODY) {
        return Err(format!("response is larger than the {}MB limit", MAX_BODY / 1024 / 1024));
    }

    let status = response.status();
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| Some((name.to_string(), value.to_str().ok()?.to_string())))
        .collect();
    let bytes = response.bytes().await.map_err(|error| error.to_string())?;
    if bytes.len() as u64 > MAX_BODY {
        return Err(format!("response is larger than the {}MB limit", MAX_BODY / 1024 / 1024));
    }
    let (body, binary) = match String::from_utf8(bytes.to_vec()) {
        Ok(text) => (text, false),
        Err(error) => (String::from_utf8_lossy(error.as_bytes()).into_owned(), true),
    };

    tracing::debug!(url = %final_url, status = status.as_u16(), bytes = bytes.len(), "page request");
    Ok(FetchResponse {
        url: final_url,
        status: status.as_u16(),
        ok: status.is_success(),
        headers,
        body,
        binary,
    })
}

/// The client for page requests. Redirects are followed, but every hop is checked: a public URL
/// that redirects to `127.0.0.1` is the ordinary way this kind of command gets abused.
fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                match redirect_decision(attempt.url().as_str(), attempt.previous().len()) {
                    Redirect::Follow => attempt.follow(),
                    Redirect::TooMany => attempt.stop(),
                    Redirect::Refused(blocked) => attempt.error(blocked),
                }
            }))
            .build()
            .expect("http client builds")
    })
}

/// The methods a page may ask the host to use on its behalf.
fn method_for(method: Option<&str>) -> Result<reqwest::Method, String> {
    match method.map(str::to_ascii_uppercase).as_deref() {
        None | Some("") | Some("GET") => Ok(reqwest::Method::GET),
        Some("POST") => Ok(reqwest::Method::POST),
        Some("PUT") => Ok(reqwest::Method::PUT),
        Some("DELETE") => Ok(reqwest::Method::DELETE),
        Some("PATCH") => Ok(reqwest::Method::PATCH),
        Some("HEAD") => Ok(reqwest::Method::HEAD),
        Some(other) => Err(format!("{other} requests are not made on behalf of the page")),
    }
}

/// A caller's budget, floored at nothing and capped so a page cannot pin a connection open.
fn timeout_for(timeout_ms: Option<u64>) -> std::time::Duration {
    std::time::Duration::from_millis(timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS).min(MAX_TIMEOUT_MS))
}

/// Headers the transport owns. A page setting these breaks the connection rather than the rules.
fn header_allowed(name: &str) -> bool {
    !matches!(
        name.to_ascii_lowercase().as_str(),
        "host" | "content-length" | "connection" | "transfer-encoding" | "upgrade"
    )
}

/// What to do with one redirect hop.
#[derive(Debug, PartialEq, Eq)]
enum Redirect {
    Follow,
    TooMany,
    Refused(shiru_networking::guard::Blocked),
}

/// A redirect is a destination the caller never named, so each hop is judged like the first.
fn redirect_decision(url: &str, hops: usize) -> Redirect {
    if hops >= 8 {
        return Redirect::TooMany;
    }
    match shiru_networking::guard::check_url(url) {
        Ok(()) => Redirect::Follow,
        Err(blocked) => Redirect::Refused(blocked),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiru_networking::guard::Blocked;

    #[test]
    fn the_methods_a_source_needs_are_passed_through() {
        assert_eq!(method_for(None).unwrap(), reqwest::Method::GET);
        assert_eq!(method_for(Some("get")).unwrap(), reqwest::Method::GET);
        assert_eq!(method_for(Some("PoSt")).unwrap(), reqwest::Method::POST);
        assert_eq!(method_for(Some("HEAD")).unwrap(), reqwest::Method::HEAD);
    }

    #[test]
    fn anything_else_is_refused_rather_than_guessed_at() {
        assert!(method_for(Some("CONNECT")).is_err(), "not a request a content source makes");
        assert!(method_for(Some("TRACE")).is_err());
    }

    #[test]
    fn a_page_cannot_hold_a_connection_open_forever() {
        assert_eq!(timeout_for(Some(u64::MAX)).as_millis(), MAX_TIMEOUT_MS as u128);
        assert_eq!(timeout_for(None).as_millis(), DEFAULT_TIMEOUT_MS as u128);
    }

    #[test]
    fn a_patient_caller_keeps_its_budget() {
        // a slow source is still a source; nothing here shortens what was asked for
        assert_eq!(timeout_for(Some(45_000)).as_millis(), 45_000);
    }

    #[test]
    fn headers_the_transport_owns_are_dropped() {
        for name in ["Host", "content-length", "Connection", "Transfer-Encoding", "upgrade"] {
            assert!(!header_allowed(name), "{name} belongs to the connection");
        }
    }

    #[test]
    fn headers_a_source_needs_are_kept() {
        for name in ["User-Agent", "Referer", "Cookie", "Accept", "Authorization", "X-Api-Key"] {
            assert!(header_allowed(name), "{name} is the caller's business");
        }
    }

    #[test]
    fn a_redirect_into_the_local_network_is_refused() {
        // the ordinary way a command like this gets abused: a public URL that bounces inward
        assert_eq!(redirect_decision("http://127.0.0.1:9000/", 1), Redirect::Refused(Blocked::Private));
        assert_eq!(redirect_decision("http://169.254.169.254/", 1), Redirect::Refused(Blocked::Private));
        assert_eq!(redirect_decision("file:///etc/passwd", 1), Redirect::Refused(Blocked::Scheme));
    }

    #[test]
    fn an_ordinary_redirect_is_followed() {
        assert_eq!(redirect_decision("https://nyaa.si/view/1", 1), Redirect::Follow);
    }

    #[test]
    fn a_redirect_loop_ends() {
        assert_eq!(redirect_decision("https://example.com/", 8), Redirect::TooMany);
    }
}
