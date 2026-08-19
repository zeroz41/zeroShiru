//! Integration tests against real ffmpeg-muxed fixtures (tests/fixtures/,
//! regenerable — see the commands in the repo history / module docs). The
//! library itself never touches the filesystem; only these tests do, standing
//! in for the torrent gateway that normally serves the byte ranges.

use shiru_media::{parse_matroska_head, MatroskaError, TrackKind};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

#[test]
fn video_audio_fixture_yields_title_duration_and_tracks() {
    let bytes = fixture("fixture.mkv");
    let info = parse_matroska_head(&bytes).unwrap();

    assert_eq!(info.title.as_deref(), Some("Fixture"));
    let duration = info.duration_ms.expect("ffmpeg writes Duration");
    assert!((900.0..2100.0).contains(&duration), "one second of media, got {duration}ms");

    assert_eq!(info.tracks.len(), 2);
    let video = &info.tracks[0];
    assert_eq!(video.kind, TrackKind::Video);
    assert_eq!(video.number, 1);
    assert_eq!(video.codec_id, "V_MPEG4/ISO/AVC");
    assert_eq!(video.language, "und", "ffmpeg tags unlabelled video as und");
    assert!(video.codec_private.is_none(), "AVC decoder config is not the metadata layer's business");
    assert!(!video.default, "muxed without a default disposition: explicit FlagDefault 0");

    let audio = &info.tracks[1];
    assert_eq!(audio.kind, TrackKind::Audio);
    assert_eq!(audio.number, 2);
    assert_eq!(audio.codec_id, "A_AAC");
    assert_eq!(audio.language, "jpn");
    assert_eq!(audio.name.as_deref(), Some("Japanese Audio"));
    assert!(audio.default);
}

#[test]
fn ass_fixture_carries_the_subtitle_header_in_codec_private() {
    let bytes = fixture("fixture_subs.mkv");
    let info = parse_matroska_head(&bytes).unwrap();

    let subs = info
        .tracks
        .iter()
        .find(|track| track.kind == TrackKind::Subtitle)
        .expect("the fixture muxes an ASS track");
    assert_eq!(subs.codec_id, "S_TEXT/ASS");
    assert_eq!(subs.language, "eng");
    assert_eq!(subs.name.as_deref(), Some("Full Subtitles"));
    assert!(subs.default);
    assert!(subs.forced, "muxed with -disposition default+forced");

    // The ASS header — [Script Info], styles and all — must travel in
    // CodecPrivate; it is what the renderer boots from before any cue arrives.
    let header = subs.codec_private.as_deref().expect("subtitle CodecPrivate kept");
    let header = std::str::from_utf8(header).unwrap();
    assert!(header.contains("[Script Info]"));
    assert!(header.contains("[V4+ Styles]"));
    assert!(header.contains("Style: Signs"));
}

/// The streaming claim, proven per fixture: a prefix strictly smaller than the
/// file parses identically to the whole file, and every shorter prefix asks
/// for more data instead of failing hard.
#[test]
fn a_head_prefix_is_enough_and_short_prefixes_ask_for_more() {
    for name in ["fixture.mkv", "fixture_subs.mkv"] {
        let bytes = fixture(name);
        let full = parse_matroska_head(&bytes).unwrap();

        // find the exact smallest prefix that parses (the fixtures are tiny)
        let enough = (0..bytes.len())
            .find(|&len| parse_matroska_head(&bytes[..len]).is_ok())
            .unwrap_or_else(|| panic!("{name}: no proper prefix parses"));
        assert!(
            enough < bytes.len() / 2,
            "{name}: metadata must live in the head, needed {enough} of {}",
            bytes.len()
        );

        let head = parse_matroska_head(&bytes[..enough]).unwrap();
        assert_eq!(head.tracks, full.tracks, "{name}: prefix and full parse must agree");
        assert_eq!(head.title, full.title);
        assert_eq!(head.duration_ms, full.duration_ms);

        // everything shorter is NeedMoreData — never NotMatroska/Invalid,
        // since a truncated valid stream is the normal streaming condition
        for len in (0..enough).step_by(37) {
            assert_eq!(
                parse_matroska_head(&bytes[..len]).unwrap_err(),
                MatroskaError::NeedMoreData,
                "{name}: prefix of {len} bytes"
            );
        }
    }
}
