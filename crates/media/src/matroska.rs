//! Streaming Matroska (MKV/WebM) metadata parsing — the Rust replacement for the
//! `matroska-metadata` npm package's track-discovery phase.
//!
//! The streaming constraint shapes everything here: bytes arrive from a torrent
//! gateway or debrid CDN via HTTP range requests against the HEAD of the file,
//! never from a local file. That means:
//!
//! * We parse from a plain `&[u8]` — whatever prefix of the file the caller has
//!   fetched so far. No I/O, no async; this must compile for
//!   `wasm32-unknown-unknown` so the TV builds can reuse it.
//! * Running out of bytes mid-structure is not corruption, it is the normal
//!   "fetch a bigger range and call again" signal — surfaced as the
//!   distinguishable [`MatroskaError::NeedMoreData`].
//! * The `Segment` element is typically written with an *unknown size* in
//!   streamed/live-muxed files (the muxer cannot know the final length up
//!   front), so we must descend into it rather than try to skip over it.
//!
//! Everything the player needs at stream-open time — track numbers, kinds,
//! codec ids, languages, names, flags, and the `CodecPrivate` blob that carries
//! ASS `[Script Info]` headers — lives in the `Info` and `Tracks` elements near
//! the head, so a few hundred KB of prefix is always enough in practice.

use serde::{Deserialize, Serialize};

// --- EBML element ids (stored with their length-descriptor bits, as read off the wire) ---
const ID_EBML: u32 = 0x1A45_DFA3;
const ID_DOCTYPE: u32 = 0x4282;
const ID_SEGMENT: u32 = 0x1853_8067;
const ID_INFO: u32 = 0x1549_A966;
const ID_TIMESTAMP_SCALE: u32 = 0x2A_D7B1;
const ID_DURATION: u32 = 0x4489;
const ID_TITLE: u32 = 0x7BA9;
const ID_TRACKS: u32 = 0x1654_AE6B;
const ID_TRACK_ENTRY: u32 = 0xAE;
const ID_TRACK_NUMBER: u32 = 0xD7;
const ID_TRACK_TYPE: u32 = 0x83;
const ID_CODEC_ID: u32 = 0x86;
const ID_CODEC_PRIVATE: u32 = 0x63A2;
const ID_NAME: u32 = 0x536E;
const ID_LANGUAGE: u32 = 0x22_B59C;
const ID_LANGUAGE_BCP47: u32 = 0x22_B59D;
const ID_FLAG_DEFAULT: u32 = 0x88;
const ID_FLAG_FORCED: u32 = 0x55AA;
const ID_CLUSTER: u32 = 0x1F43_B675;

/// Nanoseconds per timestamp tick when `Info` carries no `TimestampScale` —
/// the Matroska spec default, and what makes one tick equal one millisecond.
const DEFAULT_TIMESTAMP_SCALE: u64 = 1_000_000;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum MatroskaError {
    /// The slice ended before the `Tracks` element was fully parsed. Not an
    /// error in the streaming sense: the caller should range-request a larger
    /// prefix of the file and parse again.
    #[error("byte slice ends before the Tracks element; fetch a larger prefix and retry")]
    NeedMoreData,
    /// The bytes do not start with an EBML header whose DocType is
    /// matroska/webm — wrong container, retrying with more data cannot help.
    #[error("not a Matroska/WebM stream")]
    NotMatroska,
    /// Structurally invalid EBML (bad vint, oversized id, unknown-size leaf).
    /// More data cannot help here either.
    #[error("invalid EBML structure: {0}")]
    Invalid(&'static str),
}

/// What kind of stream a `TrackEntry` describes, mapped from the Matroska
/// `TrackType` codes the player cares about (1/2/17); everything else (complex,
/// logo, buttons, control, metadata) is grouped as `Other` rather than dropped,
/// so track numbering stays complete for cue routing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TrackKind {
    Video,
    Audio,
    Subtitle,
    Other,
}

impl TrackKind {
    fn from_code(code: u64) -> Self {
        match code {
            1 => Self::Video,
            2 => Self::Audio,
            17 => Self::Subtitle,
            _ => Self::Other,
        }
    }
}

/// One `TrackEntry`, reduced to what the playback pipeline consumes: routing
/// (number), selection (kind/language/flags), display (name), and decoding
/// (codec id, plus `CodecPrivate` for subtitle tracks — ASS styles and
/// `[Script Info]` headers travel there).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub number: u64,
    pub kind: TrackKind,
    pub codec_id: String,
    pub name: Option<String>,
    /// Resolved language: `LanguageBCP47` when present (it overrides the
    /// legacy element per spec), else `Language`, else the spec default "eng".
    pub language: String,
    pub default: bool,
    pub forced: bool,
    /// Kept only for subtitle tracks — video/audio `CodecPrivate` (SPS/PPS,
    /// AAC config) can be large and the metadata layer has no use for it.
    pub codec_private: Option<Vec<u8>>,
}

/// Segment-level metadata parsed from the head of a Matroska stream.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct MatroskaInfo {
    pub title: Option<String>,
    /// `Info.Duration` converted to milliseconds via `TimestampScale`.
    /// Absent in live/unfinished streams.
    pub duration_ms: Option<f64>,
    pub tracks: Vec<Track>,
}

/// Parse segment metadata from the head of a Matroska byte stream.
///
/// `bytes` is whatever prefix of the file the caller has — succeeds once the
/// prefix covers the EBML header plus the `Tracks` element (typically well
/// under the first MB). Returns [`MatroskaError::NeedMoreData`] when the slice
/// ends first: fetch more and call again. `Info` fields found after `Tracks`
/// are picked up only if the slice reaches them; `Tracks` alone is the
/// success criterion, because track listing is what gates playback start.
pub fn parse_matroska_head(bytes: &[u8]) -> Result<MatroskaInfo, MatroskaError> {
    let mut reader = Reader::new(bytes);

    // EBML header: must exist, must have a known size, and its DocType must be
    // matroska or webm (absent DocType defaults to "matroska" per spec).
    let (id, size) = reader.read_element()?;
    if id != ID_EBML {
        return Err(MatroskaError::NotMatroska);
    }
    let size = size.ok_or(MatroskaError::Invalid("EBML header with unknown size"))?;
    check_doctype(reader.take(size)?)?;

    // Top level: everything before the Segment (there shouldn't be anything)
    // gets skipped; the Segment itself is descended into even when its size is
    // unknown — which it usually is in streamed files.
    loop {
        let (id, size) = reader.read_element()?;
        if id == ID_SEGMENT {
            break;
        }
        let size = size.ok_or(MatroskaError::Invalid("unknown-size element outside Segment"))?;
        reader.skip(size)?;
    }

    let mut info = MatroskaInfo::default();
    let mut have_tracks = false;
    let mut have_info = false;
    loop {
        let (id, size) = match reader.read_element() {
            Ok(element) => element,
            // The slice ran out after Tracks: return what we have. Before
            // Tracks it is the caller's cue to fetch more.
            Err(MatroskaError::NeedMoreData) if have_tracks => break,
            Err(error) => return Err(error),
        };
        match id {
            ID_INFO => {
                let size = size.ok_or(MatroskaError::Invalid("unknown-size Info"))?;
                parse_info(reader.take(size)?, &mut info)?;
                have_info = true;
            }
            ID_TRACKS => {
                let size = size.ok_or(MatroskaError::Invalid("unknown-size Tracks"))?;
                info.tracks = parse_tracks(reader.take(size)?)?;
                have_tracks = true;
            }
            // Media data begins — the metadata head is over. (Reached with
            // have_tracks == false only in the rare Tracks-after-Clusters
            // layout, where skipping the cluster and scanning on is correct.)
            ID_CLUSTER if have_tracks => break,
            _ => {
                let Some(size) = size else {
                    if have_tracks {
                        break; // e.g. an unknown-size Cluster: nothing left to learn
                    }
                    return Err(MatroskaError::Invalid("unknown-size element before Tracks"));
                };
                match reader.skip(size) {
                    Ok(()) => {}
                    Err(MatroskaError::NeedMoreData) if have_tracks => break,
                    Err(error) => return Err(error),
                }
            }
        }
        if have_tracks && have_info {
            break;
        }
    }
    if !have_tracks {
        return Err(MatroskaError::NeedMoreData);
    }
    Ok(info)
}

/// Verify the EBML header's DocType. A header without a DocType element
/// defaults to "matroska" per spec, so only an explicit foreign DocType rejects.
fn check_doctype(header: &[u8]) -> Result<(), MatroskaError> {
    let mut reader = Reader::new(header);
    while !reader.is_empty() {
        let (id, size) = reader.read_element()?;
        let size = size.ok_or(MatroskaError::Invalid("unknown-size element in EBML header"))?;
        let payload = reader.take(size)?;
        if id == ID_DOCTYPE {
            return match parse_string(payload).as_str() {
                "matroska" | "webm" => Ok(()),
                _ => Err(MatroskaError::NotMatroska),
            };
        }
    }
    Ok(())
}

/// `Segment.Info`: title and duration. TimestampScale may follow Duration
/// within Info, so the raw duration is only converted after the full pass.
fn parse_info(payload: &[u8], info: &mut MatroskaInfo) -> Result<(), MatroskaError> {
    let mut reader = Reader::new(payload);
    let mut scale = DEFAULT_TIMESTAMP_SCALE;
    let mut raw_duration = None;
    while !reader.is_empty() {
        let (id, size) = reader.read_element()?;
        let size = size.ok_or(MatroskaError::Invalid("unknown-size element in Info"))?;
        let payload = reader.take(size)?;
        match id {
            ID_TIMESTAMP_SCALE => scale = parse_uint(payload),
            ID_DURATION => raw_duration = Some(parse_float(payload)?),
            ID_TITLE => info.title = Some(parse_string(payload)),
            _ => {}
        }
    }
    // Duration is stored in TimestampScale ticks; scale is ns per tick.
    info.duration_ms = raw_duration.map(|ticks| ticks * scale as f64 / 1e6);
    Ok(())
}

fn parse_tracks(payload: &[u8]) -> Result<Vec<Track>, MatroskaError> {
    let mut reader = Reader::new(payload);
    let mut tracks = Vec::new();
    while !reader.is_empty() {
        let (id, size) = reader.read_element()?;
        let size = size.ok_or(MatroskaError::Invalid("unknown-size element in Tracks"))?;
        let payload = reader.take(size)?;
        if id == ID_TRACK_ENTRY {
            tracks.push(parse_track_entry(payload)?);
        }
    }
    Ok(tracks)
}

fn parse_track_entry(payload: &[u8]) -> Result<Track, MatroskaError> {
    let mut reader = Reader::new(payload);
    let mut track = Track {
        number: 0,
        kind: TrackKind::Other,
        codec_id: String::new(),
        name: None,
        language: String::new(),
        // Spec defaults: FlagDefault is 1 unless written, FlagForced is 0.
        default: true,
        forced: false,
        codec_private: None,
    };
    let mut language = None;
    let mut language_bcp47 = None;
    let mut codec_private = None;
    while !reader.is_empty() {
        let (id, size) = reader.read_element()?;
        let size = size.ok_or(MatroskaError::Invalid("unknown-size element in TrackEntry"))?;
        let payload = reader.take(size)?;
        match id {
            ID_TRACK_NUMBER => track.number = parse_uint(payload),
            ID_TRACK_TYPE => track.kind = TrackKind::from_code(parse_uint(payload)),
            ID_CODEC_ID => track.codec_id = parse_string(payload),
            ID_NAME => track.name = Some(parse_string(payload)),
            ID_LANGUAGE => language = Some(parse_string(payload)),
            ID_LANGUAGE_BCP47 => language_bcp47 = Some(parse_string(payload)),
            ID_FLAG_DEFAULT => track.default = parse_uint(payload) != 0,
            ID_FLAG_FORCED => track.forced = parse_uint(payload) != 0,
            ID_CODEC_PRIVATE => codec_private = Some(payload.to_vec()),
            _ => {}
        }
    }
    track.language = language_bcp47
        .or(language)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "eng".into());
    if track.kind == TrackKind::Subtitle {
        track.codec_private = codec_private;
    }
    Ok(track)
}

// --- EBML primitives ---

/// Unsigned integer: 0-8 big-endian bytes, empty means 0 per spec.
fn parse_uint(payload: &[u8]) -> u64 {
    payload.iter().fold(0u64, |acc, &byte| acc << 8 | byte as u64)
}

/// Float: 0 (meaning 0.0), 4, or 8 big-endian bytes.
fn parse_float(payload: &[u8]) -> Result<f64, MatroskaError> {
    match payload.len() {
        0 => Ok(0.0),
        4 => Ok(f32::from_be_bytes(payload.try_into().unwrap()) as f64),
        8 => Ok(f64::from_be_bytes(payload.try_into().unwrap())),
        _ => Err(MatroskaError::Invalid("float element must be 0, 4 or 8 bytes")),
    }
}

/// UTF-8 string; Matroska permits trailing NUL padding, which we strip.
fn parse_string(payload: &[u8]) -> String {
    let trimmed = payload.split(|&byte| byte == 0).next().unwrap_or(payload);
    String::from_utf8_lossy(trimmed).into_owned()
}

/// Cursor over the fetched prefix. Every "not enough bytes" condition maps to
/// `NeedMoreData`, because from the caller's seat that is what it means.
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn is_empty(&self) -> bool {
        self.pos >= self.data.len()
    }

    /// Element id: a vint of 1-4 bytes kept *with* its length-descriptor bits,
    /// which is how ids are conventionally written (0x1A45DFA3 etc.).
    fn read_id(&mut self) -> Result<u32, MatroskaError> {
        let first = *self.data.get(self.pos).ok_or(MatroskaError::NeedMoreData)?;
        let length = first.leading_zeros() as usize + 1;
        if length > 4 {
            return Err(MatroskaError::Invalid("element id longer than 4 bytes"));
        }
        let end = self.pos + length;
        if end > self.data.len() {
            return Err(MatroskaError::NeedMoreData);
        }
        let id = self.data[self.pos..end].iter().fold(0u32, |acc, &byte| acc << 8 | byte as u32);
        self.pos = end;
        Ok(id)
    }

    /// Element size: a vint of 1-8 bytes with the descriptor bit stripped.
    /// `None` is the all-value-bits-set "unknown size" marker — legal only on
    /// master elements, and routine on the Segment of a streamed file.
    fn read_size(&mut self) -> Result<Option<u64>, MatroskaError> {
        let first = *self.data.get(self.pos).ok_or(MatroskaError::NeedMoreData)?;
        let length = first.leading_zeros() as usize + 1;
        if length > 8 {
            return Err(MatroskaError::Invalid("size vint longer than 8 bytes"));
        }
        let end = self.pos + length;
        if end > self.data.len() {
            return Err(MatroskaError::NeedMoreData);
        }
        let raw = self.data[self.pos..end].iter().fold(0u64, |acc, &byte| acc << 8 | byte as u64);
        self.pos = end;
        let mask = (1u64 << (7 * length)) - 1;
        let value = raw & mask;
        Ok(if value == mask { None } else { Some(value) })
    }

    fn read_element(&mut self) -> Result<(u32, Option<u64>), MatroskaError> {
        let id = self.read_id()?;
        let size = self.read_size()?;
        Ok((id, size))
    }

    /// Borrow the next `size` bytes as an element payload.
    fn take(&mut self, size: u64) -> Result<&'a [u8], MatroskaError> {
        let size = usize::try_from(size).map_err(|_| MatroskaError::NeedMoreData)?;
        let end = self.pos.checked_add(size).ok_or(MatroskaError::NeedMoreData)?;
        if end > self.data.len() {
            return Err(MatroskaError::NeedMoreData);
        }
        let payload = &self.data[self.pos..end];
        self.pos = end;
        Ok(payload)
    }

    fn skip(&mut self, size: u64) -> Result<(), MatroskaError> {
        self.take(size).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size_of(bytes: &[u8]) -> Result<Option<u64>, MatroskaError> {
        Reader::new(bytes).read_size()
    }

    #[test]
    fn vint_sizes_from_one_to_eight_bytes() {
        assert_eq!(size_of(&[0x81]), Ok(Some(1)));
        assert_eq!(size_of(&[0xFE]), Ok(Some(0x7E)));
        assert_eq!(size_of(&[0x40, 0x02]), Ok(Some(2)));
        assert_eq!(size_of(&[0x21, 0x23, 0x45]), Ok(Some(0x012345)));
        assert_eq!(size_of(&[0x10, 0x20, 0x00, 0x40]), Ok(Some(0x200040)));
        assert_eq!(size_of(&[0x08, 0, 0, 0, 5]), Ok(Some(5)));
        assert_eq!(size_of(&[0x04, 0, 0, 0, 0, 6]), Ok(Some(6)));
        assert_eq!(size_of(&[0x02, 0, 0, 0, 0, 0, 7]), Ok(Some(7)));
        assert_eq!(size_of(&[0x01, 0, 0, 0, 0, 0, 0, 8]), Ok(Some(8)));
    }

    #[test]
    fn vint_unknown_size_marker_at_every_length() {
        assert_eq!(size_of(&[0xFF]), Ok(None));
        assert_eq!(size_of(&[0x7F, 0xFF]), Ok(None));
        assert_eq!(size_of(&[0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), Ok(None));
        // one bit shy of the marker is a huge but *known* size
        assert_eq!(size_of(&[0x7F, 0xFE]), Ok(Some(0x3FFE)));
    }

    #[test]
    fn vint_truncation_and_garbage() {
        assert_eq!(size_of(&[]), Err(MatroskaError::NeedMoreData));
        assert_eq!(size_of(&[0x40]), Err(MatroskaError::NeedMoreData));
        assert_eq!(size_of(&[0x01, 0, 0]), Err(MatroskaError::NeedMoreData));
        // 0x00 first byte would need a 9+ byte vint: invalid, not "more data"
        assert_eq!(size_of(&[0x00, 1, 2, 3, 4, 5, 6, 7, 8]), Err(MatroskaError::Invalid("size vint longer than 8 bytes")));
    }

    #[test]
    fn element_ids_keep_their_descriptor_bits() {
        let mut reader = Reader::new(&[0x1A, 0x45, 0xDF, 0xA3, 0xAE, 0x42, 0x82]);
        assert_eq!(reader.read_id(), Ok(ID_EBML));
        assert_eq!(reader.read_id(), Ok(ID_TRACK_ENTRY));
        assert_eq!(reader.read_id(), Ok(ID_DOCTYPE));
        // ids are capped at 4 bytes even though sizes may run to 8
        assert_eq!(
            Reader::new(&[0x08, 0, 0, 0, 0]).read_id(),
            Err(MatroskaError::Invalid("element id longer than 4 bytes"))
        );
    }

    /// ffmpeg does not yet write LanguageBCP47, so the preference order is
    /// pinned with a synthesized TrackEntry rather than a fixture.
    #[test]
    fn bcp47_language_overrides_legacy_language() {
        let mut entry = Vec::new();
        entry.extend_from_slice(&[0xD7, 0x81, 3]); // TrackNumber 3
        entry.extend_from_slice(&[0x83, 0x81, 17]); // TrackType subtitle
        entry.extend_from_slice(&[0x22, 0xB5, 0x9C, 0x83]); // Language "jpn"
        entry.extend_from_slice(b"jpn");
        entry.extend_from_slice(&[0x22, 0xB5, 0x9D, 0x82]); // LanguageBCP47 "ja"
        entry.extend_from_slice(b"ja");
        let track = parse_track_entry(&entry).unwrap();
        assert_eq!(track.language, "ja");
        assert_eq!(track.kind, TrackKind::Subtitle);
        assert_eq!(track.number, 3);
    }

    #[test]
    fn language_defaults_to_eng_when_absent() {
        let entry = [0xD7, 0x81, 1, 0x83, 0x81, 2];
        let track = parse_track_entry(&entry).unwrap();
        assert_eq!(track.language, "eng");
        assert_eq!(track.kind, TrackKind::Audio);
        assert!(track.default, "FlagDefault defaults to set per spec");
        assert!(!track.forced);
    }

    #[test]
    fn non_matroska_bytes_are_rejected_not_retried() {
        assert_eq!(parse_matroska_head(b"junk not ebml"), Err(MatroskaError::NotMatroska));
        assert_eq!(parse_matroska_head(&[]), Err(MatroskaError::NeedMoreData));
    }
}
