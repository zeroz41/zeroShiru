//! Normalizes extension/provider results into StreamCandidate values.
//!
//! OPEN DECISION (docs/migration/01-parity-checklist.md): the extensions/ workspace
//! is a dynamic JS source system. Until that is resolved, discovery stays host-side
//! and only normalization/ranking lives here.

use shiru_domain::{parse_hash, StreamCandidate};

/// Best-effort normalization of whatever a source handed over.
pub fn normalize(torrent_id: &str) -> Option<StreamCandidate> {
    if torrent_id.starts_with("https://") || torrent_id.starts_with("http://") {
        return Some(StreamCandidate::Direct { url: torrent_id.to_string() });
    }
    let info_hash = parse_hash(torrent_id)?;
    let magnet = torrent_id.starts_with("magnet:").then(|| torrent_id.to_string());
    Some(StreamCandidate::Torrent { info_hash, magnet, file_index: None })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn urls_become_direct_candidates() {
        assert!(matches!(normalize("https://cdn/x.mkv"), Some(StreamCandidate::Direct { .. })));
    }

    #[test]
    fn magnets_and_hashes_become_torrent_candidates() {
        match normalize(&format!("magnet:?xt=urn:btih:{HASH}")) {
            Some(StreamCandidate::Torrent { info_hash, magnet, .. }) => {
                assert_eq!(info_hash, HASH);
                assert!(magnet.is_some());
            }
            other => panic!("unexpected: {other:?}"),
        }
        match normalize(HASH) {
            Some(StreamCandidate::Torrent { info_hash, magnet, .. }) => {
                assert_eq!(info_hash, HASH);
                assert!(magnet.is_none());
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn junk_normalizes_to_nothing() {
        assert_eq!(normalize("not a source"), None);
    }
}
