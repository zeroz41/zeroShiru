//! The Tauri desktop host. Thin by design: commands adapt IPC to the shared crates
//! and never hold application logic themselves (migration report section 45).

mod commands;
mod debrid;
mod discord;
mod graphics;
#[cfg(desktop)]
mod shell;
mod torrent;
mod window;

/// The bridge adapter injected before the page loads, with the platform info the
/// synchronous half of the bridge contract needs inlined at startup.
fn bridge_script() -> String {
    let info = serde_json::to_string(&commands::platform_info()).expect("platform info serializes");
    let services = serde_json::to_string(&debrid::catalog()).expect("debrid catalog serializes");
    include_str!("bridge.js")
        .replace("__SHIRU_PLATFORM_INFO__", &info)
        .replace("__SHIRU_DEBRID_SERVICES__", &services)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    graphics::apply();
    let builder = tauri::Builder::default();
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
        // a second launch hands its URLs/args to the running instance
        let urls = argv.iter().filter_map(|arg| url::Url::parse(arg).ok()).collect();
        shell::forward_urls(app, urls);
    }));
    builder
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .on_window_event(|window, event| window::handle_window_event(window, event))
        .manage(debrid::DebridState::default())
        .manage(torrent::TorrentState::default())
        .manage(discord::DiscordState::default())
        .append_invoke_initialization_script(bridge_script())
        .invoke_handler(tauri::generate_handler![
            commands::get_app_version,
            commands::get_platform_info,
            commands::route_playback,
            commands::open_uri,
            debrid::debrid_validate,
            debrid::debrid_list_availability,
            debrid::debrid_check_availability,
            debrid::debrid_unknown_hashes,
            debrid::debrid_remember,
            debrid::debrid_resolve,
            torrent::torrent_start,
            torrent::torrent_stream,
            torrent::torrent_stage,
            torrent::torrent_unload,
            torrent::torrent_untrack,
            torrent::torrent_complete,
            torrent::torrent_rescan,
            torrent::torrent_scrape,
            torrent::torrent_set_playback,
            torrent::torrent_launch_external,
            torrent::torrent_update_settings,
            window::window_minimize,
            window::window_toggle_maximize,
            window::window_hide,
            window::window_show_and_focus,
            window::window_is_minimized,
            window::window_is_fullscreen,
            window::window_ready,
            window::app_exit,
            window::open_devtools,
            window::pick_file,
            window::pick_folder,
            window::notify,
            discord::set_discord_rpc,
            discord::set_presence,
            discord::clear_presence,
        ])
        .setup(|app| {
            #[cfg(desktop)]
            {
                shell::setup_tray(app.handle())?;
                #[cfg(any(windows, target_os = "linux"))]
                {
                    use tauri_plugin_deep_link::DeepLinkExt;
                    let _ = app.deep_link().register_all();
                }
                use tauri_plugin_deep_link::DeepLinkExt;
                let handle = app.handle().clone();
                app.deep_link().on_open_url(move |event| {
                    shell::forward_urls(&handle, event.urls());
                });
            }
            #[cfg(mobile)]
            let _ = app;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
