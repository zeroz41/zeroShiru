import '../../domain/models/torrent.dart';

/// A soft score for release ordering. Language metadata is often incomplete,
/// so this must never be used as a filter: explicit provider tags are strong,
/// while filename hints are intentionally conservative.
int releaseLanguagePreferenceScore(
  TorrentResult result, {
  required String audioLanguage,
  required String subtitleLanguage,
}) {
  final audio = _base(audioLanguage);
  final subtitles = _base(subtitleLanguage);
  var score = 0;

  final reportedAudio = result.audioLanguages
      .map(_base)
      .whereType<String>()
      .toSet();
  if (audio != null && reportedAudio.isNotEmpty) {
    score += reportedAudio.contains(audio) ? 90 : -90;
  } else if (audio != null) {
    score += _audioTitleScore(result.title, audio);
  }

  final reportedSubtitles = result.subtitleLanguages
      .map(_base)
      .whereType<String>()
      .toSet();
  if (subtitles != null && reportedSubtitles.isNotEmpty) {
    score += reportedSubtitles.contains(subtitles) ? 60 : -45;
  } else if (subtitles != null) {
    score += _subtitleTitleScore(result.title, subtitles);
  }
  return score;
}

String? explicitReleaseLanguageLabel(TorrentResult result) {
  String labels(Iterable<String> values) => values
      .map(_base)
      .whereType<String>()
      .toSet()
      .map((value) => value.toUpperCase())
      .join('/');

  final audio = labels(result.audioLanguages);
  final subtitles = labels(result.subtitleLanguages);
  if (audio.isEmpty && subtitles.isEmpty) return null;
  return [
    if (audio.isNotEmpty) '$audio audio',
    if (subtitles.isNotEmpty) '$subtitles subs',
  ].join(' · ');
}

int _audioTitleScore(String title, String preferred) {
  final lower = title.toLowerCase();
  final dual = RegExp(r'\bdual[ ._-]*audio\b').hasMatch(lower);
  final english = RegExp(r'\b(eng(?:lish)?[ ._-]*audio|dub(?:bed)?)\b')
      .hasMatch(lower);
  final japanese = RegExp(r'\b(jpn|japanese|ja)[ ._-]*(audio|dub)\b')
      .hasMatch(lower);
  return switch (preferred) {
    'en' => dual || english ? 42 : -8,
    'ja' =>
      dual || japanese
          ? 38
          : english
          ? -42
          : 14,
    _ => 0,
  };
}

int _subtitleTitleScore(String title, String preferred) {
  final lower = title.toLowerCase();
  final multi = RegExp(r'\bmulti[ ._-]*(sub|subtitle)s?\b').hasMatch(lower);
  final raw = RegExp(r'\b(raw|no[ ._-]*subs?)\b').hasMatch(lower);
  final english = RegExp(r'\b(eng(?:lish)?[ ._-]*(sub|subtitle)s?|subbed)\b')
      .hasMatch(lower);
  final japanese = RegExp(r'\b(jpn|japanese|ja)[ ._-]*(sub|subtitle)s?\b')
      .hasMatch(lower);
  return switch (preferred) {
    'en' =>
      multi || english
          ? 28
          : raw
          ? -24
          : 6,
    'ja' =>
      multi || japanese
          ? 28
          : raw
          ? -4
          : 0,
    _ => multi ? 5 : 0,
  };
}

String? _base(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase().replaceAll('_', '-');
  if (normalized.isEmpty || normalized == 'und' || normalized == 'unknown') {
    return null;
  }
  final base = normalized.split('-').first;
  return switch (base) {
    'jpn' || 'jp' || 'japanese' => 'ja',
    'eng' || 'english' => 'en',
    'spa' || 'spanish' => 'es',
    'por' || 'portuguese' => 'pt',
    'deu' || 'ger' || 'german' => 'de',
    'fra' || 'fre' || 'french' => 'fr',
    'ita' || 'italian' => 'it',
    'kor' || 'korean' => 'ko',
    'zho' || 'chi' || 'chinese' => 'zh',
    'rus' || 'russian' => 'ru',
    _ => base,
  };
}
