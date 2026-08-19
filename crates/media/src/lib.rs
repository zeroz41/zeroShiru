//! Media/container inspection (migration phases 5 and 15). Pure parsing lives here
//! so the TV builds can reuse it via WASM; nothing in this crate may touch the
//! filesystem directly — bytes come in, metadata comes out.

use serde::{Deserialize, Serialize};

pub mod matroska;
pub use matroska::{parse_matroska_head, MatroskaError, MatroskaInfo, Track, TrackKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Container {
    Matroska,
    Mp4,
    WebM,
    Unknown,
}

/// Container detection from the first bytes of a stream.
pub fn detect_container(head: &[u8]) -> Container {
    // EBML magic — Matroska and WebM share it; DocType inside distinguishes them.
    if head.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        return if find(head, b"webm") { Container::WebM } else { Container::Matroska };
    }
    if head.len() >= 12 && &head[4..8] == b"ftyp" {
        return Container::Mp4;
    }
    Container::Unknown
}

fn find(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_matroska_and_webm_by_ebml_doctype() {
        let mut mkv = vec![0x1A, 0x45, 0xDF, 0xA3];
        mkv.extend_from_slice(b"....matroska....");
        assert_eq!(detect_container(&mkv), Container::Matroska);

        let mut webm = vec![0x1A, 0x45, 0xDF, 0xA3];
        webm.extend_from_slice(b"....webm....");
        assert_eq!(detect_container(&webm), Container::WebM);
    }

    #[test]
    fn detects_mp4_by_ftyp() {
        let mp4 = [0, 0, 0, 24, b'f', b't', b'y', b'p', b'i', b's', b'o', b'm'];
        assert_eq!(detect_container(&mp4), Container::Mp4);
    }

    #[test]
    fn junk_is_unknown() {
        assert_eq!(detect_container(b"hello"), Container::Unknown);
    }
}

/// File-kind classification shared with the debrid picker.
/// Port of videoExtensions/subtitleExtensions in common/modules/util.js.
pub const VIDEO_EXTENSIONS: &[&str] = &[
    "3g2", "3gp", "asf", "avi", "dv", "flv", "gxf", "m2ts", "m4a", "m4b", "m4p", "m4r", "m4v",
    "mkv", "mov", "mp4", "mpd", "mpeg", "mpg", "mxf", "nut", "ogm", "ogv", "swf", "ts", "vob",
    "webm", "wmv", "wtv",
];

pub const SUBTITLE_EXTENSIONS: &[&str] = &["srt", "vtt", "ass", "ssa", "sub", "txt"];

fn has_extension(path: &str, extensions: &[&str]) -> bool {
    let Some((_, ext)) = path.rsplit_once('.') else { return false };
    extensions.iter().any(|known| known.eq_ignore_ascii_case(ext))
}

pub fn is_video_path(path: &str) -> bool {
    has_extension(path, VIDEO_EXTENSIONS)
}

pub fn is_subtitle_path(path: &str) -> bool {
    has_extension(path, SUBTITLE_EXTENSIONS)
}

#[cfg(test)]
mod path_tests {
    use super::*;

    #[test]
    fn classifies_paths_case_insensitively() {
        assert!(is_video_path("/pack/Episode 01.MKV"));
        assert!(is_video_path("/a.webm"));
        assert!(!is_video_path("/readme.nfo"));
        assert!(!is_video_path("no-extension"));
        assert!(is_subtitle_path("/subs/ep1.ASS"));
        assert!(!is_subtitle_path("/ep1.mkv"));
    }
}
