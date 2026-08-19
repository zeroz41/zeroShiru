//! Linux graphics compatibility (migration report sections 48-49). WebKitGTK's
//! DMABUF renderer fails on some stacks — NVIDIA + Wayland most often, seen as
//! "Error 71 (Protocol error) dispatching to Wayland display" before a window ever
//! appears.
//!
//! Mode is AUTO by default and only the known-bad stack gets the slow path, because
//! forcing the fallback everywhere costs everyone else compositing. The user can
//! pin a mode in settings (stored, applied at the next launch — the renderer is
//! configured before a window exists), and `SHIRU_GRAPHICS` overrides even that,
//! which is what someone debugging a black window reaches for first. Explicit
//! `WEBKIT_*` variables always win over all of it.

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

/// The mode to apply: the environment first, then the stored preference.
fn resolve(config_dir: &Path) -> String {
    match std::env::var(ENV_OVERRIDE) {
        Ok(mode) if MODES.contains(&mode.as_str()) => mode,
        _ => stored_mode(config_dir),
    }
}

/// Applies the mode. Runs before Tauri builds, so the config directory is derived
/// rather than asked for: nothing exists yet to ask.
pub fn apply(identifier: &str) {
    let config_dir = config_dir_for(identifier);
    let _ = config_dir;
    #[cfg(target_os = "linux")]
    {
        match resolve(&config_dir).as_str() {
            "safe" => {
                set_default("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
                set_default("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
            }
            "no-dmabuf" => set_default("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            _ => {
                // auto: only the known-bad stack gets the fallback, everyone else
                // keeps the fast path
                if nvidia_present() {
                    set_default("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
                }
            }
        }
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

#[cfg(target_os = "linux")]
fn nvidia_present() -> bool {
    std::path::Path::new("/proc/driver/nvidia/version").exists()
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
}
