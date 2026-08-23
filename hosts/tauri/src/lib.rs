//! The Tauri desktop host. Thin by design: commands adapt IPC to the shared crates
//! and never hold application logic themselves (migration report section 45).

mod commands;
mod debrid;
mod diagnostics;
#[cfg(desktop)]
mod desktop;
mod discord;
mod graphics;
mod logging;
mod media_cache;
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
    // logging first, so the renderer decision below is in the log that explains a
    // launch that never drew anything
    logging::init(&graphics::config_dir_for(identifier));
    graphics::apply(identifier);
    let builder = tauri::Builder::default()
        // remote art is served through the host's capped disk cache, so the same
        // cover is downloaded once, not once per session — see media_cache.rs
        .register_asynchronous_uri_scheme_protocol(media_cache::SCHEME, |context, request, responder| {
            let app = context.app_handle().clone();
            tauri::async_runtime::spawn(async move {
                responder.respond(media_cache::respond(&app, request).await);
            });
        });
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
        .on_window_event(window::handle_window_event)
        .manage(debrid::DebridState::default())
        .manage(torrent::TorrentState::default())
        .manage(discord::DiscordState::default())
        .manage(updater::UpdateState::default())
        .invoke_handler(tauri::generate_handler![
            commands::get_app_version,
            commands::get_platform_info,
            commands::route_playback,
            commands::open_uri,
            logging::log_renderer,
            net::probe_network,
            net::http_request,
            debrid::debrid_validate,
            debrid::debrid_list_availability,
            diagnostics::get_diagnostics,
            diagnostics::set_log_filter,
            debrid::debrid_watch_availability,
            debrid::debrid_cancel_availability,
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
            window::exit_intent_ack,
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
            let window_builder =
                tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::App("app.html".into()))
                    .title("zeroShiru")
                    .inner_size(1280.0, 800.0)
                    .min_inner_size(320.0, 390.0)
                    .background_color(tauri::window::Color(0x17, 0x19, 0x1c, 0xff))
                    .initialization_script(bridge_script());
            // The webview's storage was only ever persistent because WebKit derives a
            // default directory from the GTK program name — rename the binary and every
            // user starts over. Name the directory on purpose instead: the exact path
            // the accidental scheme has always used, so nothing existing is orphaned.
            // Linux only — Windows' WebView2 default is already the right LOCALAPPDATA
            // profile, and moving it would orphan those users instead.
            #[cfg(target_os = "linux")]
            let window_builder = {
                use tauri::Manager;
                window_builder.data_directory(app.path().app_data_dir()?)
            };
            let window = window_builder.build()?;
            // The one failure that cannot say anything for itself: the WebKit web
            // process dying. Everything the user sees lives in that process, so when
            // the GPU path drops it — observed on WebKitGTK + NVIDIA after the window
            // was tabbed away during playback and shown again — the app went black,
            // took input from nobody, and left NOTHING in the log, because a dead page
            // cannot log. The host is still alive though, and it can both say what
            // happened (the reason distinguishes a crash from the kernel's memory
            // pressure) and reload the page, which makes WebKit build a fresh process.
            #[cfg(target_os = "linux")]
            {
                let _ = window.with_webview(|webview| {
                    use std::sync::atomic::{AtomicU32, Ordering};
                    use webkit2gtk::WebViewExt;
                    static REVIVALS: AtomicU32 = AtomicU32::new(0);
                    /// A page that dies as soon as it is revived is not coming back;
                    /// reloading it forever would just glow the CPU.
                    const MAX_REVIVALS: u32 = 5;
                    webview.inner().connect_web_process_terminated(|view, reason| {
                        let attempt = REVIVALS.fetch_add(1, Ordering::Relaxed) + 1;
                        tracing::error!(target: "graphics", ?reason, attempt, "the web process died; reloading the page");
                        if attempt <= MAX_REVIVALS {
                            view.reload();
                        } else {
                            tracing::error!(target: "graphics", "the web process keeps dying; giving up on revival — restart the app");
                        }
                    });
                });
            }
            media_cache::spawn_janitor(app.handle());
            #[cfg(target_os = "linux")]
            window::use_native_decorations(&window);
            #[cfg(not(target_os = "linux"))]
            let _ = window;

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
    fn the_bridge_rewrites_art_into_the_scheme_the_host_actually_serves() {
        // a renamed scheme on either side would quietly turn every cover into a 404
        let script = bridge_script();
        assert!(script.contains(&format!("{}://localhost/", media_cache::SCHEME)));
        assert!(script.contains(&format!("http://{}.localhost/", media_cache::SCHEME)), "WebView2 maps custom schemes onto http");
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
