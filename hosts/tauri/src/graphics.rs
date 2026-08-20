//! Linux graphics compatibility (migration report sections 48-49). WebKitGTK's
//! DMABUF renderer fails on some stacks — NVIDIA + Wayland most often, seen as
//! "Error 71 (Protocol error) dispatching to Wayland display" before a window ever
//! appears.
//!
//! Mode is AUTO by default: a stack known to need the fallback gets it from the
//! first launch, and every other stack keeps the GPU path.
//!
//! An NVIDIA driver being loaded is that known-bad stack, and this was briefly
//! narrowed on the theory that current drivers no longer need it. They do — a
//! 610-series open module on KDE Wayland answers with `Failed to create GBM buffer
//! of size 1280x800: Invalid argument` and a black window that is otherwise alive.
//! So auto keeps the guard, and a window is never traded for a frame rate.
//!
//! The cost of the guard is real: without the DMABUF renderer every composited frame
//! goes through shared memory, so hover, scrolling and video are all slower. The
//! narrower knob for it is `gpu-no-gbm`, which drops only GBM *inside* the DMA-BUF
//! renderer (`WEBKIT_DMABUF_RENDERER_DISABLE_GBM`, present in webkit2gtk-4.1 2.52)
//! rather than the renderer itself — aimed at the failing call rather than the
//! feature that contains it. It is offered, not defaulted: it is untested on the
//! stack that needs it, and the first launch is not the place to find out.
//!
//! Every mode **escalates on evidence**: each launch marks that it tried, a launch
//! that draws clears the mark, and one that does not leaves it behind, so each
//! failure moves one rung down the ladder — a pinned mode included, because an app
//! that cannot draw is worse than an app that ignored a preference for one launch.
//! "Draws" means the renderer reported a painted window AND nothing on stderr said it
//! could not allocate a buffer: a window that exists is not a window with anything in
//! it, which is exactly how the black-window case slips past a naive check. Only
//! `SHIRU_GRAPHICS` is absolute — it is what someone debugging reaches for.
//!
//! The user can still pin a mode in settings (stored, applied at the next launch —
//! the renderer is configured before a window exists), and `SHIRU_GRAPHICS` overrides
//! even that, which is what someone debugging a black window reaches for first.
//! Explicit `WEBKIT_*` variables always win over all of it.

use std::path::{Path, PathBuf};

/// The modes the settings screen offers, in order.
pub const MODES: [&str; 4] = ["auto", "gpu-no-gbm", "no-dmabuf", "safe"];

/// Every mode that draws, fastest first. A launch that fails to draw moves one rung
/// down this; `auto` is not on it because auto is a starting rung, not a setting.
const LADDER: [&str; 4] = ["gpu", "gpu-no-gbm", "no-dmabuf", "safe"];

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

/// Set once the renderer has said, on stderr, that it cannot draw. A painted window
/// reported afterwards is not evidence of anything.
static RENDERER_FAILED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The renderer painted, so this configuration works — unless the renderer has already
/// said it cannot allocate a buffer, in which case the window is up and empty and the
/// next launch should try the next rung down.
pub fn started_successfully(config_dir: &Path) {
    started_reported(config_dir, RENDERER_FAILED.load(std::sync::atomic::Ordering::SeqCst));
}

/// A deliberate quit is not a launch that could not draw. Without this, closing the
/// app before the page mounts — or a harness that kills it — reads as a renderer
/// failure and costs the next launch a rung for nothing.
pub fn exiting_cleanly(config_dir: &Path) {
    started_successfully(config_dir);
}

/// `started_successfully` with the renderer's verdict handed in, so the rule can be
/// tested without a process-wide flag that other tests share.
fn started_reported(config_dir: &Path, renderer_failed: bool) {
    if renderer_failed {
        return;
    }
    let _ = std::fs::remove_file(attempt_file(config_dir));
}

/// Whether a line the renderer printed says it cannot draw. These come from inside
/// WebKit and its GPU process, never reach the page, and are the only warning given
/// before a window that is alive and black.
pub fn renderer_cannot_draw(line: &str) -> bool {
    const FAILURES: [&str; 5] = [
        "Failed to create GBM buffer",
        "Error 71 (Protocol error) dispatching to Wayland display",
        "Failed to create EGL",
        "eglInitialize failed",
        "Could not create EGL context",
    ];
    FAILURES.iter().any(|failure| line.contains(failure))
}

/// Remembers that this launch could not draw, whatever the window does afterwards.
pub fn renderer_failed(config_dir: &Path) {
    if RENDERER_FAILED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    record_renderer_failure(config_dir);
}

/// The half of `renderer_failed` that touches the disk, without the once-per-process
/// latch around it.
fn record_renderer_failure(config_dir: &Path) {
    let failed = failed_starts(config_dir);
    if std::fs::create_dir_all(config_dir).is_ok() {
        let _ = std::fs::write(attempt_file(config_dir), (failed.max(1)).to_string());
    }
    tracing::error!(
        target: "graphics",
        "the renderer cannot allocate buffers on this configuration; the next launch will fall back"
    );
}

/// Where auto starts: the GPU path, or straight to the shared-memory one on a stack
/// whose failure mode is a black window rather than an error.
fn auto_start(known_bad: bool) -> usize {
    if known_bad {
        2 // "no-dmabuf"
    } else {
        0
    }
}

/// The mode in force: where the asked-for mode sits on the ladder, plus one rung for
/// every launch that could not draw.
fn walk(asked: &str, failed: u32, known_bad: bool) -> &'static str {
    let start = if asked == "auto" {
        auto_start(known_bad)
    } else {
        LADDER.iter().position(|mode| *mode == asked).unwrap_or(0)
    };
    LADDER[(start + failed as usize).min(LADDER.len() - 1)]
}

/// Whether this machine is the stack the fallback exists for. NVIDIA's driver and
/// WebKitGTK's DMABUF renderer do not get along, and the failure is a black window
/// rather than an error, so this is not worth discovering the hard way.
fn known_bad_stack() -> bool {
    cfg!(target_os = "linux") && Path::new("/proc/driver/nvidia/version").exists()
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
    resolve_effective(config_dir, known_bad_stack())
}

/// `effective_mode` with the stack judgement handed in, so it can be tested on a
/// machine that is not the one being described.
fn resolve_effective(config_dir: &Path, known_bad: bool) -> String {
    // the environment is the escape hatch, so it is taken exactly as given
    if let Ok(mode) = std::env::var(ENV_OVERRIDE) {
        if MODES.contains(&mode.as_str()) {
            return mode;
        }
    }
    walk(&stored_mode(config_dir), failed_starts(config_dir), known_bad).to_string()
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
            // the DMA-BUF renderer without the one call that fails on this driver:
            // buffers are still shared as dma-bufs, they are just not allocated
            // through GBM. Accelerated, and aimed at the actual error
            "gpu-no-gbm" => set_default("WEBKIT_DMABUF_RENDERER_DISABLE_GBM", "1"),
            // auto with nothing against it: the GPU path, which is the whole point
            // of not being a browser tab
            _ => {}
        }
        watch_renderer_output(config_dir.clone());
        if failed > 0 {
            tracing::warn!(target: "graphics", mode = %mode, failed, "falling back after a launch that never drew a window");
        } else {
            tracing::info!(target: "graphics", mode = %mode, "renderer configured");
        }
        record_attempt(&config_dir, failed);
    }
}


/// Watches what the renderer prints for the one thing it never tells the page: that it
/// cannot allocate a buffer, which shows up as a window that is alive and black. The
/// message comes from inside WebKit's GPU process, so it arrives on our stderr and
/// nowhere else — everything read is written straight back out, this only listens.
#[cfg(target_os = "linux")]
fn watch_renderer_output(config_dir: PathBuf) {
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::FromRawFd;

    // a handle on the real stderr to write through to, before it is replaced
    let real = unsafe { libc::dup(libc::STDERR_FILENO) };
    if real < 0 {
        return;
    }
    let mut fds = [0 as libc::c_int; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        unsafe { libc::close(real) };
        return;
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    if unsafe { libc::dup2(write_fd, libc::STDERR_FILENO) } < 0 {
        unsafe {
            libc::close(real);
            libc::close(read_fd);
            libc::close(write_fd);
        }
        return;
    }
    unsafe { libc::close(write_fd) };

    std::thread::spawn(move || {
        let mut out = unsafe { std::fs::File::from_raw_fd(real) };
        let reader = BufReader::new(unsafe { std::fs::File::from_raw_fd(read_fd) });
        for line in reader.lines() {
            let Ok(line) = line else { break };
            // straight back out first: this must never swallow what it is reading
            let _ = writeln!(out, "{line}");
            let _ = out.flush();
            if renderer_cannot_draw(&line) {
                renderer_failed(&config_dir);
            }
        }
    });
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
        store_mode(&dir, "no-dmabuf").unwrap();
        assert_eq!(stored_mode(&dir), "no-dmabuf");
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
    fn a_stack_whose_failure_is_a_black_window_is_not_experimented_on() {
        // the nvidia driver and webkit's dmabuf renderer answer "Failed to create GBM
        // buffer" and then show a window with nothing in it. Discovering that at every
        // first launch is not a trade worth making for a frame rate
        assert_eq!(walk("auto", 0, true), "no-dmabuf");
        assert_eq!(walk("auto", 0, false), "gpu", "and everyone else keeps the gpu path");
    }

    #[test]
    fn a_launch_that_could_not_draw_moves_one_rung_down() {
        assert_eq!(walk("auto", 1, false), "gpu-no-gbm");
        assert_eq!(walk("auto", 2, false), "no-dmabuf");
        assert_eq!(walk("auto", 3, false), "safe");
        assert_eq!(walk("auto", 9, false), "safe", "and never past the end of the ladder");
    }

    #[test]
    fn a_pinned_mode_that_cannot_draw_still_falls_back() {
        // being stuck at a black window with no way in but an environment variable is
        // worse than a preference being overridden for one launch
        assert_eq!(walk("gpu-no-gbm", 0, true), "gpu-no-gbm", "what they asked for, first");
        assert_eq!(walk("gpu-no-gbm", 1, true), "no-dmabuf");
        assert_eq!(walk("gpu-no-gbm", 2, true), "safe");
    }

    #[test]
    fn a_window_that_never_drew_is_remembered_and_a_painted_one_clears_it() {
        let dir = scratch("learns");
        std::fs::create_dir_all(&dir).unwrap();

        record_attempt(&dir, failed_starts(&dir));
        assert_eq!(failed_starts(&dir), 1);

        started_reported(&dir, false);
        assert_eq!(failed_starts(&dir), 0, "a one-off crash must not cost the fast path forever");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_renderer_that_says_it_cannot_draw_is_believed_over_a_window_that_exists() {
        let dir = scratch("black-window");
        std::fs::create_dir_all(&dir).unwrap();

        assert!(renderer_cannot_draw("Failed to create GBM buffer of size 1280x800: Invalid argument"));
        assert!(renderer_cannot_draw("Error 71 (Protocol error) dispatching to Wayland display"));
        assert!(!renderer_cannot_draw("libayatana-appindicator is deprecated"));

        record_renderer_failure(&dir);
        // the page mounts and reports a painted window anyway: it is painting into a
        // buffer nothing can show, which is the whole shape of this bug
        started_reported(&dir, true);
        assert_eq!(failed_starts(&dir), 1, "so the next launch takes the next rung down");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn quitting_on_purpose_is_not_a_launch_that_could_not_draw() {
        // closing the app before the page mounts, or a test harness killing it, used to
        // leave the mark behind and cost the next launch a rung for nothing
        let dir = scratch("clean-exit");
        std::fs::create_dir_all(&dir).unwrap();
        record_attempt(&dir, failed_starts(&dir));
        exiting_cleanly(&dir);
        assert_eq!(failed_starts(&dir), 0);
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

    #[test]
    fn the_environment_is_absolute_because_it_is_the_escape_hatch() {
        let dir = scratch("override");
        store_mode(&dir, "auto").unwrap();
        record_attempt(&dir, 5);
        std::env::set_var(ENV_OVERRIDE, "safe");
        assert_eq!(resolve_effective(&dir, false), "safe");
        std::env::remove_var(ENV_OVERRIDE);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_config_directory_is_the_one_tauri_uses() {
        let dir = config_dir_for("watch.zeroshiru.app");
        assert!(dir.ends_with("watch.zeroshiru.app"));
    }

    #[test]
    fn every_mode_the_settings_screen_offers_can_be_stored_and_walked() {
        for mode in MODES {
            let dir = scratch(&format!("mode-{mode}"));
            store_mode(&dir, mode).expect(mode);
            assert!(!walk(mode, 0, false).is_empty(), "{mode}");
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}
