//! Is there a working connection? Asked over the same `HttpTransport` everything
//! else uses, so a native host answers it with a real HTTP status and a TV host can
//! answer it with whatever its web transport manages.
//!
//! Why this is not left to the frontend: a webview may only ask a connectivity
//! endpoint in `no-cors` mode, and the answer comes back opaque — status 0, body
//! unreadable. "The request completed" is then the *only* thing it can learn, which
//! cannot tell a working connection from a captive portal that answered for it.
//! Native HTTP has no such limit: the probe endpoints promise `204 No Content`, so
//! anything else answering is something else answering.
//!
//! The other rule here is that a slow link is not an outage. A timeout is not a
//! measurement — it is the absence of one — so it reports [`Reachability::Unknown`]
//! and the caller keeps whatever it already believed. Only a connection that fails
//! outright, at every endpoint, is read as offline.

use crate::{HttpRequest, HttpResponse, HttpTransport, Method, TransportError};
use std::collections::HashMap;

/// What a probe found out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reachability {
    /// An endpoint answered exactly as promised. There is a connection.
    Online,
    /// Something answered, but not what was asked for: a captive portal, a
    /// filtering proxy, a hotel splash page. Reachable, but not the internet.
    Portal,
    /// Every endpoint failed to connect at all. This is a real answer.
    Offline,
    /// Nothing answered in time, or the endpoints themselves are broken. NOT an
    /// answer: callers keep the state they had rather than reporting an outage.
    Unknown,
}

impl Reachability {
    /// The wire name, which is what crosses the host bridge.
    pub fn as_str(self) -> &'static str {
        match self {
            Reachability::Online => "online",
            Reachability::Portal => "portal",
            Reachability::Offline => "offline",
            Reachability::Unknown => "unknown",
        }
    }
}

/// Endpoints that promise `204 No Content` and an empty body. More than one so a
/// single vendor having a bad day is never mistaken for the user being offline.
pub const ENDPOINTS: &[&str] = &[
    "https://cp.cloudflare.com/generate_204",
    "https://connectivitycheck.gstatic.com/generate_204",
];

/// The floor under any caller's timeout. A probe is a background question, and
/// answering it impatiently on a slow link is how an app decides a working
/// connection is an outage.
pub const MIN_TIMEOUT_MS: u64 = 2_000;

/// Asks [`ENDPOINTS`] in order, stopping at the first that answers properly.
pub async fn probe(transport: &dyn HttpTransport, timeout_ms: u64) -> Reachability {
    probe_endpoints(transport, ENDPOINTS, timeout_ms).await
}

/// [`probe`] against a given list, so tests need no network and hosts can override.
pub async fn probe_endpoints(
    transport: &dyn HttpTransport,
    endpoints: &[&str],
    timeout_ms: u64,
) -> Reachability {
    let timeout_ms = timeout_ms.max(MIN_TIMEOUT_MS);
    let mut portal = false;
    // only a connection that fails outright says "offline", and only if they all do
    let mut all_failed_to_connect = true;
    let mut asked = false;

    for endpoint in endpoints {
        asked = true;
        match transport.execute(request_for(endpoint, timeout_ms)).await {
            Ok(response) => {
                all_failed_to_connect = false;
                match read(&response) {
                    Reachability::Online => return Reachability::Online,
                    Reachability::Portal => portal = true,
                    // the endpoint itself is broken; that says nothing about us
                    _ => {}
                }
            }
            Err(TransportError::Network(_)) => {}
            Err(TransportError::Timeout(_)) => all_failed_to_connect = false,
        }
    }

    if portal {
        Reachability::Portal
    } else if asked && all_failed_to_connect {
        Reachability::Offline
    } else {
        Reachability::Unknown
    }
}

/// What one answer means. The endpoints promise `204` and nothing else, so a body
/// or any other success status is somebody else answering on their behalf.
fn read(response: &HttpResponse) -> Reachability {
    match response.status {
        204 if response.body.is_empty() => Reachability::Online,
        200..=399 => Reachability::Portal,
        // 4xx/5xx is the endpoint being unwell, which is not news about the link
        _ => Reachability::Unknown,
    }
}

fn request_for(endpoint: &str, timeout_ms: u64) -> HttpRequest {
    let mut headers = HashMap::new();
    // a cached 204 would answer for a connection that is no longer there
    headers.insert("Cache-Control".to_string(), "no-store, no-cache".to_string());
    headers.insert("Pragma".to_string(), "no-cache".to_string());
    HttpRequest {
        method: Method::Get,
        url: endpoint.to_string(),
        headers,
        body: None,
        timeout_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::Mutex;

    /// One scripted answer per endpoint, in the order they are asked.
    struct Script {
        answers: Mutex<Vec<Result<HttpResponse, TransportError>>>,
        asked: Mutex<Vec<HttpRequest>>,
    }

    impl Script {
        fn new(answers: Vec<Result<HttpResponse, TransportError>>) -> Self {
            Script { answers: Mutex::new(answers), asked: Mutex::new(Vec::new()) }
        }
    }

    #[async_trait]
    impl HttpTransport for Script {
        async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
            self.asked.lock().unwrap().push(request);
            let mut answers = self.answers.lock().unwrap();
            if answers.is_empty() {
                return Err(TransportError::Network("script ran out".into()));
            }
            answers.remove(0)
        }
    }

    fn answer(status: u16, body: &str) -> Result<HttpResponse, TransportError> {
        Ok(HttpResponse {
            status,
            headers: HashMap::new(),
            body: body.as_bytes().to_vec(),
        })
    }

    const TWO: &[&str] = &["https://first.test/generate_204", "https://second.test/generate_204"];

    async fn probed(answers: Vec<Result<HttpResponse, TransportError>>) -> Reachability {
        probe_endpoints(&Script::new(answers), TWO, MIN_TIMEOUT_MS).await
    }

    #[tokio::test]
    async fn an_empty_204_is_a_connection() {
        assert_eq!(probed(vec![answer(204, "")]).await, Reachability::Online);
    }

    #[tokio::test]
    async fn the_first_good_answer_ends_the_probe() {
        let script = Script::new(vec![answer(204, "")]);
        assert_eq!(probe_endpoints(&script, TWO, MIN_TIMEOUT_MS).await, Reachability::Online);
        assert_eq!(script.asked.lock().unwrap().len(), 1, "the second endpoint is not worth asking");
    }

    #[tokio::test]
    async fn a_second_endpoint_covers_the_first_one_being_down() {
        let answers = vec![answer(500, "we are unwell"), answer(204, "")];
        assert_eq!(probed(answers).await, Reachability::Online);
    }

    #[tokio::test]
    async fn something_answering_instead_of_the_endpoint_is_a_portal() {
        // the shape of a hotel splash page: a 200 with a login form
        assert_eq!(probed(vec![answer(200, "<html>sign in</html>")]).await, Reachability::Portal);
        // and of a redirect to one
        assert_eq!(probed(vec![answer(302, "")]).await, Reachability::Portal);
        // a 204 that carries a body is not the 204 that was promised
        assert_eq!(probed(vec![answer(204, "injected")]).await, Reachability::Portal);
    }

    #[tokio::test]
    async fn a_portal_outranks_a_later_dead_endpoint() {
        let answers = vec![answer(200, "sign in"), Err(TransportError::Network("dns".into()))];
        assert_eq!(probed(answers).await, Reachability::Portal, "something answered; we are not offline");
    }

    #[tokio::test]
    async fn only_failing_to_connect_everywhere_is_offline() {
        let answers = vec![
            Err(TransportError::Network("dns failure".into())),
            Err(TransportError::Network("connection refused".into())),
        ];
        assert_eq!(probed(answers).await, Reachability::Offline);
    }

    #[tokio::test]
    async fn a_slow_link_is_never_reported_as_an_outage() {
        let answers = vec![Err(TransportError::Timeout(2_000)), Err(TransportError::Timeout(2_000))];
        assert_eq!(probed(answers).await, Reachability::Unknown, "a timeout is not a measurement");
    }

    #[tokio::test]
    async fn one_timeout_among_dead_endpoints_still_withholds_the_verdict() {
        let answers = vec![Err(TransportError::Network("dns".into())), Err(TransportError::Timeout(2_000))];
        assert_eq!(probed(answers).await, Reachability::Unknown, "the slow one was never answered");
    }

    #[tokio::test]
    async fn endpoints_that_are_merely_broken_prove_nothing() {
        assert_eq!(probed(vec![answer(500, ""), answer(503, "")]).await, Reachability::Unknown);
    }

    #[tokio::test]
    async fn an_impatient_caller_is_given_the_floor() {
        let script = Script::new(vec![answer(204, "")]);
        probe_endpoints(&script, TWO, 300).await;
        let asked = script.asked.lock().unwrap();
        assert_eq!(asked[0].timeout_ms, MIN_TIMEOUT_MS, "300ms is how a slow link becomes an outage");
    }

    #[tokio::test]
    async fn a_generous_caller_keeps_its_budget() {
        let script = Script::new(vec![answer(204, "")]);
        probe_endpoints(&script, TWO, 30_000).await;
        assert_eq!(script.asked.lock().unwrap()[0].timeout_ms, 30_000);
    }

    #[tokio::test]
    async fn the_probe_is_never_served_from_a_cache() {
        let script = Script::new(vec![answer(204, "")]);
        probe_endpoints(&script, TWO, MIN_TIMEOUT_MS).await;
        let asked = script.asked.lock().unwrap();
        assert_eq!(asked[0].headers.get("Cache-Control").map(String::as_str), Some("no-store, no-cache"));
    }

    #[test]
    fn the_wire_names_are_what_the_bridge_promises() {
        assert_eq!(Reachability::Online.as_str(), "online");
        assert_eq!(Reachability::Portal.as_str(), "portal");
        assert_eq!(Reachability::Offline.as_str(), "offline");
        assert_eq!(Reachability::Unknown.as_str(), "unknown");
    }
}
