//! Desktop integration the settings screen drives: the taskbar badge, the log
//! buttons, and the Linux graphics mode.
//!
//! These replace Electron-era hooks that the bridge was carrying as noops. Two of
//! them changed shape on the way: ANGLE selection was a Chromium switch and has no
//! meaning under WebKitGTK/WebView2, so it became the graphics mode this host
//! actually has; DoH was Chromium's resolver and is gone entirely.

use crate::{graphics, logging};
use tauri::Manager;
use tauri_plugin_dialog::DialogExt;

/// The unread notification count, shown on the dock/taskbar icon where the
/// platform has one.
#[tauri::command]
pub fn set_unread_count(app: tauri::AppHandle, count: i64) {
    #[cfg(desktop)]
    if let Some(window) = app.get_webview_window("main") {
        let badge = (count > 0).then_some(count);
        let _ = window.set_badge_count(badge);
    }
    #[cfg(not(desktop))]
    let _ = (app, count);
}

/// What the settings screen reports back for the Export Logs button:
/// `{ error, cancelled }`, matching the shape the frontend already handles.
#[derive(serde::Serialize, Default)]
pub struct ExportResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub cancelled: bool,
}

/// Asks where to put a copy of the log, then puts one there.
#[tauri::command]
pub async fn export_log(app: tauri::AppHandle) -> ExportResult {
    if logging::path().is_none() {
        return ExportResult { error: Some("logging is not running".into()), cancelled: false };
    }
    let default_name = format!("zeroshiru-{}.log", chrono_stamp());
    let chosen = app
        .dialog()
        .file()
        .set_file_name(default_name)
        .add_filter("Log file", &["log", "txt"])
        .blocking_save_file();
    let Some(destination) = chosen else {
        return ExportResult { error: None, cancelled: true };
    };
    let Ok(destination) = destination.into_path() else {
        return ExportResult { error: Some("that location cannot be written to".into()), cancelled: false };
    };
    match logging::export(&destination) {
        Ok(()) => ExportResult::default(),
        Err(error) => ExportResult { error: Some(error), cancelled: false },
    }
}

#[derive(serde::Serialize)]
pub struct ResetResult {
    pub success: bool,
}

#[tauri::command]
pub fn reset_log() -> ResetResult {
    ResetResult { success: logging::reset().is_ok() }
}

/// The graphics mode in force, and the ones this platform offers. The frontend
/// renders the selector from this rather than knowing the list itself.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphicsInfo {
    pub mode: String,
    pub modes: Vec<&'static str>,
    /// Set when an environment variable is deciding, in which case the stored
    /// preference is being ignored and the UI says so.
    pub overridden: bool,
    /// What is actually in force. `auto` decides from how the last launches went,
    /// so the settings screen can say what it decided rather than only "Automatic".
    pub effective: String,
    /// Launches in a row that never drew a window. Non-zero means auto has fallen
    /// back, which is worth telling the user: it costs them smoothness.
    pub failed_starts: u32,
}

#[tauri::command]
pub fn get_graphics(app: tauri::AppHandle) -> GraphicsInfo {
    let dir = config_dir(&app);
    GraphicsInfo {
        mode: graphics::stored_mode(&dir),
        modes: graphics::MODES.to_vec(),
        overridden: std::env::var_os(graphics::ENV_OVERRIDE).is_some(),
        effective: graphics::effective_mode(&dir),
        failed_starts: graphics::failed_starts(&dir),
    }
}

/// Stores the mode for the next launch. It cannot take effect now: the renderer's
/// compositing is decided before the window exists.
#[tauri::command]
pub fn set_graphics(app: tauri::AppHandle, mode: String) -> Result<(), String> {
    graphics::store_mode(&config_dir(&app), &mode)
}

fn config_dir(app: &tauri::AppHandle) -> std::path::PathBuf {
    app.path().app_config_dir().unwrap_or_else(|_| std::env::temp_dir())
}

/// A sortable timestamp for the exported file name, without pulling in a date
/// library for one string: seconds since the epoch reads fine on a debug log.
fn chrono_stamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reset_without_logging_running_reports_failure_rather_than_pretending() {
        // logging::init has not run in this test binary unless the logging tests did;
        // either way the result must be honest about which happened
        let reported = reset_log().success;
        assert_eq!(reported, logging::path().is_some());
    }
}
