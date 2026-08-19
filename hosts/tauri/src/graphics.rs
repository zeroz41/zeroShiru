//! Linux graphics compatibility (migration report sections 48-49). WebKitGTK's
//! DMABUF renderer fails on some stacks — NVIDIA + Wayland most often, seen as
//! "Error 71 (Protocol error) dispatching to Wayland display" before a window
//! ever appears. Mode is AUTO by default; SHIRU_GRAPHICS=auto|no-dmabuf|safe
//! overrides it, and explicit WEBKIT_* variables set by the user always win.

pub fn apply() {
    #[cfg(target_os = "linux")]
    {
        let mode = std::env::var("SHIRU_GRAPHICS").unwrap_or_else(|_| "auto".into());
        match mode.as_str() {
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
