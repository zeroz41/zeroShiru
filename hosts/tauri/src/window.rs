//! Window and shell integration: the ELECTRON half of the bridge, minus the
//! pieces that die with Electron (ANGLE selection, DoH toggle live elsewhere).

use tauri::{Emitter, Manager};

#[tauri::command]
pub fn window_minimize(window: tauri::Window) {
    #[cfg(desktop)]
    let _ = window.minimize();
    #[cfg(mobile)]
    let _ = window; // Android backgrounds via the OS, not a titlebar button
}

#[tauri::command]
pub fn window_toggle_maximize(window: tauri::Window) {
    #[cfg(desktop)]
    if window.is_maximized().unwrap_or(false) {
        let _ = window.unmaximize();
    } else {
        let _ = window.maximize();
    }
    #[cfg(mobile)]
    let _ = window;
}

#[tauri::command]
pub fn window_hide(window: tauri::Window) {
    exit_intent_answered();
    let _ = window.hide();
}

#[tauri::command]
pub fn window_show_and_focus(window: tauri::Window) {
    let _ = window.show();
    #[cfg(desktop)]
    let _ = window.unminimize();
    let _ = window.set_focus();
}

#[tauri::command]
pub fn window_is_minimized(window: tauri::Window) -> bool {
    window.is_minimized().unwrap_or(false)
}

#[tauri::command]
pub fn window_is_fullscreen(window: tauri::Window) -> bool {
    window.is_fullscreen().unwrap_or(false)
}

#[tauri::command]
pub fn window_ready(window: tauri::Window) {
    // production shows the window only once the renderer has painted, so it
    // cannot be moved around while still blank — same trick the Electron host used
    let _ = window.show();
}

#[tauri::command]
pub fn app_exit(app: tauri::AppHandle) {
    exit_intent_answered();
    app.exit(0);
}

#[tauri::command]
pub fn open_devtools(window: tauri::WebviewWindow) {
    #[cfg(debug_assertions)]
    window.open_devtools();
    #[cfg(not(debug_assertions))]
    let _ = window;
}

#[tauri::command]
pub async fn pick_file(app: tauri::AppHandle, filters: Option<Vec<String>>) -> Option<String> {
    use tauri_plugin_dialog::DialogExt;
    let mut dialog = app.dialog().file();
    if let Some(extensions) = filters {
        let refs: Vec<&str> = extensions.iter().map(String::as_str).collect();
        dialog = dialog.add_filter("Supported", &refs);
    }
    dialog.blocking_pick_file().map(|path| path.to_string())
}

#[tauri::command]
pub async fn pick_folder(app: tauri::AppHandle) -> Option<String> {
    #[cfg(desktop)]
    {
        use tauri_plugin_dialog::DialogExt;
        app.dialog().file().blocking_pick_folder().map(|path| path.to_string())
    }
    #[cfg(mobile)]
    {
        let _ = app;
        None // Android folder access goes through SAF (phase 12 Kotlin adapter)
    }
}

#[tauri::command]
pub fn notify(app: tauri::AppHandle, title: String, body: Option<String>) {
    use tauri_plugin_notification::NotificationExt;
    let mut builder = app.notification().builder().title(title);
    if let Some(body) = body {
        builder = builder.body(body);
    }
    let _ = builder.show();
}

/// How long the renderer gets to answer a close before the window closes anyway.
const EXIT_INTENT_GRACE_MS: u64 = 4_000;

/// Whether the renderer has answered the close we are waiting on.
static EXIT_INTENT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Records that the renderer took the close it was asked about, so the fallback below stands
/// down. Taking it is enough — the modal it puts up is the user's to answer in their own time,
/// and hurrying that along would be its own bug. Hiding to the tray and quitting count too.
pub fn exit_intent_answered() {
    EXIT_INTENT.store(false, std::sync::atomic::Ordering::SeqCst);
}

/// The renderer saying it has the close in hand and is asking the user about it.
#[tauri::command]
pub fn exit_intent_ack() {
    exit_intent_answered();
}

/// Close means hide-behind-exit-intent, exactly like the Electron host: the frontend shows its
/// quit/minimize modal and decides.
///
/// With one difference, learned the hard way. Preventing the close and waiting on the renderer
/// means a renderer that cannot answer — busy, mid-playback on a black page, wedged, or simply
/// never having registered the handler — leaves a window that cannot be closed at all, and the
/// only way out is killing the process. So the wait is bounded: ask, and if nothing comes back,
/// honour what the user asked for. A second close is taken to mean they are not waiting either.
pub fn handle_window_event(window: &tauri::Window, event: &tauri::WindowEvent) {
    use std::sync::atomic::Ordering;
    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
        // already asking, and asked again: the answer is not coming, and they mean it
        if EXIT_INTENT.swap(true, Ordering::SeqCst) {
            window.app_handle().exit(0);
            return;
        }
        api.prevent_close();
        let _ = window.emit("shiru://exit-intent", ());
        let _ = window.show();
        let app = window.app_handle().clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(EXIT_INTENT_GRACE_MS)).await;
            // still unanswered: nothing is going to ask the user, so stop holding the app open
            if EXIT_INTENT.swap(false, Ordering::SeqCst) {
                tracing::warn!("the renderer did not answer the close, exiting anyway");
                app.exit(0);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn a_renderer_that_takes_the_close_gets_as_long_as_it_needs() {
        // it puts up a quit-or-minimize modal, and nobody answers a modal in four seconds
        EXIT_INTENT.store(true, Ordering::SeqCst);
        exit_intent_ack();
        assert!(!EXIT_INTENT.load(Ordering::SeqCst), "the wait is over; the user's is not");
    }

    #[test]
    fn an_answered_close_stands_the_fallback_down() {
        EXIT_INTENT.store(true, Ordering::SeqCst);
        exit_intent_answered();
        assert!(!EXIT_INTENT.load(Ordering::SeqCst), "the renderer answered, so nothing forces an exit");
    }

    #[test]
    fn the_grace_is_long_enough_to_answer_and_short_enough_to_wait_out() {
        assert!(EXIT_INTENT_GRACE_MS >= 2_000, "a modal has to be able to appear");
        assert!(EXIT_INTENT_GRACE_MS <= 10_000, "nobody waits ten seconds to close a window");
    }
}
