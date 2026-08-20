//! Anime release filename recognition: episode numbers and release kind, read off
//! a file name without a network call or a WASM blob.
//!
//! This replaces the JS `anitomyscript` dependency on the path that matters most —
//! deciding which file of a season pack actually plays. It is deliberately *not* a
//! full anitomy: it answers the two questions the picker asks (which episodes does
//! this name claim, and is it an extra rather than an episode) and answers
//! "no idea" everywhere else, because the picker's fallbacks are safe and a
//! confidently wrong number plays the wrong episode.
//!
//! The rule throughout: a number is an episode only where a release name would put
//! one. Anything else — resolutions, CRCs, years, codec tags, audio layouts — stays
//! unread rather than being guessed at.

use serde::{Deserialize, Serialize};

/// The kind of release a name describes, when it says so. Mirrors the subset of
/// anitomy's `anime_type` the picker cares about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ReleaseKind {
    /// Creditless opening/ending (NCOP, NCED, "clean opening").
    Creditless,
    /// Opening or ending sequence.
    Theme,
    Ova,
    Ona,
    Special,
    /// Preview, PV, CM, trailer, menu, omake, bonus, extra.
    Promo,
}

impl ReleaseKind {
    /// Whether a file of this kind is an extra rather than an episode of the show.
    /// Everything this enum can hold is; the method exists so callers read as
    /// intent rather than as "has a kind".
    pub fn is_extra(self) -> bool {
        true
    }
}

/// What a file name says about itself.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ParsedFilename {
    /// Every episode number the name answers to. One number is a single episode,
    /// two are the ends of a range ("01-12" -> [1, 12]) which counts as covering
    /// everything between. Empty when the name carries no readable number.
    pub episode_numbers: Vec<f64>,
    /// The release kind, when the name names one.
    pub kind: Option<ReleaseKind>,
    /// Release version, from a `v2` suffix.
    pub version: Option<u32>,
}

impl ParsedFilename {
    /// Whether this file is an extra rather than an episode.
    pub fn is_extra(&self) -> bool {
        self.kind.is_some_and(ReleaseKind::is_extra)
    }
}

/// Reads one file name (a bare name or a full path — only the last segment is read).
pub fn parse_filename(name: &str) -> ParsedFilename {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let stem = strip_extension(base);
    let tokens = tokenize(stem);
    let kind = release_kind(&tokens);
    let (episode_numbers, version) = episode_numbers(&tokens);
    ParsedFilename { episode_numbers, kind, version }
}

/// Reads a batch of names, in order.
pub fn parse_filenames<S: AsRef<str>>(names: &[S]) -> Vec<ParsedFilename> {
    names.iter().map(|name| parse_filename(name.as_ref())).collect()
}

/// Drops a trailing extension, but only one that looks like an extension: a short
/// alphanumeric tail. "Show - 12.5" keeps its .5, "Show - 12.mkv" loses its .mkv.
fn strip_extension(base: &str) -> &str {
    let Some((stem, ext)) = base.rsplit_once('.') else { return base };
    let plausible = !ext.is_empty()
        && ext.len() <= 4
        && ext.chars().all(|c| c.is_ascii_alphanumeric())
        && ext.chars().any(|c| c.is_ascii_alphabetic());
    if plausible {
        stem
    } else {
        base
    }
}

#[derive(Debug, Clone, PartialEq)]
struct Token {
    text: String,
    /// Inside [], () or {} — where group names, CRCs and quality tags live.
    enclosed: bool,
    /// A lone `-`, which is what separates a title from its episode number.
    separator: bool,
}

/// Splits a name into bracket groups and free-text words. Delimiters are space,
/// underscore, plus and dot — except a dot between two digits, which is a decimal
/// point in an episode number like `12.5`.
fn tokenize(stem: &str) -> Vec<Token> {
    let chars: Vec<char> = stem.chars().collect();
    let mut tokens = Vec::new();
    let mut word = String::new();
    let mut index = 0;

    let flush = |word: &mut String, tokens: &mut Vec<Token>| {
        if word.is_empty() {
            return;
        }
        // a trailing/leading dash is a separator: "Show - 05" and "Show-05" alike
        let text = word.trim_matches('-').to_string();
        let was_dash_only = text.is_empty();
        if was_dash_only {
            tokens.push(Token { text: "-".into(), enclosed: false, separator: true });
        } else {
            tokens.push(Token { text, enclosed: false, separator: false });
        }
        word.clear();
    };

    while index < chars.len() {
        let c = chars[index];
        let closing = match c {
            '[' => Some(']'),
            '(' => Some(')'),
            '{' => Some('}'),
            _ => None,
        };
        if let Some(close) = closing {
            flush(&mut word, &mut tokens);
            let start = index + 1;
            let mut end = start;
            while end < chars.len() && chars[end] != close {
                end += 1;
            }
            let text: String = chars[start..end].iter().collect();
            if !text.trim().is_empty() {
                tokens.push(Token { text: text.trim().to_string(), enclosed: true, separator: false });
            }
            index = end + 1;
            continue;
        }
        let delimiter = match c {
            ' ' | '_' | '+' => true,
            // a dot is a decimal point only between a number and a short fraction:
            // "12.5" is episode 12.5, while "E05.1080p" is two dot-separated words
            '.' => !is_decimal_point(&word, &chars, index),
            _ => false,
        };
        if delimiter {
            flush(&mut word, &mut tokens);
        } else {
            word.push(c);
        }
        index += 1;
    }
    flush(&mut word, &mut tokens);
    tokens
}

/// Whether the dot at `index` joins a number to its fraction rather than
/// separating two words. Both sides have to look the part: digits only before it,
/// and one or two digits after it that end the word.
fn is_decimal_point(word: &str, chars: &[char], index: usize) -> bool {
    if word.is_empty() || !word.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let fraction = chars[index + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
    let terminated = chars
        .get(index + 1 + fraction)
        .is_none_or(|next| !next.is_ascii_alphanumeric());
    (1..=2).contains(&fraction) && terminated
}

/// The release kind a name declares, if any. Read from free text and brackets
/// alike: plenty of releases put `[NCOP]` in a tag.
fn release_kind(tokens: &[Token]) -> Option<ReleaseKind> {
    let mut found = None;
    for token in tokens {
        let word = strip_trailing_number(&token.text).0.to_ascii_uppercase();
        let kind = match word.as_str() {
            "NCOP" | "NCED" | "CREDITLESS" | "NC" => Some(ReleaseKind::Creditless),
            "OP" | "ED" | "OPENING" | "ENDING" => Some(ReleaseKind::Theme),
            "OVA" | "OAD" => Some(ReleaseKind::Ova),
            "ONA" => Some(ReleaseKind::Ona),
            "SP" | "SPECIAL" | "SPECIALS" | "OMAKE" => Some(ReleaseKind::Special),
            "PV" | "CM" | "PREVIEW" | "TRAILER" | "MENU" | "BONUS" | "EXTRA" | "EXTRAS" => {
                Some(ReleaseKind::Promo)
            }
            _ => None,
        };
        // "clean opening" and friends: the qualifier makes it creditless
        if let Some(kind) = kind {
            found = Some(match (found, kind) {
                (Some(ReleaseKind::Creditless), _) => ReleaseKind::Creditless,
                (_, kind) => kind,
            });
        }
    }
    found
}

/// Splits a trailing number off a word: "NCOP1" -> ("NCOP", Some(1.0)).
fn strip_trailing_number(text: &str) -> (&str, Option<f64>) {
    let split = text
        .char_indices()
        .rev()
        .take_while(|(_, c)| c.is_ascii_digit() || *c == '.')
        .last()
        .map(|(index, _)| index);
    match split {
        Some(index) if index > 0 => {
            let (word, digits) = text.split_at(index);
            (word, digits.parse().ok())
        }
        _ => (text, None),
    }
}

/// The episode numbers a name claims, and the release version if it carries one.
/// Candidates are read in priority order; the first form that answers wins, so a
/// name saying `S01E05` is never re-read as something else.
fn episode_numbers(tokens: &[Token]) -> (Vec<f64>, Option<u32>) {
    let free: Vec<&Token> = tokens.iter().filter(|token| !token.enclosed).collect();

    if let Some(found) = season_episode(&free) {
        return (found, version_of(tokens));
    }
    if let Some(found) = prefixed_episode(&free) {
        return (found, version_of(tokens));
    }
    if let Some(found) = kind_numbered(&free) {
        return (found, version_of(tokens));
    }
    if let Some(found) = after_separator(&free) {
        return (found, version_of(tokens));
    }
    if let Some(found) = bare_number(&free) {
        return (found, version_of(tokens));
    }
    // last resort: a bracket that holds nothing but a number, as in "Show [05]"
    for token in tokens.iter().filter(|token| token.enclosed) {
        match numeric_token(&token.text) {
            Some(found) if !looks_like_year(&found) => return (found, version_of(tokens)),
            _ => {}
        }
    }
    (Vec::new(), version_of(tokens))
}

/// `S01E05`, `S01E05-E06`, `1x05`.
fn season_episode(tokens: &[&Token]) -> Option<Vec<f64>> {
    for (index, token) in tokens.iter().enumerate() {
        let text = token.text.to_ascii_uppercase();
        if let Some(rest) = text.strip_prefix('S') {
            // S01E05 in one token
            if let Some((_, episodes)) = rest.split_once('E') {
                if let Some(found) = episode_range(episodes) {
                    return Some(found);
                }
            }
            // S01 . E05 as two tokens
            if rest.chars().all(|c| c.is_ascii_digit()) && !rest.is_empty() {
                if let Some(next) = tokens.get(index + 1) {
                    if let Some(found) = next
                        .text
                        .to_ascii_uppercase()
                        .strip_prefix('E')
                        .and_then(episode_range)
                    {
                        return Some(found);
                    }
                }
            }
        }
        // 1x05 — but not 1920x1080, which is a frame size. A season is one or two
        // digits; reading a width as one made every file in a pack claim episode 1080,
        // so the episode being asked for was in none of them and the pack was refused
        if let Some((season, episodes)) = text.split_once('X') {
            if !season.is_empty()
                && season.len() <= 2
                && season.chars().all(|c| c.is_ascii_digit())
                && !episodes.is_empty()
            {
                if let Some(found) = episode_range(episodes) {
                    return Some(found);
                }
            }
        }
    }
    None
}

/// `E05`, `EP05`, `Episode 05`, `EP 05-06`.
fn prefixed_episode(tokens: &[&Token]) -> Option<Vec<f64>> {
    for (index, token) in tokens.iter().enumerate() {
        let text = token.text.to_ascii_uppercase();
        for prefix in ["EPISODE", "EPS", "EP", "E"] {
            let Some(rest) = text.strip_prefix(prefix) else { continue };
            if rest.is_empty() {
                // the number is the next token
                if let Some(found) = tokens.get(index + 1).and_then(|next| numeric_token(&next.text)) {
                    return Some(found);
                }
            } else if let Some(found) = episode_range(rest) {
                return Some(found);
            }
            break; // longest matching prefix only
        }
    }
    None
}

/// `NCOP1`, `SP01`, `OVA 02` — an extra that carries its own number.
fn kind_numbered(tokens: &[&Token]) -> Option<Vec<f64>> {
    for (index, token) in tokens.iter().enumerate() {
        let (word, trailing) = strip_trailing_number(&token.text);
        if release_kind(&[Token { text: word.into(), enclosed: false, separator: false }]).is_none() {
            continue;
        }
        if let Some(number) = trailing {
            return Some(vec![number]);
        }
        if let Some(found) = tokens.get(index + 1).and_then(|next| numeric_token(&next.text)) {
            return Some(found);
        }
    }
    None
}

/// The fansub form: `Title - 05`, `Title - 01-12`, `Title - 05v2`.
fn after_separator(tokens: &[&Token]) -> Option<Vec<f64>> {
    for (index, token) in tokens.iter().enumerate() {
        if !token.separator {
            continue;
        }
        if let Some(found) = tokens.get(index + 1).and_then(|next| numeric_token(&next.text)) {
            return Some(found);
        }
    }
    None
}

/// A standalone number somewhere in the name, taking the last one — release names
/// put the title first. Years and other non-episode numbers are skipped.
fn bare_number(tokens: &[&Token]) -> Option<Vec<f64>> {
    tokens
        .iter()
        .enumerate()
        .rev()
        .find_map(|(index, token)| {
            let found = numeric_token(&token.text)?;
            let previous = index.checked_sub(1).and_then(|before| tokens.get(before));
            (!looks_like_year(&found) && !follows_audio_tag(previous)).then_some(found)
        })
}

/// A four-digit number on its own is a year far more often than an episode; the
/// dash-delimited and prefixed forms above still read one when a release means it.
fn looks_like_year(numbers: &[f64]) -> bool {
    matches!(numbers, [single] if *single >= 1900.0 && *single <= 2100.0 && single.fract() == 0.0)
}

/// `AAC 5.1` and friends: a decimal after an audio tag is a channel layout.
fn follows_audio_tag(previous: Option<&&Token>) -> bool {
    let Some(token) = previous else { return false };
    let text = token.text.to_ascii_uppercase();
    matches!(text.as_str(), "AAC" | "AC3" | "EAC3" | "DD" | "DDP" | "DTS" | "FLAC" | "TRUEHD" | "OPUS")
}

/// A token that is nothing but an episode number (or range), with an optional
/// `v2` version suffix: "05", "005", "12.5", "01-12", "05v2".
fn numeric_token(text: &str) -> Option<Vec<f64>> {
    let trimmed = strip_version(text).0;
    episode_range(trimmed)
}

/// Splits a `v2` suffix off a number token.
fn strip_version(text: &str) -> (&str, Option<u32>) {
    if let Some((number, version)) = text.rsplit_once(['v', 'V']) {
        if !number.is_empty()
            && number.chars().all(|c| c.is_ascii_digit() || c == '.' || c == '-')
            && !version.is_empty()
            && version.chars().all(|c| c.is_ascii_digit())
        {
            return (number, version.parse().ok());
        }
    }
    (text, None)
}

/// Reads "05" as [5] and "01-12" as [1, 12]. Anything that is not purely a number
/// or a number range reads as nothing.
fn episode_range(text: &str) -> Option<Vec<f64>> {
    if text.is_empty() {
        return None;
    }
    if let Some((first, second)) = text.split_once('-') {
        let (second, _) = strip_version(second);
        let second = second.strip_prefix(['E', 'e']).unwrap_or(second);
        let first = number(first)?;
        // "12-05" counts down rather than spanning, so it names one episode, not a range
        return Some(match number(second) {
            Some(second) if second > first => vec![first, second],
            _ => vec![first],
        });
    }
    Some(vec![number(text)?])
}

/// A plain decimal number, digits only. Leading zeros are fine; anything else is not.
fn number(text: &str) -> Option<f64> {
    if text.is_empty() || !text.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return None;
    }
    let parsed: f64 = text.parse().ok()?;
    parsed.is_finite().then_some(parsed)
}

/// The release version anywhere in the name: `05v2`, `475 v2`.
fn version_of(tokens: &[Token]) -> Option<u32> {
    for token in tokens {
        if let (_, Some(version)) = strip_version(&token.text) {
            return Some(version);
        }
        let text = token.text.to_ascii_lowercase();
        if let Some(digits) = text.strip_prefix('v') {
            if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
                return digits.parse().ok();
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn episodes(name: &str) -> Vec<f64> {
        parse_filename(name).episode_numbers
    }

    #[test]
    fn reads_the_fansub_form_whatever_the_padding() {
        for name in ["Show - 5.mkv", "Show - 05.mkv", "Show - 005.mkv"] {
            assert_eq!(episodes(name), vec![5.0], "{name}");
        }
    }

    #[test]
    fn a_frame_size_is_not_a_season_and_an_episode() {
        // `1920x1080` used to read as season 1920 episode 1080, so every file in a pack
        // claimed the same episode, the wanted one was in none of them, and the whole
        // release was refused as not holding it
        for name in [
            "Show.-.05.1920x1080.x264.FLAC.mkv",
            "[Group] Show 05 1280x720 AAC.mkv",
            "Show - 05 [848x480].mkv",
        ] {
            assert_eq!(episodes(name), vec![5.0], "{name}");
        }
        // and the form it was written for still reads
        assert_eq!(episodes("Show 1x05.mkv"), vec![5.0]);
        assert_eq!(episodes("Show 12x05.mkv"), vec![5.0]);
    }

    #[test]
    fn reads_season_and_episode_forms() {
        assert_eq!(episodes("Show S01E05.mkv"), vec![5.0]);
        assert_eq!(episodes("Show.S01.E05.1080p.mkv"), vec![5.0]);
        assert_eq!(episodes("Show 1x05.mkv"), vec![5.0]);
        assert_eq!(episodes("Show EP05.mkv"), vec![5.0]);
        assert_eq!(episodes("Show Episode 5.mkv"), vec![5.0]);
    }

    #[test]
    fn reads_ranges_as_both_ends() {
        assert_eq!(episodes("[Group] Show - 01-02.mkv"), vec![1.0, 2.0]);
        assert_eq!(episodes("[Group] Show - 01-12 [Batch].mkv"), vec![1.0, 12.0]);
        assert_eq!(episodes("Show S01E01-E12.mkv"), vec![1.0, 12.0]);
    }

    #[test]
    fn keeps_decimal_episodes_whole() {
        assert_eq!(episodes("Show - 12.5.mkv"), vec![12.5]);
        assert_eq!(episodes("Show - 12.mkv"), vec![12.0]);
    }

    #[test]
    fn a_version_suffix_never_hides_the_episode() {
        assert_eq!(episodes("Show - 05v2.mkv"), vec![5.0]);
        assert_eq!(parse_filename("Show - 05v2.mkv").version, Some(2));
        assert_eq!(episodes("One Piece - 475 v2 [F-R][b1929031].mkv"), vec![475.0]);
    }

    #[test]
    fn quality_tags_and_crcs_are_never_episodes() {
        assert_eq!(episodes("[Group] Show - 001 [1080p][b1929031].mkv"), vec![1.0]);
        assert_eq!(episodes("[Group] Show - 05 [1080p][10bit][AAC 5.1].mkv"), vec![5.0]);
        assert_eq!(episodes("[Group] Show [1080p][b1929031].mkv"), Vec::<f64>::new());
    }

    #[test]
    fn a_year_alone_is_not_an_episode() {
        assert_eq!(episodes("Show (2020).mkv"), Vec::<f64>::new());
        assert_eq!(episodes("Show 2020.mkv"), Vec::<f64>::new());
        // but a release that numbers past 1900 still reads, because the form says so
        assert_eq!(episodes("One Piece - 1015.mkv"), vec![1015.0]);
    }

    #[test]
    fn extras_are_named_as_such_and_keep_their_numbers() {
        let ncop = parse_filename("[Group] Show - NCOP1.mkv");
        assert_eq!(ncop.kind, Some(ReleaseKind::Creditless));
        assert_eq!(ncop.episode_numbers, vec![1.0]);
        assert!(ncop.is_extra());

        let sp = parse_filename("Specials/[Group] Show - SP01.mkv");
        assert_eq!(sp.kind, Some(ReleaseKind::Special));
        assert_eq!(sp.episode_numbers, vec![1.0]);

        let ova = parse_filename("Specials/[Group] Show - OVA 02.mkv");
        assert_eq!(ova.kind, Some(ReleaseKind::Ova));
        assert_eq!(ova.episode_numbers, vec![2.0]);
    }

    #[test]
    fn an_unnumbered_special_reads_as_an_extra_with_no_number() {
        let parsed = parse_filename("Show - Unnumbered Special.mkv");
        assert_eq!(parsed.kind, Some(ReleaseKind::Special));
        assert!(parsed.episode_numbers.is_empty(), "guessing a number here plays the wrong file");
    }

    #[test]
    fn only_the_last_path_segment_is_read() {
        assert_eq!(episodes("Season 1/[Group] Show S01E02.mkv"), vec![2.0]);
        assert_eq!(episodes("1080p/Show - 05.mkv"), vec![5.0]);
    }

    #[test]
    fn a_name_with_nothing_to_say_says_nothing() {
        assert_eq!(episodes("Movie.mkv"), Vec::<f64>::new());
        assert_eq!(episodes("readme.txt"), Vec::<f64>::new());
        assert_eq!(episodes(""), Vec::<f64>::new());
    }

    #[test]
    fn a_bracketed_number_is_read_only_when_nothing_else_answers() {
        assert_eq!(episodes("[Group] Show [05].mkv"), vec![5.0]);
        // the free-text number wins over the bracketed one
        assert_eq!(episodes("[Group] Show - 07 [05].mkv"), vec![7.0]);
    }

    #[test]
    fn hyphenated_titles_do_not_become_ranges() {
        assert_eq!(episodes("Re-Zero - 05.mkv"), vec![5.0]);
        assert_eq!(episodes("Show - 12-05.mkv"), vec![12.0], "a descending pair is not a range");
    }
}
