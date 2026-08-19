//! Time and sleeping are host services: native hosts use tokio, WASM hosts hand in
//! wrappers over Date.now/setTimeout. Nothing in this crate calls a clock directly,
//! which is what lets the same provider logic run on the TVs.

use async_trait::async_trait;

#[async_trait]
pub trait Platform: Send + Sync {
    /// Milliseconds from an arbitrary but monotonic-enough epoch.
    fn now_ms(&self) -> u64;
    async fn sleep(&self, ms: u64);
}

#[cfg(feature = "native")]
pub struct NativePlatform;

#[cfg(feature = "native")]
#[async_trait]
impl Platform for NativePlatform {
    fn now_ms(&self) -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
    }

    async fn sleep(&self, ms: u64) {
        tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
    }
}
