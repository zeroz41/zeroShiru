//! In-app updates for directly distributed desktop builds.
//!
//! The frontend drives this the way it always has: it asks for a check on a timer,
//! and expects `available` → `progress` → `downloaded` events, then installs when
//! the user says so. What changed underneath is that Tauri only accepts an update
//! whose signature matches the public key baked into the app, so a release that is
//! not signed with the project's private key cannot be installed by anyone.
//!
//! Until that keypair exists (see docs/CI.md#updater), a check answers
//! `unconfigured` and says nothing to the user: an update prompt that can never
//! succeed is worse than no prompt, and this runs every thirty minutes.

use serde::Serialize;
use std::sync::Mutex;
use tauri::Emitter;

/// Where the update manifests live. The stable channel rides GitHub's "latest
/// release" redirect; nightlies are published under a fixed tag, since GitHub's
/// latest-release pointer deliberately skips prereleases.
const STABLE_MANIFEST: &str =
    "https://github.com/zeroz41/zeroShiru/releases/latest/download/latest.json";
const NIGHTLY_MANIFEST: &str =
    "https://github.com/zeroz41/zeroShiru/releases/download/nightly/latest.json";

/// The event channel update state arrives on, fanned out per type by the bridge.
const UPDATE_EVENT: &str = "shiru://update";

#[derive(Default)]
pub struct UpdateState {
    /// The channel the user picked, remembered for the install that follows a check.
    channel: Mutex<String>,
}

#[derive(Serialize, PartialEq, Debug)]
#[serde(rename_all = "kebab-case")]
pub enum CheckStatus {
    /// An update was found; it downloads immediately and reports progress.
    Available,
    UpToDate,
    /// No signing key is configured in this build, so nothing could be installed.
    Unconfigured,
    /// The check itself failed — offline, or the manifest could not be read.
    Failed,
}

#[derive(Serialize)]
pub struct CheckResult {
    pub status: CheckStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Why a check failed, for the log rather than for the user.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

fn manifest_for(channel: &str) -> &'static str {
    if channel == "nightly" {
        NIGHTLY_MANIFEST
    } else {
        STABLE_MANIFEST
    }
}

/// Remembers which channel to follow. The frontend also passes it per check, so
/// this only matters to work started later.
#[tauri::command]
pub fn set_update_channel(state: tauri::State<'_, UpdateState>, channel: String) {
    *state.channel.lock().unwrap() = channel;
}

#[cfg(desktop)]
#[tauri::command]
pub async fn check_for_updates(
    app: tauri::AppHandle,
    state: tauri::State<'_, UpdateState>,
    channel: Option<String>,
) -> Result<CheckResult, String> {
    use tauri_plugin_updater::UpdaterExt;

    // The plugin needs a `plugins.updater` section to initialize at all, so the
    // config carries an empty pubkey and release builds substitute the real one.
    // An empty key verifies nothing, and the plugin only notices that at install
    // time -- long after the user has been shown an update. Notice it here.
    if !has_signing_key(&app) {
        return Ok(unconfigured("no signing key compiled in".into()));
    }

    let channel = channel.unwrap_or_else(|| state.channel.lock().unwrap().clone());
    let endpoint = manifest_for(&channel);
    let builder = match app.updater_builder().endpoints(vec![endpoint
        .parse()
        .map_err(|error| format!("bad update endpoint: {error}"))?])
    {
        Ok(builder) => builder,
        Err(error) => return Ok(unconfigured(error.to_string())),
    };
    let updater = match builder.build() {
        Ok(updater) => updater,
        // no public key compiled in: this build cannot verify an update, so it must
        // not offer one
        Err(error) => return Ok(unconfigured(error.to_string())),
    };

    match updater.check().await {
        Ok(Some(update)) => {
            let version = update.version.clone();
            tracing::info!(version = %version, channel = %channel, "update available");
            emit(&app, "available", serde_json::json!(version));
            download(app.clone(), update).await;
            Ok(CheckResult { status: CheckStatus::Available, version: Some(version), detail: None })
        }
        Ok(None) => Ok(CheckResult { status: CheckStatus::UpToDate, version: None, detail: None }),
        Err(error) => {
            tracing::warn!(%error, "update check failed");
            Ok(CheckResult {
                status: CheckStatus::Failed,
                version: None,
                detail: Some(error.to_string()),
            })
        }
    }
}

/// Downloads and stages the update, reporting progress as a percentage. Installing
/// is a separate step, because the user decides when to restart.
#[cfg(desktop)]
async fn download(app: tauri::AppHandle, update: tauri_plugin_updater::Update) {
    let version = update.version.clone();
    let mut downloaded = 0usize;
    let mut last_percent = 0u8;
    let progress = {
        let app = app.clone();
        move |chunk: usize, total: Option<u64>| {
            downloaded += chunk;
            let Some(total) = total.filter(|total| *total > 0) else { return };
            let percent = ((downloaded as f64 / total as f64) * 100.0).min(100.0) as u8;
            // one event per whole percent: the renderer only draws a bar
            if percent > last_percent {
                last_percent = percent;
                emit(&app, "progress", serde_json::json!(percent));
            }
        }
    };
    let finished = {
        let app = app.clone();
        let version = version.clone();
        move || {
            tracing::info!(version = %version, "update downloaded");
            emit(&app, "downloaded", serde_json::json!(version));
        }
    };
    if let Err(error) = update.download_and_install(progress, finished).await {
        tracing::error!(%error, "update download failed");
        emit(&app, "aborted", serde_json::json!(true));
    }
}

/// Restarts into the staged update.
#[cfg(desktop)]
#[tauri::command]
pub fn quit_and_install(app: tauri::AppHandle) {
    tracing::info!("restarting into the staged update");
    app.restart();
}

#[cfg(not(desktop))]
#[tauri::command]
pub async fn check_for_updates(
    _app: tauri::AppHandle,
    _state: tauri::State<'_, UpdateState>,
    _channel: Option<String>,
) -> Result<CheckResult, String> {
    // Android updates come from the store or the APK the user downloads
    Ok(unconfigured("in-app updates are desktop only".into()))
}

#[cfg(not(desktop))]
#[tauri::command]
pub fn quit_and_install(_app: tauri::AppHandle) {}

/// Whether a public key was compiled into this build, as opposed to absent or empty.
#[cfg(desktop)]
fn has_signing_key(app: &tauri::AppHandle) -> bool {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|updater| updater.get("pubkey"))
        .and_then(|key| key.as_str())
        .is_some_and(|key| !key.is_empty())
}

fn unconfigured(detail: String) -> CheckResult {
    tracing::debug!(%detail, "updater not configured");
    CheckResult { status: CheckStatus::Unconfigured, version: None, detail: Some(detail) }
}

fn emit(app: &tauri::AppHandle, kind: &str, data: serde_json::Value) {
    let _ = app.emit(UPDATE_EVENT, serde_json::json!({ "type": kind, "data": data }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_channel_reads_its_own_manifest() {
        assert_eq!(manifest_for("nightly"), NIGHTLY_MANIFEST);
        assert_eq!(manifest_for("stable"), STABLE_MANIFEST);
        // an unknown channel follows stable rather than nothing at all
        assert_eq!(manifest_for(""), STABLE_MANIFEST);
        assert!(STABLE_MANIFEST.starts_with("https://"), "an update manifest must not travel in the clear");
        assert!(NIGHTLY_MANIFEST.starts_with("https://"));
    }

    #[test]
    fn an_unconfigured_build_reports_itself_rather_than_failing() {
        let result = unconfigured("no public key".into());
        assert_eq!(result.status, CheckStatus::Unconfigured);
        assert!(result.version.is_none(), "nothing may be offered that cannot be verified");
    }
}
