/// Anime release filename recognition: episode numbers and release kind, read off
/// a file name without a network call or a WASM blob.
///
/// Faithful port of `crates/media/src/filename.rs` (the redo branch's Rust core).
/// It is deliberately *not* a full anitomy: it answers the two questions the
/// picker asks (which episodes does this name claim, and is it an extra rather
/// than an episode) and answers "no idea" everywhere else, because the picker's
/// fallbacks are safe and a confidently wrong number plays the wrong episode.
///
/// The rule throughout: a number is an episode only where a release name would
/// put one. Anything else — resolutions, CRCs, years, codec tags, audio
/// layouts — stays unread rather than being guessed at.
library;

/// The kind of release a name describes, when it says so. Mirrors the subset of
/// anitomy's `anime_type` the picker cares about.
enum ReleaseKind {
  /// Creditless opening/ending (NCOP, NCED, "clean opening").
  creditless,

  /// Opening or ending sequence.
  theme,
  ova,
  ona,
  special,

  /// Preview, PV, CM, trailer, menu, omake, bonus, extra.
  promo;

  /// Whether a file of this kind is an extra rather than an episode of the show.
  /// Everything this enum can hold is; the getter exists so callers read as
  /// intent rather than as "has a kind".
  bool get isExtra => true;
}

/// What a file name says about itself.
class ParsedFilename {
  const ParsedFilename({
    this.episodeNumbers = const [],
    this.kind,
    this.version,
  });

  /// Every episode number the name answers to. One number is a single episode,
  /// two are the ends of a range ("01-12" -> [1, 12]) which counts as covering
  /// everything between. Empty when the name carries no readable number.
  final List<double> episodeNumbers;

  /// The release kind, when the name names one.
  final ReleaseKind? kind;

  /// Release version, from a `v2` suffix.
  final int? version;

  /// Whether this file is an extra rather than an episode.
  bool get isExtra => kind?.isExtra ?? false;
}

/// Reads one file name (a bare name or a full path — only the last segment is read).
ParsedFilename parseFilename(String name) {
  final base = name.split(RegExp(r'[/\\]')).last;
  final stem = _stripExtension(base);
  final tokens = _tokenize(stem);
  final kind = _releaseKind(tokens);
  final (episodeNumbers, version) = _episodeNumbers(tokens);
  return ParsedFilename(
    episodeNumbers: episodeNumbers,
    kind: kind,
    version: version,
  );
}

/// Reads a batch of names, in order.
List<ParsedFilename> parseFilenames(List<String> names) => [
  for (final name in names) parseFilename(name),
];

/// Drops a trailing extension, but only one that looks like an extension: a short
/// alphanumeric tail. "Show - 12.5" keeps its .5, "Show - 12.mkv" loses its .mkv.
String _stripExtension(String base) {
  final dot = base.lastIndexOf('.');
  if (dot < 0) return base;
  final stem = base.substring(0, dot);
  final ext = base.substring(dot + 1);
  final plausible =
      ext.isNotEmpty &&
      ext.length <= 4 &&
      ext.codeUnits.every(_isAsciiAlphanumeric) &&
      ext.codeUnits.any(_isAsciiAlphabetic);
  return plausible ? stem : base;
}

bool _isAsciiDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isAsciiAlphabetic(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
bool _isAsciiAlphanumeric(int c) => _isAsciiDigit(c) || _isAsciiAlphabetic(c);

class _Token {
  const _Token(this.text, {this.enclosed = false, this.separator = false});

  final String text;

  /// Inside [], () or {} — where group names, CRCs and quality tags live.
  final bool enclosed;

  /// A lone `-`, which is what separates a title from its episode number.
  final bool separator;
}

/// Splits a name into bracket groups and free-text words. Delimiters are space,
/// underscore, plus and dot — except a dot between two digits, which is a decimal
/// point in an episode number like `12.5`.
List<_Token> _tokenize(String stem) {
  final chars = stem.codeUnits;
  final tokens = <_Token>[];
  final word = StringBuffer();
  var index = 0;

  void flush() {
    if (word.isEmpty) return;
    // a trailing/leading dash is a separator: "Show - 05" and "Show-05" alike
    final text = _trimDashes(word.toString());
    if (text.isEmpty) {
      tokens.add(const _Token('-', separator: true));
    } else {
      tokens.add(_Token(text));
    }
    word.clear();
  }

  while (index < chars.length) {
    final c = chars[index];
    final close = switch (c) {
      0x5B => 0x5D, // [ ]
      0x28 => 0x29, // ( )
      0x7B => 0x7D, // { }
      _ => null,
    };
    if (close != null) {
      flush();
      final start = index + 1;
      var end = start;
      while (end < chars.length && chars[end] != close) {
        end++;
      }
      final text = String.fromCharCodes(chars, start, end).trim();
      if (text.isNotEmpty) {
        tokens.add(_Token(text, enclosed: true));
      }
      index = end + 1;
      continue;
    }
    final delimiter = switch (c) {
      0x20 || 0x5F || 0x2B => true, // space, underscore, plus
      // a dot is a decimal point only between a number and a short fraction:
      // "12.5" is episode 12.5, while "E05.1080p" is two dot-separated words
      0x2E => !_isDecimalPoint(word.toString(), chars, index),
      _ => false,
    };
    if (delimiter) {
      flush();
    } else {
      word.writeCharCode(c);
    }
    index++;
  }
  flush();
  return tokens;
}

String _trimDashes(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && text.codeUnitAt(start) == 0x2D) {
    start++;
  }
  while (end > start && text.codeUnitAt(end - 1) == 0x2D) {
    end--;
  }
  return text.substring(start, end);
}

/// Whether the dot at `index` joins a number to its fraction rather than
/// separating two words. Both sides have to look the part: digits only before it,
/// and one or two digits after it that end the word.
bool _isDecimalPoint(String word, List<int> chars, int index) {
  if (word.isEmpty || !word.codeUnits.every(_isAsciiDigit)) return false;
  var fraction = 0;
  while (index + 1 + fraction < chars.length &&
      _isAsciiDigit(chars[index + 1 + fraction])) {
    fraction++;
  }
  final after = index + 1 + fraction;
  final terminated =
      after >= chars.length || !_isAsciiAlphanumeric(chars[after]);
  return fraction >= 1 && fraction <= 2 && terminated;
}

/// The release kind a name declares, if any. Read from free text and brackets
/// alike: plenty of releases put `[NCOP]` in a tag.
ReleaseKind? _releaseKind(List<_Token> tokens) {
  ReleaseKind? found;
  for (final token in tokens) {
    final word = _stripTrailingNumber(token.text).$1.toUpperCase();
    final kind = switch (word) {
      'NCOP' || 'NCED' || 'CREDITLESS' || 'NC' => ReleaseKind.creditless,
      'OP' || 'ED' || 'OPENING' || 'ENDING' => ReleaseKind.theme,
      'OVA' || 'OAD' => ReleaseKind.ova,
      'ONA' => ReleaseKind.ona,
      'SP' || 'SPECIAL' || 'SPECIALS' || 'OMAKE' => ReleaseKind.special,
      'PV' ||
      'CM' ||
      'PREVIEW' ||
      'TRAILER' ||
      'MENU' ||
      'BONUS' ||
      'EXTRA' ||
      'EXTRAS' => ReleaseKind.promo,
      _ => null,
    };
    // "clean opening" and friends: the qualifier makes it creditless
    if (kind != null) {
      found = found == ReleaseKind.creditless ? ReleaseKind.creditless : kind;
    }
  }
  return found;
}

/// Splits a trailing number off a word: "NCOP1" -> ("NCOP", 1.0).
(String, double?) _stripTrailingNumber(String text) {
  var split = text.length;
  while (split > 0) {
    final c = text.codeUnitAt(split - 1);
    if (_isAsciiDigit(c) || c == 0x2E) {
      split--;
    } else {
      break;
    }
  }
  if (split == 0 || split == text.length) return (text, null);
  return (text.substring(0, split), _parseFloat(text.substring(split)));
}

/// The episode numbers a name claims, and the release version if it carries one.
/// Candidates are read in priority order; the first form that answers wins, so a
/// name saying `S01E05` is never re-read as something else.
(List<double>, int?) _episodeNumbers(List<_Token> tokens) {
  final free = [
    for (final token in tokens)
      if (!token.enclosed) token,
  ];

  final found =
      _seasonEpisode(free) ??
      _prefixedEpisode(free) ??
      _kindNumbered(free) ??
      _afterSeparator(free) ??
      _bareNumber(free);
  if (found != null) return (found, _versionOf(tokens));

  // last resort: a bracket that holds nothing but a number, as in "Show [05]"
  for (final token in tokens) {
    if (!token.enclosed) continue;
    final numbers = _numericToken(token.text);
    if (numbers != null && !_looksLikeYear(numbers)) {
      return (numbers, _versionOf(tokens));
    }
  }
  return (const [], _versionOf(tokens));
}

/// `S01E05`, `S01E05-E06`, `1x05`.
List<double>? _seasonEpisode(List<_Token> tokens) {
  for (var index = 0; index < tokens.length; index++) {
    final text = tokens[index].text.toUpperCase();
    if (text.startsWith('S')) {
      final rest = text.substring(1);
      // S01E05 in one token
      final e = rest.indexOf('E');
      if (e >= 0) {
        final found = _episodeRange(rest.substring(e + 1));
        if (found != null) return found;
      }
      // S01 . E05 as two tokens
      if (rest.isNotEmpty && rest.codeUnits.every(_isAsciiDigit)) {
        if (index + 1 < tokens.length) {
          final next = tokens[index + 1].text.toUpperCase();
          if (next.startsWith('E')) {
            final found = _episodeRange(next.substring(1));
            if (found != null) return found;
          }
        }
      }
    }
    // 1x05 — but not 1920x1080, which is a frame size. A season is one or two
    // digits; reading a width as one made every file in a pack claim episode 1080,
    // so the episode being asked for was in none of them and the pack was refused
    final x = text.indexOf('X');
    if (x >= 0) {
      final season = text.substring(0, x);
      final episodes = text.substring(x + 1);
      if (season.isNotEmpty &&
          season.length <= 2 &&
          season.codeUnits.every(_isAsciiDigit) &&
          episodes.isNotEmpty) {
        final found = _episodeRange(episodes);
        if (found != null) return found;
      }
    }
  }
  return null;
}

/// `E05`, `EP05`, `Episode 05`, `EP 05-06`.
List<double>? _prefixedEpisode(List<_Token> tokens) {
  for (var index = 0; index < tokens.length; index++) {
    final text = tokens[index].text.toUpperCase();
    for (final prefix in const ['EPISODE', 'EPS', 'EP', 'E']) {
      if (!text.startsWith(prefix)) continue;
      final rest = text.substring(prefix.length);
      if (rest.isEmpty) {
        // the number is the next token
        if (index + 1 < tokens.length) {
          final found = _numericToken(tokens[index + 1].text);
          if (found != null) return found;
        }
      } else {
        final found = _episodeRange(rest);
        if (found != null) return found;
      }
      break; // longest matching prefix only
    }
  }
  return null;
}

/// `NCOP1`, `SP01`, `OVA 02` — an extra that carries its own number.
List<double>? _kindNumbered(List<_Token> tokens) {
  for (var index = 0; index < tokens.length; index++) {
    final (word, trailing) = _stripTrailingNumber(tokens[index].text);
    if (_releaseKind([_Token(word)]) == null) continue;
    if (trailing != null) return [trailing];
    if (index + 1 < tokens.length) {
      final found = _numericToken(tokens[index + 1].text);
      if (found != null) return found;
    }
  }
  return null;
}

/// The fansub form: `Title - 05`, `Title - 01-12`, `Title - 05v2`.
List<double>? _afterSeparator(List<_Token> tokens) {
  for (var index = 0; index < tokens.length; index++) {
    if (!tokens[index].separator) continue;
    if (index + 1 < tokens.length) {
      final found = _numericToken(tokens[index + 1].text);
      if (found != null) return found;
    }
  }
  return null;
}

/// A standalone number somewhere in the name, taking the last one — release names
/// put the title first. Years and other non-episode numbers are skipped.
List<double>? _bareNumber(List<_Token> tokens) {
  for (var index = tokens.length - 1; index >= 0; index--) {
    final found = _numericToken(tokens[index].text);
    if (found == null) continue;
    final previous = index > 0 ? tokens[index - 1] : null;
    if (!_looksLikeYear(found) && !_followsAudioTag(previous)) return found;
  }
  return null;
}

/// A four-digit number on its own is a year far more often than an episode; the
/// dash-delimited and prefixed forms above still read one when a release means it.
bool _looksLikeYear(List<double> numbers) {
  if (numbers.length != 1) return false;
  final single = numbers.first;
  return single >= 1900.0 &&
      single <= 2100.0 &&
      single == single.truncateToDouble();
}

/// `AAC 5.1` and friends: a decimal after an audio tag is a channel layout.
bool _followsAudioTag(_Token? previous) {
  if (previous == null) return false;
  return const {
    'AAC',
    'AC3',
    'EAC3',
    'DD',
    'DDP',
    'DTS',
    'FLAC',
    'TRUEHD',
    'OPUS',
  }.contains(previous.text.toUpperCase());
}

/// A token that is nothing but an episode number (or range), with an optional
/// `v2` version suffix: "05", "005", "12.5", "01-12", "05v2".
List<double>? _numericToken(String text) =>
    _episodeRange(_stripVersion(text).$1);

/// Splits a `v2` suffix off a number token.
(String, int?) _stripVersion(String text) {
  var split = -1;
  for (var index = text.length - 1; index >= 0; index--) {
    final c = text.codeUnitAt(index);
    if (c == 0x76 || c == 0x56) {
      split = index;
      break;
    }
  }
  if (split >= 0) {
    final number = text.substring(0, split);
    final version = text.substring(split + 1);
    if (number.isNotEmpty &&
        number.codeUnits.every(
          (c) => _isAsciiDigit(c) || c == 0x2E || c == 0x2D,
        ) &&
        version.isNotEmpty &&
        version.codeUnits.every(_isAsciiDigit)) {
      return (number, int.tryParse(version));
    }
  }
  return (text, null);
}

/// Reads "05" as [5] and "01-12" as [1, 12]. Anything that is not purely a number
/// or a number range reads as nothing.
List<double>? _episodeRange(String text) {
  if (text.isEmpty) return null;
  final dash = text.indexOf('-');
  if (dash >= 0) {
    final first = _number(text.substring(0, dash));
    if (first == null) return null;
    var secondText = _stripVersion(text.substring(dash + 1)).$1;
    if (secondText.startsWith('E') || secondText.startsWith('e')) {
      secondText = secondText.substring(1);
    }
    final second = _number(secondText);
    // "12-05" counts down rather than spanning, so it names one episode, not a range
    return second != null && second > first ? [first, second] : [first];
  }
  final single = _number(text);
  return single == null ? null : [single];
}

/// A plain decimal number, digits only. Leading zeros are fine; anything else is not.
double? _number(String text) {
  if (text.isEmpty ||
      !text.codeUnits.every((c) => _isAsciiDigit(c) || c == 0x2E)) {
    return null;
  }
  final parsed = _parseFloat(text);
  return parsed != null && parsed.isFinite ? parsed : null;
}

/// Rust-compatible float parsing over a digits-and-dots string: "1." parses as
/// 1.0 the way `str::parse::<f64>` reads it, where Dart's own parser refuses it.
double? _parseFloat(String text) {
  final parsed = double.tryParse(text);
  if (parsed != null) return parsed;
  if (text.endsWith('.')) {
    return double.tryParse(text.substring(0, text.length - 1));
  }
  return null;
}

/// The release version anywhere in the name: `05v2`, `475 v2`.
int? _versionOf(List<_Token> tokens) {
  for (final token in tokens) {
    final (_, version) = _stripVersion(token.text);
    if (version != null) return version;
    final text = token.text.toLowerCase();
    if (text.startsWith('v')) {
      final digits = text.substring(1);
      if (digits.isNotEmpty && digits.codeUnits.every(_isAsciiDigit)) {
        return int.tryParse(digits);
      }
    }
  }
  return null;
}

// --- File-kind classification shared with the pickers ---
// Port of VIDEO/SUBTITLE/FONT_EXTENSIONS in crates/media/src/lib.rs (originally
// videoExtensions/subtitleExtensions in common/modules/util.js).

const List<String> videoExtensions = [
  '3g2',
  '3gp',
  'asf',
  'avi',
  'dv',
  'flv',
  'gxf',
  'm2ts',
  'm4a',
  'm4b',
  'm4p',
  'm4r',
  'm4v',
  'mkv',
  'mov',
  'mp4',
  'mpd',
  'mpeg',
  'mpg',
  'mxf',
  'nut',
  'ogm',
  'ogv',
  'swf',
  'ts',
  'vob',
  'webm',
  'wmv',
  'wtv',
];

const List<String> subtitleExtensions = [
  'srt',
  'vtt',
  'ass',
  'ssa',
  'sub',
  'txt',
];

/// Fonts an ASS subtitle track may need to render as its author meant it.
const List<String> fontExtensions = [
  'ttf',
  'ttc',
  'woff',
  'woff2',
  'otf',
  'cff',
  'otc',
  'pfa',
  'pfb',
  'pcf',
  'fnt',
  'bdf',
  'pfr',
  'eot',
];

bool _hasExtension(String path, List<String> extensions) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = path.substring(dot + 1).toLowerCase();
  return extensions.contains(ext);
}

bool isVideoPath(String path) => _hasExtension(path, videoExtensions);

bool isSubtitlePath(String path) => _hasExtension(path, subtitleExtensions);

bool isFontPath(String path) => _hasExtension(path, fontExtensions);

/// Everything playback can use: the video, its subtitles, and the fonts those
/// subtitles need. The filter every resolve applies.
bool isPlaybackPath(String path) =>
    isVideoPath(path) || isSubtitlePath(path) || isFontPath(path);
