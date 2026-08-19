//! File shapes shared between the debrid layer and the player.
//! Ports the DebridFile/DebridResolved typedefs and toPlayerFile from
//! common/modules/debrid/{service.js,identity.js}.

use serde::{Deserialize, Serialize};

/// One streamable file a debrid service resolved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DebridFile {
    /// File name without directories.
    pub name: String,
    /// Path within the torrent, always starting with a slash.
    pub path: String,
    /// File size in bytes.
    pub size: u64,
    /// Direct stream URL, must be HTTPS, the player streams it as is.
    pub url: String,
    /// MIME type when the service reports one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub r#type: Option<String>,
}

/// A magnet resolved to direct stream URLs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DebridResolved {
    /// Lowercase info hash.
    pub hash: String,
    /// Torrent name.
    pub name: String,
    /// Streamable files, in torrent order.
    pub files: Vec<DebridFile>,
}

/// A resolved file shaped like the torrent client's file objects, shared watch key included.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayerFile {
    pub info_hash: String,
    /// SHA-1 of `"{infoHash}:{name}:{size}"` — the key watch progress and resume positions are
    /// stored under. MUST stay byte-identical with the torrent client's makeHash, so debrid and
    /// torrent playback of the same release share progress.
    pub file_hash: String,
    /// The torrent's own name. Stays snake_case: the player's file objects have
    /// carried this key since the torrent client wrote them.
    #[serde(rename = "torrent_name")]
    pub torrent_name: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub r#type: Option<String>,
    pub size: u64,
    pub path: String,
    pub url: String,
    pub debrid: bool,
}

/// SHA-1 of a string, hex encoded — the identity function behind `PlayerFile::file_hash`.
pub fn sha1_hex(data: &str) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(data.as_bytes());
    hex::encode(hasher.finalize())
}

/// The key watch progress and resume positions are stored under: sha1 of
/// `"{infoHash}:{name}:{size}"`. Both lanes call this — a debrid play and a torrent
/// play of the same file must land on the same key or resume silently restarts.
pub fn watch_key(info_hash: &str, name: &str, size: u64) -> String {
    sha1_hex(&format!("{info_hash}:{name}:{size}"))
}

/// Shapes one resolved debrid file like the torrent client's file objects.
/// Port of toPlayerFile in common/modules/debrid/identity.js.
pub fn to_player_file(resolved_hash: &str, resolved_name: &str, file: &DebridFile) -> PlayerFile {
    PlayerFile {
        info_hash: resolved_hash.to_string(),
        file_hash: watch_key(resolved_hash, &file.name, file.size),
        torrent_name: resolved_name.to_string(),
        name: file.name.clone(),
        r#type: file.r#type.clone(),
        size: file.size,
        path: file.path.clone(),
        url: file.url.clone(),
        debrid: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_matches_webcrypto_reference() {
        // printf 'abc' | sha1sum
        assert_eq!(sha1_hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(sha1_hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    }

    #[test]
    fn the_watch_key_is_pinned_to_the_format_both_lanes_write() {
        // the same vector crates/torrent pins, so the two can never drift apart
        assert_eq!(
            watch_key("cab1a8cd6ea5d193fd4ea88b8e02b3e5e53e0dcb", "Episode 1.mkv", 123_456),
            sha1_hex("cab1a8cd6ea5d193fd4ea88b8e02b3e5e53e0dcb:Episode 1.mkv:123456")
        );
        // non-ASCII names are routine in real releases: UTF-8 bytes, no normalisation
        assert_eq!(
            watch_key("aa", "★☆Show☆★ - 01.mkv", 10),
            sha1_hex("aa:★☆Show☆★ - 01.mkv:10")
        );
    }

    #[test]
    fn player_file_keeps_the_shared_watch_key() {
        let file = DebridFile {
            name: "ep1.mkv".into(),
            path: "/pack/ep1.mkv".into(),
            size: 123,
            url: "https://cdn.example/ep1.mkv".into(),
            r#type: None,
        };
        let player = to_player_file("aabb", "Pack", &file);
        assert_eq!(player.file_hash, watch_key("aabb", "ep1.mkv", 123));
        assert!(player.debrid);
        assert_eq!(player.torrent_name, "Pack");
    }
}
