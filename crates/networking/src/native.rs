//! reqwest-backed transport for desktop and Android.

use crate::{Body, HttpRequest, HttpResponse, HttpTransport, Method, TransportError};
use async_trait::async_trait;
use std::time::Duration;

pub struct NativeTransport {
    client: reqwest::Client,
}

impl NativeTransport {
    pub fn new() -> Self {
        NativeTransport { client: reqwest::Client::new() }
    }
}

impl Default for NativeTransport {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl HttpTransport for NativeTransport {
    async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, TransportError> {
        let method = match request.method {
            Method::Get => reqwest::Method::GET,
            Method::Post => reqwest::Method::POST,
            Method::Put => reqwest::Method::PUT,
            Method::Delete => reqwest::Method::DELETE,
        };
        let mut builder = self
            .client
            .request(method, &request.url)
            .timeout(Duration::from_millis(request.timeout_ms));
        for (name, value) in &request.headers {
            builder = builder.header(name, value);
        }
        match request.body {
            Some(Body::Bytes { content_type, bytes }) => {
                builder = builder.header("Content-Type", content_type).body(bytes);
            }
            Some(Body::Multipart(fields)) => {
                let mut form = reqwest::multipart::Form::new();
                for (key, value) in fields {
                    form = form.text(key, value);
                }
                builder = builder.multipart(form);
            }
            None => {}
        }
        let timeout_ms = request.timeout_ms;
        let response = builder.send().await.map_err(|error| {
            if error.is_timeout() {
                TransportError::Timeout(timeout_ms)
            } else {
                TransportError::Network(error.to_string())
            }
        })?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| Some((name.to_string(), value.to_str().ok()?.to_string())))
            .collect();
        let body = response
            .bytes()
            .await
            .map_err(|error| TransportError::Network(error.to_string()))?
            .to_vec();
        Ok(HttpResponse { status, headers, body })
    }
}
