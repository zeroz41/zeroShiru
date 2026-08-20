//! HTTP is abstract: providers describe requests, hosts execute them. Native hosts
//! use the reqwest transport; TV hosts hand in a fetch-backed transport, because a
//! provider API callable from native Rust is not automatically callable from a TV
//! web app (CORS, config.xml access lists).

use async_trait::async_trait;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Put,
    Delete,
}

impl Method {
    pub fn as_str(&self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Put => "PUT",
            Method::Delete => "DELETE",
        }
    }
}

#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: Method,
    pub url: String,
    pub headers: HashMap<String, String>,
    pub body: Option<Body>,
    /// Hard ceiling on one round trip, in milliseconds.
    pub timeout_ms: u64,
}

#[derive(Debug, Clone)]
pub enum Body {
    /// Pre-encoded bytes with their content type (form/json bodies).
    Bytes { content_type: String, bytes: Vec<u8> },
    /// Multipart form fields; the transport encodes them and sets the boundary.
    Multipart(Vec<(String, String)>),
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    /// The service could not be reached at all, usually because the client is offline.
    #[error("network request failed: {0}")]
    Network(String),
    /// The transport kept us waiting past the budget.
    #[error("request timed out after {0}ms")]
    Timeout(u64),
}

#[async_trait]
pub trait HttpTransport: Send + Sync {
    async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, TransportError>;
}

pub mod guard;
pub mod reachability;

#[cfg(feature = "native")]
mod native;
#[cfg(feature = "native")]
pub use native::NativeTransport;
