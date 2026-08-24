//! Linux graphics. One thing here is a fix; the rest is a manual override nobody
//! should need.
//!
//! **The fix.** This process's webview is GTK3 — `libgtk-3`/`libgdk-3` plus
//! webkit2gtk-4.1 — and GDK3 has no implementation of `linux-drm-syncobj-v1`. Not a
//! partial one: the protocol's symbols do not appear in the library at all, because
//! explicit sync landed in GTK4 and was never backported. NVIDIA's EGL-Wayland platform
//! library, meanwhile, negotiates that protocol itself, on behalf of a client that knows
//! nothing about it. The compositor is then handed a surface using explicit sync that
//! nothing will ever set an acquire or release point on, and the buffer handoff fails.
//!
//! That is what `Failed to create GBM buffer of size 1280x800: Invalid argument` and
//! `Error 71 (Protocol error) dispatching to Wayland display` are. Not a bad machine, not
//! a driver too old or too new, and not something a particular user did: a client that
//! cannot speak a protocol its EGL layer signed it up for. Every GTK3 WebKitGTK app on
//! NVIDIA under Wayland meets it, which is why every Tauri, wails and GTK3-webkit project
//! has the same issue open.
//!
//! `__NV_DISABLE_EXPLICIT_SYNC=1` is NVIDIA's own documented switch for precisely this
//! case — fall back to implicit sync when the client cannot do explicit sync — so it is
//! set on every Linux launch, before GTK or EGL initialise, whatever else is configured.
//! It is safe to set everywhere because nothing else in a graphics stack reads it: on a
//! full Arch install with Mesa, the Intel and Gallium drivers and Vulkan present, the only
//! libraries containing that string at all are `libnvidia-egl-wayland*`. On AMD, Intel,
//! llvmpipe or under X11 it is an unread string in the environment. It disables no
//! feature this app uses: DMA-BUF, GBM and accelerated compositing all stay on.
//!
//! **The overrides.** Everything below is a manual setting, for a stack that fails for
//! some reason this does not cover. It is not a path any working machine takes.
//!
//! | mode | what it does | still on the GPU |
//! | --- | --- | --- |
//! | `gpu` | the DMA-BUF renderer as WebKit ships it — what everyone gets | yes |
//! | `no-gbm` | `WEBKIT_DMABUF_RENDERER_DISABLE_GBM=1`: buffers are still shared as dma-bufs, they are just not allocated through GBM | yes |
//! | `shm` | `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1`: the renderer stays, its buffers go through shared memory | no |
//! | `safe` | `WEBKIT_DISABLE_DMABUF_RENDERER=1` + `WEBKIT_DISABLE_COMPOSITING_MODE=1` | no |
//!
//! `shm` sits above `safe` because removing the DMA-BUF renderer outright leaves WebKit
//! 2.52 with no accelerated backing-store transport at all, which it does not always
//! survive; forcing that same renderer onto shared memory asks for the slow path by the
//! supported route.
//!
//! A launch that never draws a window still leaves a mark, and the next one steps down a
//! rung — the only way back into an app whose window never opens, since the setting that
//! would fix it lives inside that window. With the fix above in place nothing should ever
//! reach it. A rung that does draw is remembered against a fingerprint of the stack, so
//! the step-down cannot oscillate, and a driver, kernel or WebKit update re-opens the top.
//!
//! `SHIRU_GRAPHICS` overrides the stored preference and never steps down: it is what
//! someone debugging reaches for. Explicit `WEBKIT_*`/`__NV_*` variables win over all of it.

use std::path::{Path, PathBuf};

/// The modes the settings screen offers, in order. `auto` walks the ladder below;
/// everything else names a rung on it.
pub const MODES: [&str; 5] = ["auto", "gpu", "no-gbm", "shm", "safe"];

/// Every mode that draws, fastest first. A launch that fails to draw moves one rung
/// down this; `auto` is not on it because auto is a starting rung, not a setting.
const LADDER: [&str; 4] = ["gpu", "no-gbm", "shm", "safe"];

/// The environment variable that overrides the stored preference.
pub const ENV_OVERRIDE: &str = "SHIRU_GRAPHICS";

/// The canonical name for a mode, accepting the names earlier versions stored. A
/// preference is a file on the user's disk, so renaming a rung must not silently
/// throw their choice away — `gpu-no-gbm` and `no-dmabuf` still mean what they meant.
fn canonical(mode: &str) -> Option<&'static str> {
    Some(match mode.trim() {
        "auto" => "auto",
        // an explicit-sync-free GPU path is what every launch gets now, so the rung
        // that used to mean "the gpu path plus that" is simply the gpu path
        "gpu" | "nvidia-sync" => "gpu",
        "no-gbm" | "gpu-no-gbm" => "no-gbm",
        "shm" | "no-dmabuf" => "shm",
        "safe" => "safe",
        _ => return None,
    })
}

/// Reads the preference file. Unknown or missing content reads as `auto`, so a
/// half-written file cannot leave the app unable to draw.
pub fn stored_mode(config_dir: &Path) -> String {
    std::fs::read_to_string(mode_file(config_dir))
        .ok()
        .and_then(|content| canonical(&content))
        .unwrap_or("auto")
        .to_string()
}

/// Stores the preference for the next launch.
pub fn store_mode(config_dir: &Path, mode: &str) -> Result<(), String> {
    let mode = canonical(mode).ok_or_else(|| format!("unknown graphics mode: {mode}"))?;
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

/// Where the rung that last drew a window is written down, with the stack it drew on.
fn settled_file(config_dir: &Path) -> PathBuf {
    config_dir.join("graphics-settled")
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

/// What the machine's graphics stack is, as far as this bug is concerned. Everything
/// in here is something that, when it changes, could plausibly have fixed the failure
/// — so a change is what earns the fast path another try.
fn stack_fingerprint() -> String {
    let mut parts: Vec<String> = Vec::new();
    // the driver, where there is one that reports itself
    if let Ok(version) = std::fs::read_to_string("/proc/driver/nvidia/version") {
        parts.push(format!("nvidia:{}", version.lines().next().unwrap_or("").trim()));
    }
    // the WebKit actually mapped into this process, not whatever is installed
    if let Ok(maps) = std::fs::read_to_string("/proc/self/maps") {
        if let Some(library) = maps
            .lines()
            .filter_map(|line| line.split_whitespace().last())
            .find(|path| path.contains("libwebkit") && path.contains(".so"))
        {
            parts.push(format!("webkit:{}", library.rsplit('/').next().unwrap_or(library)));
        }
    }
    if let Ok(kernel) = std::fs::read_to_string("/proc/sys/kernel/osrelease") {
        parts.push(format!("kernel:{}", kernel.trim()));
    }
    // X11 and Wayland fail in different places, so they are different stacks
    parts.push(format!("session:{}", std::env::var("XDG_SESSION_TYPE").unwrap_or_default()));
    parts.join("|")
}

/// The rung `auto` starts from: the one that last drew a window on this exact stack,
/// or the top when nothing has been proven — a stack that changed under us included.
fn settled_rung(config_dir: &Path) -> usize {
    let Ok(content) = std::fs::read_to_string(settled_file(config_dir)) else { return 0 };
    let mut lines = content.lines();
    let (Some(fingerprint), Some(mode)) = (lines.next(), lines.next()) else { return 0 };
    if fingerprint != stack_fingerprint() {
        // a driver, kernel or WebKit update is the likeliest thing to have fixed this,
        // so it buys a fresh look at the fast path rather than a permanent demotion
        return 0;
    }
    LADDER.iter().position(|rung| *rung == mode).unwrap_or(0)
}

/// Writes down that this rung drew a window here, so the next launch starts on it
/// instead of rediscovering the failure above it.
fn record_settled(config_dir: &Path, mode: &str) {
    if std::fs::create_dir_all(config_dir).is_ok() {
        let _ = std::fs::write(settled_file(config_dir), format!("{}\n{mode}", stack_fingerprint()));
    }
}

/// The rung this launch is running on, and whether it got there through `auto` — only
/// auto's own discovery is worth remembering, a pinned rung proves nothing about the
/// ones above it.
static IN_FORCE: std::sync::OnceLock<(String, bool)> = std::sync::OnceLock::new();

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
    if let Some((mode, from_auto)) = IN_FORCE.get() {
        if *from_auto {
            record_settled(config_dir, mode);
        }
    }
}

/// Whether a line the renderer printed says it cannot draw. These come from inside
/// WebKit and its GPU process, never reach the page, and are the only warning given
/// before a window that is alive and black.
pub fn renderer_cannot_draw(line: &str) -> bool {
    const FAILURES: [&str; 6] = [
        "Failed to create GBM buffer",
        "Error 71 (Protocol error) dispatching to Wayland display",
        "Failed to create EGL",
        "eglInitialize failed",
        "Could not create EGL context",
        "Failed to create DMABuf",
    ];
    FAILURES.iter().any(|failure| line.contains(failure))
}

/// Remembers that this launch could not draw, whatever the window does afterwards, so
/// the next one starts a rung lower. Nothing is restarted and nothing is interrupted:
/// this is a note for next time, and with the explicit-sync fix in place it should never
/// be written at all.
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

/// The mode in force: where the asked-for mode sits on the ladder, plus one rung for
/// every launch that could not draw. `auto` starts from whatever last drew here.
fn walk(asked: &str, failed: u32, settled: usize) -> &'static str {
    let start = if asked == "auto" {
        settled
    } else {
        LADDER.iter().position(|mode| *mode == asked).unwrap_or(0)
    };
    LADDER[(start + failed as usize).min(LADDER.len() - 1)]
}

/// The mode the environment is demanding, if it is demanding one. Absolute: it is the
/// escape hatch, so it is taken exactly as given and never escalates.
fn env_override() -> Option<&'static str> {
    std::env::var(ENV_OVERRIDE).ok().as_deref().and_then(canonical)
}

/// The mode actually in force, auto resolved against the last launches. What the
/// settings screen reports, so "Automatic" can say what it decided.
pub fn effective_mode(config_dir: &Path) -> String {
    resolve_effective(config_dir, settled_rung(config_dir))
}

/// `effective_mode` with the settled rung handed in, so it can be tested without
/// writing a fingerprint for the machine the test happens to run on.
fn resolve_effective(config_dir: &Path, settled: usize) -> String {
    if let Some(mode) = env_override() {
        return mode.to_string();
    }
    walk(&stored_mode(config_dir), failed_starts(config_dir), settled).to_string()
}

/// The environment each rung asks for. Every rung above `shm` still composites on the
/// GPU; the NVIDIA sync knob is carried down the accelerated rungs because a rung that
/// did not fix it on its own is no reason to take a fix back off.
fn environment(mode: &str) -> &'static [(&'static str, &'static str)] {
    match mode {
        // the DMA-BUF renderer as WebKit ships it, which is the whole point of not being
        // a browser tab. What every machine gets, because the fix is not a mode
        "gpu" => &[],
        // the DMA-BUF renderer without the one allocation that fails: buffers are still
        // dma-bufs, they are just not allocated through GBM
        "no-gbm" => &[("WEBKIT_DMABUF_RENDERER_DISABLE_GBM", "1")],
        // the renderer stays and moves its buffers through shared memory. Slower, and the
        // supported way to ask for slower
        "shm" => &[("WEBKIT_DMABUF_RENDERER_FORCE_SHM", "1")],
        // no renderer and no compositing: for stacks where even shared memory does not come up
        _ => &[
            ("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            ("WEBKIT_DISABLE_COMPOSITING_MODE", "1"),
        ],
    }
}

/// Applies the mode. Runs before Tauri builds, so the config directory is derived
/// rather than asked for: nothing exists yet to ask.
pub fn apply(identifier: &str) {
    let config_dir = config_dir_for(identifier);
    let _ = config_dir;
    #[cfg(target_os = "linux")]
    {
        // The fix, applied before anything reads the environment and whatever mode is in
        // force. GDK3 cannot speak linux-drm-syncobj-v1 — the protocol is not in the
        // library — while NVIDIA's EGL-Wayland layer negotiates it on the client's behalf,
        // which leaves the compositor holding a surface whose sync points nobody sets. This
        // is NVIDIA's own switch for a client that cannot do explicit sync. Nothing else in
        // a graphics stack reads it, so on Mesa or under X11 it is an unread string, and it
        // turns off nothing this app uses: DMA-BUF, GBM and compositing all stay on
        set_default("__NV_DISABLE_EXPLICIT_SYNC", "1");
        // WebKitGTK's web process discards decoded image data at a conservative fraction
        // of its memory limit even while the DOM owns every <img> and zeroShiru holds the
        // encoded bytes. Scrolling back then visibly re-decodes whole poster rails. Rail
        // cards request the correctly-sized AniList variant now, bounding their decoded
        // footprint; disable the periodic pressure sweep that evicted those live frames.
        // WebKit's ordinary memory-cache cap remains, and lib.rs already revives a web
        // process the OS chooses to kill.
        set_default("WEBKIT_DISABLE_MEMORY_PRESSURE_MONITOR", "1");
        let failed = failed_starts(&config_dir);
        let settled = settled_rung(&config_dir);
        let mode = resolve_effective(&config_dir, settled);
        for (name, value) in environment(&mode) {
            set_default(name, value);
        }
        // only auto's own discovery is worth writing down: a pinned rung that drew says
        // nothing about the rungs above it, and the environment override says less still
        let from_auto = env_override().is_none() && stored_mode(&config_dir) == "auto";
        let _ = IN_FORCE.set((mode.clone(), from_auto));
        watch_renderer_output(config_dir.clone());
        if failed > 0 {
            tracing::warn!(target: "graphics", mode = %mode, failed, "falling back after a launch that never drew a window");
        } else if settled > 0 {
            tracing::info!(target: "graphics", mode = %mode, "renderer configured, on the rung that last drew here");
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
        store_mode(&dir, "shm").unwrap();
        assert_eq!(stored_mode(&dir), "shm");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_preference_written_under_the_old_names_still_means_what_it_meant() {
        // these are files on someone's disk; renaming a rung must not quietly discard
        // the choice they made under the old name
        let dir = scratch("legacy");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(mode_file(&dir), "no-dmabuf").unwrap();
        assert_eq!(stored_mode(&dir), "shm");
        std::fs::write(mode_file(&dir), "gpu-no-gbm").unwrap();
        assert_eq!(stored_mode(&dir), "no-gbm");
        store_mode(&dir, "gpu-no-gbm").expect("and the old name is still accepted");
        assert_eq!(stored_mode(&dir), "no-gbm", "stored under the name it has now");
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
    fn every_machine_starts_on_the_gpu() {
        // a driver vendor is not a bug. Nothing is assumed about a stack until it has
        // failed once here, whatever is loaded
        assert_eq!(walk("auto", 0, 0), "gpu");
    }

    #[test]
    fn a_launch_that_could_not_draw_moves_one_rung_down() {
        assert_eq!(walk("auto", 1, 0), "no-gbm");
        assert_eq!(walk("auto", 2, 0), "shm");
        assert_eq!(walk("auto", 3, 0), "safe");
        assert_eq!(walk("auto", 9, 0), "safe", "and never past the end of the ladder");
    }

    #[test]
    fn shared_memory_comes_before_removing_the_renderer_entirely() {
        // WEBKIT_DISABLE_DMABUF_RENDERER can leave 2.52 with no accelerated transport at
        // all; forcing that same renderer onto shared memory is the supported way to ask
        let shm: Vec<&str> = environment("shm").iter().map(|(name, _)| *name).collect();
        assert_eq!(shm, ["WEBKIT_DMABUF_RENDERER_FORCE_SHM"]);
        let safe: Vec<&str> = environment("safe").iter().map(|(name, _)| *name).collect();
        assert!(safe.contains(&"WEBKIT_DISABLE_DMABUF_RENDERER"));
        assert!(LADDER.iter().position(|rung| *rung == "shm") < LADDER.iter().position(|rung| *rung == "safe"));
    }

    #[test]
    fn the_accelerated_rungs_keep_the_gpu() {
        assert!(environment("gpu").is_empty(), "the fast path sets nothing at all");
        assert_eq!(environment("no-gbm"), [("WEBKIT_DMABUF_RENDERER_DISABLE_GBM", "1")]);
        for rung in ["gpu", "no-gbm"] {
            let names: Vec<&str> = environment(rung).iter().map(|(name, _)| *name).collect();
            assert!(!names.contains(&"WEBKIT_DISABLE_DMABUF_RENDERER"), "{rung} composites on the gpu");
            assert!(!names.contains(&"WEBKIT_DMABUF_RENDERER_FORCE_SHM"), "{rung} composites on the gpu");
        }
    }

    #[test]
    fn a_pinned_mode_that_cannot_draw_still_falls_back() {
        // being stuck at a black window with no way in but an environment variable is
        // worse than a preference being overridden for one launch
        assert_eq!(walk("no-gbm", 0, 0), "no-gbm", "what they asked for, first");
        assert_eq!(walk("no-gbm", 1, 0), "shm");
        assert_eq!(walk("no-gbm", 2, 0), "safe");
        assert_eq!(walk("gpu", 1, 0), "no-gbm");
    }

    #[test]
    fn the_rung_that_drew_is_where_the_next_launch_starts() {
        // without this the ladder oscillates: fail, fall back, draw, the drawing clears
        // the failure count, and the launch after that shows another black window
        assert_eq!(walk("auto", 0, 2), "shm");
        assert_eq!(walk("auto", 1, 2), "safe", "and it still steps down from there");
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
    fn what_drew_here_is_only_trusted_while_the_stack_is_the_one_it_drew_on() {
        let dir = scratch("settled");
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(settled_rung(&dir), 0, "nothing proven yet, so the fast path");

        record_settled(&dir, "no-gbm");
        assert_eq!(settled_rung(&dir), 1, "auto starts where it last succeeded");

        // a driver, kernel or WebKit update is the likeliest thing to have fixed this
        std::fs::write(settled_file(&dir), "some-other-stack\nno-gbm").unwrap();
        assert_eq!(settled_rung(&dir), 0, "so a changed stack earns a fresh try at the gpu");

        std::fs::write(settled_file(&dir), "nonsense").unwrap();
        assert_eq!(settled_rung(&dir), 0, "and a file we cannot read is not a demotion");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_fingerprint_names_what_could_plausibly_have_fixed_it() {
        let print = stack_fingerprint();
        assert!(print.contains("session:"), "x11 and wayland fail in different places: {print}");
        assert_eq!(print, stack_fingerprint(), "and it has to be the same answer every launch");
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
    fn the_explicit_sync_fix_is_not_a_mode_and_not_a_fallback() {
        // GDK3 has no linux-drm-syncobj-v1 implementation, so no rung of this ladder is
        // ever a client that can do explicit sync. Making it a mode would mean shipping a
        // configuration that is wrong by construction and waiting for it to fail
        for mode in MODES {
            let names: Vec<&str> = environment(mode).iter().map(|(name, _)| *name).collect();
            assert!(
                !names.contains(&"__NV_DISABLE_EXPLICIT_SYNC"),
                "{mode} must not be where this gets decided"
            );
        }
        // the rung that used to carry it now means what it always should have: the gpu path
        assert_eq!(canonical("nvidia-sync"), Some("gpu"));
        assert!(environment("gpu").is_empty(), "the fast path asks WebKit for nothing special");
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
        assert_eq!(resolve_effective(&dir, 0), "safe");
        std::env::set_var(ENV_OVERRIDE, "no-dmabuf");
        assert_eq!(resolve_effective(&dir, 0), "shm", "under the old name too");
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
            assert!(!walk(mode, 0, 0).is_empty(), "{mode}");
            let _ = std::fs::remove_dir_all(&dir);
        }
        // and the ladder is exactly the modes minus auto, in order
        assert_eq!(MODES[1..], LADDER);
    }
}
