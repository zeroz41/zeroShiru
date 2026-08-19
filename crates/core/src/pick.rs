//! Episode picking for season packs: which file of a pack the player actually gets.
//!
//! The parser is injected so callers can supply their own, but nobody has to —
//! `pick_pack` reads names with the shared `shiru_media::filename` recognizer, so
//! picking is one call with no JS, no WASM parser and no host round trip.

use shiru_media::{is_video_path, parse_filename};
use std::convert::Infallible;

/// What the injected parser said about one file name. `episode_numbers` holds every
/// finite number the name answers to ("01-12" parses to [1, 12]); `is_extra` is the
/// anitomy anime_type flag (NCOP/NCED/OVA/special).
#[derive(Debug, Clone, Default)]
pub struct ParsedName {
    pub episode_numbers: Vec<f64>,
    pub is_extra: bool,
}

/// The release provably does not contain the requested episode: every video file
/// parsed to an episode number and none of them covers it. Raised instead of
/// guessing, because the guess used to be "largest file" — asking a 459-516 pack
/// for episode 23 played episode 475.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
#[error("This release holds {}, not episode {episode}. Pick a release that has it.", span_text(*.first, *.last))]
pub struct EpisodeNotInPack {
    pub episode: f64,
    pub first: f64,
    pub last: f64,
}

fn span_text(first: f64, last: f64) -> String {
    if first == last {
        format!("episode {first}")
    } else {
        format!("episodes {first}-{last}")
    }
}

/// Whether a file's episode numbers cover the requested episode. More than one
/// number means a multi-episode file, which counts as a range containing
/// everything between.
fn matches_episode(numbers: &[f64], episode: f64) -> Option<Match> {
    match numbers {
        [] => None,
        [only] => (*only == episode).then_some(Match::Exact),
        many => {
            let min = many.iter().cloned().fold(f64::INFINITY, f64::min);
            let max = many.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
            (min <= episode && episode <= max).then_some(Match::Range)
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Match {
    Exact,
    Range,
}

/// Picks the requested episode out of a pack. `files` are (path, size); `parse`
/// receives the video files' bare names in order and answers with one ParsedName
/// per name (None per entry = that name failed to parse; Err = the parser broke).
/// Returns the index into `files` of the pick, or None for an empty list.
pub fn pick_episode_file<E>(
    files: &[(String, u64)],
    episode: f64,
    parse: impl FnOnce(&[String]) -> Result<Vec<Option<ParsedName>>, E>,
) -> Result<Option<usize>, EpisodeNotInPack> {
    let video_indices: Vec<usize> =
        (0..files.len()).filter(|&index| is_video_path(&files[index].0)).collect();
    if video_indices.len() <= 1 {
        return Ok(video_indices.first().copied().or(if files.is_empty() { None } else { Some(0) }));
    }

    let names: Vec<String> = video_indices
        .iter()
        .map(|&index| files[index].0.rsplit('/').next().unwrap_or(&files[index].0).to_string())
        .collect();

    let mut candidates: Vec<usize> = video_indices.clone();
    if let Ok(parsed) = parse(&names) {
        // rank 0: episode, exact. 1: episode, range. 2: extra, exact. 3: extra, range.
        // First file in torrent order wins within a rank, so duplicate resolutions stay stable.
        let mut ranks: [Option<usize>; 4] = [None; 4];
        let mut held: Vec<f64> = Vec::new(); // every episode number the pack's files answer to
        let mut unnumbered = 0usize;
        for (position, entry) in parsed.iter().enumerate() {
            let numbers = entry.as_ref().map(|p| p.episode_numbers.as_slice()).unwrap_or(&[]);
            if numbers.is_empty() {
                unnumbered += 1;
            } else {
                held.extend_from_slice(numbers);
            }
            let Some(matched) = matches_episode(numbers, episode) else { continue };
            let is_extra = entry.as_ref().map(|p| p.is_extra).unwrap_or(false);
            let rank = (if is_extra { 2 } else { 0 }) + (if matched == Match::Range { 1 } else { 0 });
            ranks[rank].get_or_insert(position);
        }
        if let Some(position) = ranks.iter().flatten().next() {
            return Ok(Some(video_indices[*position]));
        }
        let episodes: Vec<usize> = (0..video_indices.len())
            .filter(|&position| !parsed.get(position).and_then(|p| p.as_ref()).map(|p| p.is_extra).unwrap_or(false))
            .collect();
        // every video answered with a number and none covers the episode: the release
        // cannot serve this request, and no fallback can make it
        if parsed.len() == video_indices.len() && unnumbered == 0 && !held.is_empty() {
            // the reported span reads off the real episodes where any exist, so an NCOP1
            // in the pack does not make a 459-516 release claim to start at episode 1
            let span: Vec<f64> = if episodes.is_empty() {
                held
            } else {
                episodes
                    .iter()
                    .flat_map(|&position| {
                        parsed[position].as_ref().map(|p| p.episode_numbers.clone()).unwrap_or_default()
                    })
                    .collect()
            };
            let first = span.iter().cloned().fold(f64::INFINITY, f64::min);
            let last = span.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
            return Err(EpisodeNotInPack { episode, first, last });
        }
        // nothing matched but nothing is proven either: never fall back onto an extra
        // while real episodes exist
        if !episodes.is_empty() {
            candidates = episodes.into_iter().map(|position| video_indices[position]).collect();
        }
    }
    // best guess: the largest episode-like video (first on ties, like the JS stable sort)
    // max_by keeps the LATER element on Equal (core::cmp::max_by returns v2), so ties
    // are broken to Less, which keeps the earlier candidate — the JS stable sort's pick
    Ok(candidates
        .into_iter()
        .max_by(|&a, &b| files[a].1.cmp(&files[b].1).then(std::cmp::Ordering::Less)))
}

/// Picks the episode for a debrid resolve, refusing only when refusing costs
/// nothing: when every file reaches the player anyway (no windowing), handing the
/// whole release over lets the side that knows season offsets decide.
/// `Ok(None)` hands the choice to the player.
pub fn pick_pack_file<E>(
    files: &[(String, u64)],
    episode: f64,
    parse: impl FnOnce(&[String]) -> Result<Vec<Option<ParsedName>>, E>,
    max_files: usize,
) -> Result<Option<usize>, EpisodeNotInPack> {
    match pick_episode_file(files, episode, parse) {
        Ok(pick) => Ok(pick),
        Err(error) => {
            if files.len() <= max_files {
                Ok(None)
            } else {
                Err(error)
            }
        }
    }
}

/// Reads names with the shared recognizer. The picker's own contract applies: a
/// name the recognizer cannot number comes back as `None`, which keeps a
/// mismatch unproven and the fallbacks in play.
pub fn parse_names(names: &[String]) -> Result<Vec<Option<ParsedName>>, Infallible> {
    Ok(names
        .iter()
        .map(|name| {
            let parsed = parse_filename(name);
            if parsed.episode_numbers.is_empty() && parsed.kind.is_none() {
                return None;
            }
            let is_extra = parsed.is_extra();
            Some(ParsedName { episode_numbers: parsed.episode_numbers, is_extra })
        })
        .collect())
}

/// Picks the episode out of a pack using the shared recognizer — the call every
/// host makes. `Ok(None)` hands the choice to the player.
pub fn pick_pack(
    files: &[(String, u64)],
    episode: f64,
    max_files: usize,
) -> Result<Option<usize>, EpisodeNotInPack> {
    pick_pack_file(files, episode, parse_names, max_files)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok_parse(entries: Vec<Option<ParsedName>>) -> impl FnOnce(&[String]) -> Result<Vec<Option<ParsedName>>, ()> {
        move |_names| Ok(entries)
    }

    fn numbered(numbers: &[f64]) -> Option<ParsedName> {
        Some(ParsedName { episode_numbers: numbers.to_vec(), is_extra: false })
    }

    fn extra(numbers: &[f64]) -> Option<ParsedName> {
        Some(ParsedName { episode_numbers: numbers.to_vec(), is_extra: true })
    }

    fn pack(range: std::ops::RangeInclusive<u32>) -> Vec<(String, u64)> {
        range.map(|n| (format!("/Episode {n:03}.mkv"), 1000)).collect()
    }

    #[test]
    fn a_large_pack_yields_exactly_the_requested_episode() {
        let files = pack(1..=200);
        let parsed = (1..=200).map(|n| numbered(&[n as f64])).collect();
        let pick = pick_episode_file(&files, 150.0, ok_parse(parsed)).unwrap();
        assert_eq!(pick, Some(149));
    }

    #[test]
    fn creditless_openings_never_shadow_the_real_episode() {
        // NCOP1 parses as episode 1 with an anime_type — the real episode 1 must win
        let files = vec![("/NCOP1.mkv".to_string(), 5000), ("/Episode 01.mkv".to_string(), 1000)];
        let parsed = vec![extra(&[1.0]), numbered(&[1.0])];
        assert_eq!(pick_episode_file(&files, 1.0, ok_parse(parsed)).unwrap(), Some(1));
    }

    #[test]
    fn a_pack_of_only_extras_can_still_serve_them_by_number() {
        let files = vec![("/NCOP1.mkv".to_string(), 1), ("/NCOP2.mkv".to_string(), 1)];
        let parsed = vec![extra(&[1.0]), extra(&[2.0])];
        assert_eq!(pick_episode_file(&files, 2.0, ok_parse(parsed)).unwrap(), Some(1));
    }

    #[test]
    fn a_double_episode_file_matches_both_of_its_episodes() {
        let files = vec![("/Ep 01-02.mkv".to_string(), 1), ("/Ep 03.mkv".to_string(), 1)];
        let parsed = vec![numbered(&[1.0, 2.0]), numbered(&[3.0])];
        assert_eq!(pick_episode_file(&files, 2.0, ok_parse(parsed.clone())).unwrap(), Some(0));
        assert_eq!(pick_episode_file(&files, 1.0, ok_parse(parsed)).unwrap(), Some(0));
    }

    #[test]
    fn an_exact_single_file_beats_a_batch_that_merely_contains_the_episode() {
        let files = vec![("/Batch 01-12.mkv".to_string(), 1), ("/Ep 05.mkv".to_string(), 1)];
        let parsed = vec![numbered(&[1.0, 12.0]), numbered(&[5.0])];
        assert_eq!(pick_episode_file(&files, 5.0, ok_parse(parsed)).unwrap(), Some(1));
    }

    #[test]
    fn the_first_match_in_torrent_order_wins_when_a_pack_ships_duplicates() {
        let files = vec![("/Ep 05 (1080p).mkv".to_string(), 1), ("/Ep 05 (720p).mkv".to_string(), 1)];
        let parsed = vec![numbered(&[5.0]), numbered(&[5.0])];
        assert_eq!(pick_episode_file(&files, 5.0, ok_parse(parsed)).unwrap(), Some(0));
    }

    #[test]
    fn junk_beside_the_videos_never_comes_back_as_the_pick() {
        let files = vec![
            ("/readme.nfo".to_string(), 900_000),
            ("/subs/ep1.ass".to_string(), 900_000),
            ("/Episode 01.mkv".to_string(), 10),
        ];
        // single video: parsing is skipped entirely
        assert_eq!(pick_episode_file(&files, 1.0, ok_parse(vec![])).unwrap(), Some(2));
    }

    #[test]
    fn a_release_with_no_videos_falls_back_to_the_first_file() {
        let files = vec![("/readme.nfo".to_string(), 1)];
        assert_eq!(pick_episode_file(&files, 1.0, ok_parse(vec![])).unwrap(), Some(0));
        let empty: Vec<(String, u64)> = vec![];
        assert_eq!(pick_episode_file(&empty, 1.0, ok_parse(vec![])).unwrap(), None);
    }

    #[test]
    fn a_partial_pack_provably_lacking_the_episode_refuses_instead_of_guessing() {
        let files = pack(459..=516);
        let parsed = (459..=516).map(|n| numbered(&[n as f64])).collect();
        let error = pick_episode_file(&files, 23.0, ok_parse(parsed)).unwrap_err();
        assert_eq!(error.first, 459.0);
        assert_eq!(error.last, 516.0);
    }

    #[test]
    fn extras_do_not_stretch_the_span_the_error_reports() {
        let mut files = pack(459..=516);
        files.push(("/NCOP1.mkv".to_string(), 1));
        let mut parsed: Vec<Option<ParsedName>> = (459..=516).map(|n| numbered(&[n as f64])).collect();
        parsed.push(extra(&[1.0]));
        let error = pick_episode_file(&files, 23.0, ok_parse(parsed)).unwrap_err();
        assert_eq!(error.first, 459.0, "an NCOP1 must not make the span start at 1");
    }

    #[test]
    fn an_unproven_mismatch_falls_back_to_the_largest_real_episode_never_an_extra() {
        let files = vec![
            ("/NCOP1.mkv".to_string(), 9000),
            ("/Something 01.mkv".to_string(), 500),
            ("/Something else.mkv".to_string(), 700),
        ];
        // one file unnumbered → nothing is proven, largest non-extra wins
        let parsed = vec![extra(&[1.0]), numbered(&[1.0]), Some(ParsedName::default())];
        assert_eq!(pick_episode_file(&files, 5.0, ok_parse(parsed)).unwrap(), Some(2));
    }

    #[test]
    fn a_parser_that_throws_still_yields_a_playable_fallback() {
        let files = vec![("/a.mkv".to_string(), 1), ("/b.mkv".to_string(), 2)];
        let broken = |_names: &[String]| -> Result<Vec<Option<ParsedName>>, ()> { Err(()) };
        assert_eq!(pick_episode_file(&files, 1.0, broken).unwrap(), Some(1));
    }

    #[test]
    fn the_largest_file_fallback_keeps_torrent_order_on_ties() {
        let files = vec![("/a.mkv".to_string(), 5), ("/b.mkv".to_string(), 5), ("/c.mkv".to_string(), 5)];
        let unparsed = vec![Some(ParsedName::default()), Some(ParsedName::default()), Some(ParsedName::default())];
        assert_eq!(pick_episode_file(&files, 1.0, ok_parse(unparsed)).unwrap(), Some(0));
    }

    #[test]
    fn episode_12_does_not_match_a_12_5_special_and_12_5_can_still_be_asked_for() {
        let files = vec![("/Ep 12.5.mkv".to_string(), 1), ("/Ep 12.mkv".to_string(), 1)];
        let parsed = vec![numbered(&[12.5]), numbered(&[12.0])];
        assert_eq!(pick_episode_file(&files, 12.0, ok_parse(parsed.clone())).unwrap(), Some(1));
        assert_eq!(pick_episode_file(&files, 12.5, ok_parse(parsed)).unwrap(), Some(0));
    }

    #[test]
    fn a_small_release_the_picker_cannot_match_is_handed_to_the_player_instead_of_refused() {
        // split cour numbered 13-24 asked for episode 1: provably absent by release
        // numbering, but the player's season offsets may still find it
        let files = pack(13..=24);
        let parsed: Vec<_> = (13..=24).map(|n| numbered(&[n as f64])).collect();
        assert_eq!(pick_pack_file(&files, 1.0, ok_parse(parsed.clone()), usize::MAX).unwrap(), None);
        // too big to hand over whole: still refused rather than windowed blindly
        assert!(pick_pack_file(&files, 1.0, ok_parse(parsed), 5).is_err());
    }
}

/// The picker driven by the real recognizer rather than injected parse results:
/// every case here is a way playback silently plays the wrong episode when the
/// recognizer regresses. These mirror test/unit/debrid/pick.test.js, which drove
/// the same cases through the JS anitomy build before picking moved to Rust.
#[cfg(test)]
mod real_names {
    use super::*;

    fn file(path: &str, size: u64) -> (String, u64) {
        (path.to_string(), size)
    }

    fn pick(files: &[(String, u64)], episode: f64) -> Option<&str> {
        pick_episode_file(files, episode, parse_names).unwrap().map(|index| files[index].0.as_str())
    }

    #[test]
    fn a_large_pack_yields_exactly_the_requested_episode() {
        let files: Vec<_> = (1..=150)
            .map(|n| file(&format!("/Pack/[Group] Show - {n:03} [1080p].mkv"), 1000))
            .collect();
        assert_eq!(pick(&files, 1.0), Some("/Pack/[Group] Show - 001 [1080p].mkv"));
        assert_eq!(pick(&files, 100.0), Some("/Pack/[Group] Show - 100 [1080p].mkv"));
        assert_eq!(pick(&files, 150.0), Some("/Pack/[Group] Show - 150 [1080p].mkv"));
    }

    #[test]
    fn padding_never_matters() {
        for name in ["/Show - 05.mkv", "/Show - 005.mkv", "/Show S01E05.mkv", "/Show.S01.E05.1080p.mkv"] {
            let files = vec![file("/Show - 04.mkv", 1000), file(name, 1000), file("/Show - 06.mkv", 1000)];
            assert_eq!(pick(&files, 5.0), Some(name), "{name}");
        }
    }

    #[test]
    fn a_half_episode_is_not_the_episode_before_it() {
        let files = vec![file("/Show - 12.mkv", 1), file("/Show - 12.5.mkv", 1), file("/Show - 13.mkv", 1)];
        assert_eq!(pick(&files, 12.0), Some("/Show - 12.mkv"));
        assert_eq!(pick(&files, 12.5), Some("/Show - 12.5.mkv"));
    }

    #[test]
    fn a_v2_release_still_matches_its_episode_number() {
        let files = vec![file("/Show - 04.mkv", 1), file("/Show - 05v2.mkv", 1), file("/Show - 06.mkv", 1)];
        assert_eq!(pick(&files, 5.0), Some("/Show - 05v2.mkv"));
    }

    #[test]
    fn creditless_openings_never_shadow_the_real_episode() {
        let files = vec![
            file("/Extras/[Group] Show - NCOP1.mkv", 300),
            file("/Extras/[Group] Show - NCED1.mkv", 300),
            file("/[Group] Show - 01.mkv", 900),
            file("/[Group] Show - 02.mkv", 900),
        ];
        assert_eq!(pick(&files, 1.0), Some("/[Group] Show - 01.mkv"));
        assert_eq!(pick(&files, 2.0), Some("/[Group] Show - 02.mkv"));
    }

    #[test]
    fn specials_and_ovas_do_not_shadow_same_numbered_episodes() {
        let files = vec![
            file("/Specials/[Group] Show - SP01.mkv", 1),
            file("/Specials/[Group] Show - OVA 02.mkv", 1),
            file("/[Group] Show - 01.mkv", 1),
            file("/[Group] Show - 02.mkv", 1),
        ];
        assert_eq!(pick(&files, 1.0), Some("/[Group] Show - 01.mkv"));
        assert_eq!(pick(&files, 2.0), Some("/[Group] Show - 02.mkv"));
    }

    #[test]
    fn a_pack_of_only_extras_can_still_serve_them_by_number() {
        let files = vec![file("/[Group] Show - NCOP1.mkv", 1), file("/[Group] Show - NCOP2.mkv", 1)];
        assert_eq!(pick(&files, 2.0), Some("/[Group] Show - NCOP2.mkv"));
    }

    #[test]
    fn a_batch_file_covers_the_episodes_it_spans() {
        let files = vec![file("/[Group] Show - 01-12 [Batch].mkv", 5000), file("/[Group] Show - 13.mkv", 900)];
        assert_eq!(pick(&files, 5.0), Some("/[Group] Show - 01-12 [Batch].mkv"));
        assert_eq!(pick(&files, 13.0), Some("/[Group] Show - 13.mkv"));
        // and a dedicated file beats the batch around it
        let with_single = vec![
            file("/[Group] Show - 01-12 [Batch].mkv", 5000),
            file("/[Group] Show - 05.mkv", 900),
        ];
        assert_eq!(pick(&with_single, 5.0), Some("/[Group] Show - 05.mkv"));
    }

    #[test]
    fn the_first_match_in_torrent_order_wins_when_a_pack_ships_duplicates() {
        let files = vec![file("/1080p/Show - 05.mkv", 2000), file("/720p/Show - 05.mkv", 900)];
        assert_eq!(pick(&files, 5.0), Some("/1080p/Show - 05.mkv"));
    }

    #[test]
    fn subtitles_and_junk_beside_the_videos_are_never_the_pick() {
        let files = vec![
            file("/Show - 05.ass", 30),
            file("/readme.txt", 999_999),
            file("/Show - 05.mkv", 900),
        ];
        assert_eq!(pick(&files, 5.0), Some("/Show - 05.mkv"));
    }

    // the reported bug: a 459-516 One Piece pack asked for episode 23 played
    // episode 475 - the largest file - because "no match" fell back to "largest
    // video". This is the real file list of that release, scraped from the tracker.
    #[test]
    fn a_partial_pack_asked_for_an_episode_it_lacks_refuses_instead_of_guessing() {
        let fixture = include_str!("../../../test/fixtures/fr-one-piece-459-516.json");
        let entries: Vec<serde_json::Value> = serde_json::from_str(fixture).unwrap();
        let files: Vec<(String, u64)> = entries
            .iter()
            .map(|entry| {
                (
                    entry["path"].as_str().unwrap().to_string(),
                    entry["size"].as_u64().unwrap(),
                )
            })
            .collect();

        let error = pick_episode_file(&files, 23.0, parse_names).unwrap_err();
        assert_eq!(error.first, 459.0, "the message must say what the release really holds");
        assert_eq!(error.last, 516.0);
        assert!(error.to_string().contains("459-516"));
        assert!(error.to_string().contains("episode 23"));

        // and the same pack still serves what it does hold
        assert_eq!(pick(&files, 475.0), Some("/One Piece - 475 v2 [F-R][b1929031].mkv"));
        assert_eq!(pick(&files, 459.0), Some("/One Piece - 459 v2 [F-R][9d4e6bc5].mkv"));
        assert_eq!(pick(&files, 516.0), Some("/One Piece - 516 v2 [F-R][54ce21cf].mkv"));
    }

    #[test]
    fn extras_in_a_partial_pack_do_not_stretch_the_span_the_error_reports() {
        let files = vec![
            file("/Extras/Show - NCOP1.mkv", 5000),
            file("/Show - 40.mkv", 900),
            file("/Show - 41.mkv", 950),
        ];
        let error = pick_episode_file(&files, 3.0, parse_names).unwrap_err();
        assert_eq!(error.first, 40.0, "the NCOP parsing as episode 1 must not make the pack claim to start at 1");
        assert_eq!(error.last, 41.0);
    }

    #[test]
    fn an_unproven_mismatch_falls_back_to_the_largest_real_episode_never_an_extra() {
        let files = vec![
            file("/Extras/Show - NCOP1.mkv", 5000),
            file("/Show - 01.mkv", 900),
            file("/Show - 02.mkv", 950),
            file("/Show - Unnumbered Special.mkv", 800),
        ];
        assert_eq!(pick(&files, 40.0), Some("/Show - 02.mkv"));
    }

    #[test]
    fn a_small_release_the_picker_cannot_match_is_handed_to_the_player() {
        let files: Vec<_> = (13..=24).map(|n| file(&format!("/[Group] Show - {n}.mkv"), 1000)).collect();
        assert_eq!(pick_pack(&files, 1.0, 12).unwrap(), None, "no pick means the player decides");
        assert!(pick_episode_file(&files, 1.0, parse_names).is_err(), "the strict picker still says what it knows");
    }

    #[test]
    fn a_release_too_big_to_hand_over_whole_is_still_refused() {
        let files: Vec<_> = (459..=516).map(|n| file(&format!("/One Piece - {n}.mkv"), 1000)).collect();
        assert!(pick_pack(&files, 23.0, 12).is_err(), "windowing this would play an arbitrary episode");
        assert_eq!(pick_pack(&files, 475.0, 12).unwrap(), Some(16));
    }
}
