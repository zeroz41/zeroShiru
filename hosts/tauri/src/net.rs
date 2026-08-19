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
