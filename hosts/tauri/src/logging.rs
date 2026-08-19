//! File logging for the desktop host, and the two things the settings screen does
//! with it: hand the user a copy, and start it over.
//!
//! Everything under the app — the torrent engine included — emits `tracing`, so one
//! subscriber captures the logs that are actually worth reading when playback
//! misbehaves. The file is plain text, appended to, and never rotated by size: it
//! is a debugging aid the user exports on request, not an audit trail.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// Where the log lives, once `init` has decided.
static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

/// The open handle the subscriber writes through, so `reset` can truncate the same
/// file the writer holds rather than leaving it writing to an unlinked inode.
static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

/// Opens (or creates) the log next to the app's other data and starts capturing.
/// Failing to set up logging must never stop the app from starting.
pub fn init(dir: &Path) {
    let path = dir.join("main.log");
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let Ok(file) = OpenOptions::new().create(true).append(true).open(&path) else {
        return;
    };
    let _ = LOG_PATH.set(path);
    let _ = LOG_FILE.set(Mutex::new(file));

    // RUST_LOG wins where it is set; otherwise keep the file readable rather than
    // drowning it in librqbit's per-peer chatter
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,librqbit=warn"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(LogWriter)
        .with_ansi(false)
        .try_init();
    tracing::info!(version = env!("CARGO_PKG_VERSION"), "zeroShiru starting");
}

/// The path the log is being written to, if logging started.
pub fn path() -> Option<&'static PathBuf> {
    LOG_PATH.get()
}

/// Copies the log somewhere the user can send it on.
pub fn export(destination: &Path) -> Result<(), String> {
    let source = path().ok_or("logging is not running")?;
    std::fs::copy(source, destination).map_err(|error| error.to_string())?;
    Ok(())
}

/// Empties the log without closing it, so the running subscriber keeps writing to
/// the same file the user is looking at.
pub fn reset() -> Result<(), String> {
    {
        let file = LOG_FILE.get().ok_or("logging is not running")?;
        let mut file = file.lock().map_err(|_| "log file is poisoned")?;
        file.set_len(0).map_err(|error| error.to_string())?;
        file.flush().map_err(|error| error.to_string())?;
    }
    // outside the lock: the writer takes the same one, and a std Mutex is not
    // reentrant, so logging in here with the guard alive deadlocks the app
    tracing::info!("log reset");
    Ok(())
}

/// Writes through the shared handle. A log line that cannot be written is dropped:
/// logging must never take the app down with it.
struct LogWriter;

impl std::io::Write for &LogWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if let Some(file) = LOG_FILE.get() {
            if let Ok(mut file) = file.lock() {
                let _ = file.write_all(buf);
            }
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if let Some(file) = LOG_FILE.get() {
            if let Ok(mut file) = file.lock() {
                let _ = file.flush();
            }
        }
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for LogWriter {
    type Writer = &'a LogWriter;

    fn make_writer(&'a self) -> Self::Writer {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_log_is_created_written_exported_and_reset() {
        let dir = std::env::temp_dir().join(format!("zeroshiru-log-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        init(&dir);

        let path = path().expect("logging started");
        tracing::info!("hello from the test");
        assert!(path.exists());

        let copy = dir.join("exported.log");
        export(&copy).expect("export");
        assert!(copy.exists(), "the user gets a copy they can send on");

        reset().expect("reset");
        let after = std::fs::read_to_string(path).unwrap();
        assert!(!after.contains("hello from the test"), "reset drops what was there");

        // and the subscriber keeps writing to the same file afterwards
        tracing::info!("still logging");
        let later = std::fs::read_to_string(path).unwrap();
        assert!(later.contains("still logging"), "a reset log is still a log");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
