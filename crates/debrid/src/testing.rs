//! Test doubles shared by provider tests: a scripted HTTP transport and a manual clock.
//! Compiled only for tests (see lib.rs) so shipping builds never carry it.

use crate::platform::Platform;
use async_trait::async_trait;
use shiru_networking::{HttpRequest, HttpResponse, HttpTransport, TransportError};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// What a matched route does: answer, or fail the way a bad connection does.
pub enum Outcome {
    Answer { status: u16, body: String, headers: Vec<(&'static str, &'static str)> },
    /// The link is down, or the app considers itself offline.
    Network(String),
    /// The request outlived its budget. Says nothing about the release.
    Timeout(u64),
}

/// One scripted exchange: a URL substring to match and what to answer with.
pub struct Route {
    pub matches: &'static str,
    pub outcome: Outcome,
}

impl Route {
    pub fn json(matches: &'static str, status: u16, body: &str) -> Route {
        Route {
            matches,
            outcome: Outcome::Answer { status, body: body.to_string(), headers: vec![] },
        }
    }

    /// A route the link never delivers.
    pub fn offline(matches: &'static str) -> Route {
        Route { matches, outcome: Outcome::Network("Network request failed".into()) }
    }

    /// A route that outlives its budget.
    pub fn timeout(matches: &'static str, after_ms: u64) -> Route {
        Route { matches, outcome: Outcome::Timeout(after_ms) }
    }

    pub fn with_headers(mut self, headers: Vec<(&'static str, &'static str)>) -> Route {
        if let Outcome::Answer { headers: existing, .. } = &mut self.outcome {
            *existing = headers;
        }
        self
    }
}

/// Answers requests from a script, recording everything it was asked. Optionally
/// simulates a link: every round trip costs `latency_ms` on the clock it shares with
/// the provider, which is what the poll budgets stretch against.
#[derive(Default)]
pub struct MockTransport {
    routes: Mutex<Vec<Route>>,
    pub requests: Mutex<Vec<HttpRequest>>,
    link: Mutex<Option<(std::sync::Arc<ManualClock>, u64)>>,
}

impl MockTransport {
    pub fn new(routes: Vec<Route>) -> Self {
        MockTransport { routes: Mutex::new(routes), requests: Mutex::new(vec![]), link: Mutex::new(None) }
    }

    /// Makes every request take `latency_ms` of clock time, the way a slow link does.
    pub fn on_link(self, clock: std::sync::Arc<ManualClock>, latency_ms: u64) -> Self {
        *self.link.lock().unwrap() = Some((clock, latency_ms));
        self
    }

    /// Replaces the script, for a link that comes back up mid-test.
    pub fn rescript(&self, routes: Vec<Route>) {
        *self.routes.lock().unwrap() = routes;
    }

    /// URLs of every request made, in order.
    pub fn urls(&self) -> Vec<String> {
        self.requests.lock().unwrap().iter().map(|request| request.url.clone()).collect()
    }
}

#[async_trait]
impl HttpTransport for MockTransport {
    async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        let url = request.url.clone();
        self.requests.lock().unwrap().push(request);
        if let Some((clock, latency)) = self.link.lock().unwrap().as_ref() {
            clock.advance(*latency);
        }
        let routes = self.routes.lock().unwrap();
        let route = routes
            .iter()
            .find(|route| url.contains(route.matches))
            .ok_or_else(|| TransportError::Network(format!("no scripted answer for {url}")))?;
        match &route.outcome {
            Outcome::Answer { status, body, headers } => {
                let headers: HashMap<String, String> = headers
                    .iter()
                    .map(|(name, value)| (name.to_string(), value.to_string()))
                    .collect();
                Ok(HttpResponse { status: *status, headers, body: body.clone().into_bytes() })
            }
            Outcome::Network(message) => Err(TransportError::Network(message.clone())),
            Outcome::Timeout(ms) => Err(TransportError::Timeout(*ms)),
        }
    }
}

/// A clock tests advance by hand; sleeping advances it instead of waiting.
pub struct ManualClock {
    now: AtomicU64,
}

impl ManualClock {
    pub fn new() -> Self {
        ManualClock { now: AtomicU64::new(1_000_000) }
    }

    pub fn advance(&self, ms: u64) {
        self.now.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Default for ManualClock {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Platform for ManualClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }

    async fn sleep(&self, ms: u64) {
        self.advance(ms);
    }
}
