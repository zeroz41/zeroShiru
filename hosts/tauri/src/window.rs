//! Window and shell integration: the ELECTRON half of the bridge, minus the
//! pieces that die with Electron (ANGLE selection, DoH toggle live elsewhere).

use tauri::Emitter;

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

/// Close means hide-behind-exit-intent, exactly like the Electron host: the
/// frontend shows its quit/minimize modal and decides.
pub fn handle_window_event(window: &tauri::Window, event: &tauri::WindowEvent) {
    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
        api.prevent_close();
        let _ = window.emit("shiru://exit-intent", ());
        let _ = window.show();
    }
}
