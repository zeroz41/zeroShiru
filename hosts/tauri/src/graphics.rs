//! Linux graphics compatibility (migration report sections 48-49). WebKitGTK's
//! DMABUF renderer fails on some stacks — NVIDIA + Wayland most often, seen as
//! "Error 71 (Protocol error) dispatching to Wayland display" before a window ever
//! appears.
//!
//! Mode is AUTO by default, and auto now means **try the fast path and learn**. It
//! used to mean "any machine with an NVIDIA driver loaded gets the fallback", which
//! is far too broad a brush: without the DMABUF renderer every composited frame goes
//! through the CPU, so hover states, scrolling and video all get slower — on a
//! machine whose only crime was having a card fitted. Drivers that used to fail no
//! longer do, and the ones that still fail do it loudly and immediately.
//!
//! So: each launch marks that it tried, the renderer clears the mark once a window
//! is actually up, and a launch that never got that far leaves it behind. Auto reads
//! those marks — one failed start drops the DMABUF renderer, two drop compositing
//! as well — so a stack that genuinely cannot do this fixes itself on the next
//! launch instead of costing every other stack its GPU.
//!
//! The user can still pin a mode in settings (stored, applied at the next launch —
//! the renderer is configured before a window exists), and `SHIRU_GRAPHICS` overrides
//! even that, which is what someone debugging a black window reaches for first.
//! Explicit `WEBKIT_*` variables always win over all of it.

use std::path::{Path, PathBuf};

/// The modes the settings screen offers, in order.
pub const MODES: [&str; 3] = ["auto", "no-dmabuf", "safe"];

/// The environment variable that overrides the stored preference.
pub const ENV_OVERRIDE: &str = "SHIRU_GRAPHICS";

/// Reads the preference file. Unknown or missing content reads as `auto`, so a
/// half-written file cannot leave the app unable to draw.
pub fn stored_mode(config_dir: &Path) -> String {
    std::fs::read_to_string(mode_file(config_dir))
        .ok()
        .map(|content| content.trim().to_string())
        .filter(|mode| MODES.contains(&mode.as_str()))
        .unwrap_or_else(|| "auto".into())
}

/// Stores the preference for the next launch.
pub fn store_mode(config_dir: &Path, mode: &str) -> Result<(), String> {
    if !MODES.contains(&mode) {
        return Err(format!("unknown graphics mode: {mode}"));
    }
    std::fs::create_dir_all(config_dir).map_err(|error| error.to_string())?;
    std::fs::write(mode_file(config_dir), mode).map_err(|error| error.to_string())
}

fn mode_file(config_dir: &Path) -> PathBuf {
    config_dir.join("graphics")
}

/// Where a launch records that it is trying to put a window up.
fn attempt_file(config_dir: &Path) -> PathBuf {
    config_dir.join("graphics-attempt")
}

/// How many launches in a row failed to get a window up. Reset by the first one
/// that does, so a one-off crash does not cost the fast path forever.
pub fn failed_starts(config_dir: &Path) -> u32 {
    std::fs::read_to_string(attempt_file(config_dir))
        .ok()
        .and_then(|content| content.trim().parse().ok())
        .unwrap_or(0)
}

/// Records that this launch is trying. Left behind if it never draws.
fn record_attempt(config_dir: &Path, failed: u32) {
    if std::fs::create_dir_all(config_dir).is_ok() {
        let _ = std::fs::write(attempt_file(config_dir), (failed + 1).to_string());
    }
}

/// The window is up, so whatever this launch is doing works. Called from the host
/// as well as from the renderer: a page that fails to mount is a bug in the page,
/// not a reason to take the GPU away from it.
pub fn started_successfully(config_dir: &Path) {
    let _ = std::fs::remove_file(attempt_file(config_dir));
}

/// What auto does on this machine, given how the last launches went.
fn auto_mode(failed: u32) -> &'static str {
    match failed {
        0 => "auto",
        1 => "no-dmabuf",
        _ => "safe",
    }
}

/// The mode the user asked for: the environment first, then the stored preference.
fn resolve(config_dir: &Path) -> String {
    match std::env::var(ENV_OVERRIDE) {
        Ok(mode) if MODES.contains(&mode.as_str()) => mode,
        _ => stored_mode(config_dir),
    }
}

/// The mode actually in force, auto resolved against the last launches. What the
/// settings screen reports, so "Automatic" can say what it decided.
pub fn effective_mode(config_dir: &Path) -> String {
    let asked = resolve(config_dir);
    if asked != "auto" {
        return asked;
    }
    auto_mode(failed_starts(config_dir)).to_string()
}

/// Applies the mode. Runs before Tauri builds, so the config directory is derived
/// rather than asked for: nothing exists yet to ask.
pub fn apply(identifier: &str) {
    let config_dir = config_dir_for(identifier);
    let _ = config_dir;
    #[cfg(target_os = "linux")]
    {
        let failed = failed_starts(&config_dir);
        let mode = effective_mode(&config_dir);
        match mode.as_str() {
            "safe" => {
                set_default("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
                set_default("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
            }
            "no-dmabuf" => set_default("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            // auto with nothing against it: the GPU path, which is the whole point
            // of not being a browser tab
            _ => {}
        }
        if failed > 0 {
            tracing::warn!(target: "graphics", mode = %mode, failed, "falling back after a launch that never drew a window");
        } else {
            tracing::info!(target: "graphics", mode = %mode, "renderer configured");
        }
        record_attempt(&config_dir, failed);
    }
}

/// Where Tauri will put the app config, worked out without an app handle.
pub fn config_dir_for(identifier: &str) -> PathBuf {
    let base = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Library/Application Support"))
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
    };
    base.unwrap_or_else(std::env::temp_dir).join(identifier)
}

#[cfg(target_os = "linux")]
fn set_default(name: &str, value: &str) {
    if std::env::var_os(name).is_none() {
        std::env::set_var(name, value);
    }
}



#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("zeroshiru-graphics-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn nothing_stored_reads_as_auto() {
        assert_eq!(stored_mode(&scratch("empty")), "auto");
    }

    #[test]
    fn a_stored_mode_survives_a_restart() {
        let dir = scratch("stored");
        store_mode(&dir, "safe").unwrap();
        assert_eq!(stored_mode(&dir), "safe");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn junk_in_the_file_cannot_leave_the_app_unable_to_draw() {
        let dir = scratch("junk");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(mode_file(&dir), "half-written nonsense").unwrap();
        assert_eq!(stored_mode(&dir), "auto");
        assert!(store_mode(&dir, "nonsense").is_err(), "and the UI cannot store that either");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_environment_beats_the_stored_preference() {
        let dir = scratch("override");
        store_mode(&dir, "safe").unwrap();
        std::env::set_var(ENV_OVERRIDE, "no-dmabuf");
        assert_eq!(resolve(&dir), "no-dmabuf", "debugging a black window must not need the settings screen");
        std::env::remove_var(ENV_OVERRIDE);
        assert_eq!(resolve(&dir), "safe");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_config_directory_is_the_one_tauri_uses() {
        let dir = config_dir_for("watch.zeroshiru.app");
        assert!(dir.ends_with("watch.zeroshiru.app"));
    }
    #[test]
    fn a_machine_that_has_never_failed_keeps_its_gpu() {
        let dir = scratch("fast");
        assert_eq!(effective_mode(&dir), "auto", "having a card fitted is not evidence of anything");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_launch_that_never_drew_a_window_falls_back_at_the_next_one() {
        let dir = scratch("learns");
        std::fs::create_dir_all(&dir).unwrap();

        // a launch starts, and dies before anything is composited
        record_attempt(&dir, failed_starts(&dir));
        assert_eq!(failed_starts(&dir), 1);
        assert_eq!(effective_mode(&dir), "no-dmabuf", "the fast path is what fails on these stacks");

        // it fails again on the slower path, so compositing goes too
        record_attempt(&dir, failed_starts(&dir));
        assert_eq!(effective_mode(&dir), "safe");

        // and a launch that does draw clears the record: a one-off crash must not
        // cost the machine its GPU forever
        started_successfully(&dir);
        assert_eq!(failed_starts(&dir), 0);
        assert_eq!(effective_mode(&dir), "auto");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_pinned_mode_is_not_second_guessed_by_a_bad_launch() {
        let dir = scratch("pinned");
        store_mode(&dir, "no-dmabuf").unwrap();
        record_attempt(&dir, 5);
        assert_eq!(effective_mode(&dir), "no-dmabuf", "the user asked for this one");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_half_written_attempt_file_reads_as_no_failures() {
        let dir = scratch("junk-attempt");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(attempt_file(&dir), "not a number").unwrap();
        assert_eq!(failed_starts(&dir), 0, "a file we cannot read must not take the fast path away");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
