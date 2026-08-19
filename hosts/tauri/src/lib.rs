//! The Tauri desktop host. Thin by design: commands adapt IPC to the shared crates
//! and never hold application logic themselves (migration report section 45).

mod commands;
mod debrid;
#[cfg(desktop)]
mod desktop;
mod discord;
mod graphics;
mod logging;
mod net;
#[cfg(desktop)]
mod shell;
mod torrent;
mod updater;
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

/// Every command name `bridge.js` invokes. Kept beside the handler list below so a
/// renamed command cannot silently become a call into nothing at runtime.
#[cfg(test)]
fn bridge_invocations(script: &str) -> Vec<String> {
    let mut names = Vec::new();
    for (index, _) in script.match_indices("invoke('") {
        let rest = &script[index + "invoke('".len()..];
        if let Some(end) = rest.find('\'') {
            names.push(rest[..end].to_string());
        }
    }
    names.sort();
    names.dedup();
    names
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // both run before the window exists: the renderer is configured at startup, and
    // anything that goes wrong from here should end up in the log
    let identifier = "watch.zeroshiru.app";
    graphics::apply(identifier);
    logging::init(&graphics::config_dir_for(identifier));
    let builder = tauri::Builder::default();
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
        // a second launch hands its URLs/args to the running instance
        let urls = argv.iter().filter_map(|arg| url::Url::parse(arg).ok()).collect();
        shell::forward_urls(app, urls);
    }));
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_updater::Builder::new().build());
    builder
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .on_window_event(|window, event| window::handle_window_event(window, event))
        .manage(debrid::DebridState::default())
        .manage(torrent::TorrentState::default())
        .manage(discord::DiscordState::default())
        .manage(updater::UpdateState::default())
        .invoke_handler(tauri::generate_handler![
            commands::get_app_version,
            commands::get_platform_info,
            commands::route_playback,
            commands::open_uri,
            net::probe_network,
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
            #[cfg(desktop)]
            desktop::set_unread_count,
            #[cfg(desktop)]
            desktop::export_log,
            #[cfg(desktop)]
            desktop::reset_log,
            #[cfg(desktop)]
            desktop::get_graphics,
            #[cfg(desktop)]
            desktop::set_graphics,
            updater::set_update_channel,
            updater::check_for_updates,
            updater::quit_and_install,
            discord::set_discord_rpc,
            discord::set_presence,
            discord::clear_presence,
        ])
        .setup(|app| {
            // Built in code rather than listed in tauri.conf.json because the bridge
            // must be a webview initialization script: those are the only scripts that
            // run after ALL of Tauri's own bootstrap (window.__TAURI__ included), and
            // config windows offer no way to attach one. Keep the settings in sync
            // with the frontend's expectations, not with a config block.
            tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::App("app.html".into()))
                .title("zeroShiru")
                .inner_size(1280.0, 800.0)
                .min_inner_size(320.0, 390.0)
                .background_color(tauri::window::Color(0x17, 0x19, 0x1c, 0xff))
                .initialization_script(bridge_script())
                .build()?;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The command names the invoke_handler above registers. Parsed from this file so
    /// the test cannot drift from the list it is checking.
    fn registered_commands() -> Vec<String> {
        let source = include_str!("lib.rs");
        let start = source.find("generate_handler![").expect("handler list");
        let end = source[start..].find("])").expect("handler list end") + start;
        let mut names: Vec<String> = source[start..end]
            .lines()
            .filter_map(|line| line.trim().trim_end_matches(',').rsplit("::").next())
            .filter(|name| !name.is_empty() && !name.contains('!') && !name.contains('['))
            .map(str::to_string)
            .collect();
        names.sort();
        names.dedup();
        names
    }

    #[test]
    fn every_command_the_bridge_invokes_is_registered() {
        let script = bridge_script();
        let registered = registered_commands();
        let invoked = bridge_invocations(&script);
        let missing: Vec<&String> = invoked.iter().filter(|name| !registered.contains(name)).collect();
        assert!(missing.is_empty(), "bridge.js invokes commands that no handler registers: {missing:?}");
    }

    #[test]
    fn the_inlined_values_the_sync_bridge_contract_needs_are_substituted() {
        let script = bridge_script();
        assert!(!script.contains("__SHIRU_PLATFORM_INFO__"), "getPlatformInfo must be answerable without an await");
        assert!(!script.contains("__SHIRU_DEBRID_SERVICES__"), "the settings menu reads the service registry synchronously");
        // and the substituted values are the real ones
        assert!(script.contains(std::env::consts::OS));
        assert!(script.contains("\"torbox\""), "the debrid catalog reaches the frontend");
        assert!(script.contains("\"Real-Debrid\""));
    }
}
