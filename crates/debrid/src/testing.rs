//! Test doubles shared by provider tests: a scripted HTTP transport and a manual clock.
//! Compiled only for tests (see lib.rs) so shipping builds never carry it.

use crate::platform::Platform;
use async_trait::async_trait;
use shiru_networking::{HttpRequest, HttpResponse, HttpTransport, TransportError};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// One scripted exchange: a URL substring to match and what to answer with.
pub struct Route {
    pub matches: &'static str,
    pub status: u16,
    pub body: String,
    pub headers: Vec<(&'static str, &'static str)>,
}

impl Route {
    pub fn json(matches: &'static str, status: u16, body: &str) -> Route {
        Route { matches, status, body: body.to_string(), headers: vec![] }
    }
}

/// Answers requests from a script, recording everything it was asked.
#[derive(Default)]
pub struct MockTransport {
    routes: Mutex<Vec<Route>>,
    pub requests: Mutex<Vec<HttpRequest>>,
}

impl MockTransport {
    pub fn new(routes: Vec<Route>) -> Self {
        MockTransport { routes: Mutex::new(routes), requests: Mutex::new(vec![]) }
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
        let routes = self.routes.lock().unwrap();
        let route = routes
            .iter()
            .find(|route| url.contains(route.matches))
            .ok_or_else(|| TransportError::Network(format!("no scripted answer for {url}")))?;
        let headers: HashMap<String, String> = route
            .headers
            .iter()
            .map(|(name, value)| (name.to_string(), value.to_string()))
            .collect();
        Ok(HttpResponse { status: route.status, headers, body: route.body.clone().into_bytes() })
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
