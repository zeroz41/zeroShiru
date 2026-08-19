//! Debrid IPC adapters. Provider instances are cached per (service, key) so
//! availability memory survives across calls, mirroring the JS service lifecycle.

use serde::Serialize;
use shiru_debrid::manager::{create_provider, ManagedProvider};
use shiru_debrid::platform::NativePlatform;
use shiru_debrid::{DebridError, ResolveOptions};
use shiru_domain::{Availability, DebridResolved};
use shiru_networking::NativeTransport;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct DebridState {
    active: Mutex<Option<(String, String, Arc<ManagedProvider>)>>,
}

impl DebridState {
    fn managed(&self, service: &str, api_key: &str) -> Result<Arc<ManagedProvider>, String> {
        let mut active = self.active.lock().unwrap();
        if let Some((known_service, known_key, managed)) = active.as_ref() {
            if known_service == service && known_key == api_key {
                return Ok(managed.clone());
            }
        }
        let provider = create_provider(
            service,
            api_key.to_string(),
            Arc::new(NativeTransport::new()),
            Arc::new(NativePlatform),
        )
        .ok_or_else(|| format!("unknown debrid service: {service}"))?;
        let managed = Arc::new(ManagedProvider::new(provider));
        *active = Some((service.to_string(), api_key.to_string(), managed.clone()));
        Ok(managed)
    }
}

/// Errors cross IPC as their user-facing message plus a kind the frontend can
/// branch on, mirroring the JS error names.
#[derive(Serialize)]
pub struct DebridFailure {
    pub kind: &'static str,
    pub message: String,
}

fn failure(error: DebridError) -> DebridFailure {
    let kind = match &error {
        DebridError::Auth { .. } => "auth",
        DebridError::Network { .. } => "network",
        DebridError::Timeout { .. } => "timeout",
        DebridError::NotCached { .. } => "not-cached",
        DebridError::Unavailable { .. } => "unavailable",
        DebridError::Service { .. } => "service",
    };
    DebridFailure { kind, message: error.to_string() }
}

#[derive(Serialize)]
pub struct AccountReply {
    pub username: String,
    pub expires: Option<String>,
}

#[tauri::command]
pub async fn debrid_validate(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
) -> Result<AccountReply, DebridFailure> {
    let managed = state.managed(&service, &api_key).map_err(|message| DebridFailure { kind: "service", message })?;
    let info = managed.provider().validate().await.map_err(failure)?;
    Ok(AccountReply { username: info.username, expires: info.expires })
}

#[tauri::command]
pub async fn debrid_check_availability(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    hashes: Vec<String>,
) -> Result<HashMap<String, Availability>, DebridFailure> {
    let managed = state.managed(&service, &api_key).map_err(|message| DebridFailure { kind: "service", message })?;
    managed.check_availability(&hashes, |_, _| {}).await.map_err(failure)
}

#[tauri::command]
pub async fn debrid_resolve(
    state: tauri::State<'_, DebridState>,
    service: String,
    api_key: String,
    magnet: String,
) -> Result<DebridResolved, DebridFailure> {
    let managed = state.managed(&service, &api_key).map_err(|message| DebridFailure { kind: "service", message })?;
    let opts = ResolveOptions {
        file_filter: Some(Box::new(|name| {
            shiru_media::is_video_path(name) || shiru_media::is_subtitle_path(name)
        })),
        ..Default::default()
    };
    managed.provider().resolve(&magnet, &opts).await.map_err(failure)
}
