import 'dart:async' hide TimeoutException;
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tiny_segmenter_dart/tiny_segmenter_dart.dart';

import '../../domain/ports/language_learning.dart';
import '../../domain/ports/http_transport.dart';

const _jmdictDownload =
    'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english.zip';
const _maximumUncompressedDictionaryBytes = 320 * 1024 * 1024;
const _maximumDictionaryEntries = 1000000;

/// Fast Japanese segmentation plus JMdict definitions, entirely on-device
/// after the user-triggered dictionary download. Both the large Yomitan import
/// and per-cue segmentation/enrichment stay outside Flutter's UI isolate.
class LocalJapaneseLearningTools implements LanguageLearningTools {
  LocalJapaneseLearningTools({
    required String databasePath,
    required this.transport,
  }) : _databasePath = databasePath,
       _db = sqlite3.open(databasePath),
       _analysisWorker = _JapaneseAnalysisWorker(databasePath) {
    _prepareDatabase(_db);
    _status = _readStatus(_db);
  }

  final String _databasePath;
  final HttpTransport transport;
  final Database _db;
  final _JapaneseAnalysisWorker _analysisWorker;

  @override
  String get languageCode => 'ja';
  final _statusController =
      StreamController<LearningDictionaryStatus>.broadcast();
  late LearningDictionaryStatus _status;
  Future<void>? _activeInstall;
  var _disposed = false;

  // Subtitle text repeats constantly — every seek-back replays the same cues
  // and every hover re-asks about the same word — so both hot paths keep a
  // small insertion-ordered LRU. Entries are invalidated wholesale whenever
  // the installed dictionary changes.
  static const _tokenizeCacheLimit = 96;
  static const _lookupCacheLimit = 256;
  final _tokenizeCache = <String, List<LearningToken>>{};
  final _lookupCache = <String, List<LearningDefinition>>{};

  void _clearAnalysisCaches() {
    _tokenizeCache.clear();
    _lookupCache.clear();
  }

  static V? _recallLru<V>(Map<String, V> cache, String key) {
    final hit = cache.remove(key);
    if (hit != null) cache[key] = hit;
    return hit;
  }

  static void _storeLru<V>(
    Map<String, V> cache,
    String key,
    V value,
    int limit,
  ) {
    cache[key] = value;
    if (cache.length > limit) cache.remove(cache.keys.first);
  }

  @override
  LearningDictionaryStatus get dictionaryStatus => _status;

  @override
  Stream<LearningDictionaryStatus> get dictionaryStatuses =>
      _statusController.stream;

  void _setStatus(LearningDictionaryStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  @override
  Future<List<LearningToken>> tokenize(String text) async {
    if (_disposed || text.trim().isEmpty) return const [];
    final useDictionary = _status.installed;
    final cacheKey = '${useDictionary ? 'd' : 'p'}\u0000$text';
    final cached = _recallLru(_tokenizeCache, cacheKey);
    if (cached != null) return cached;
    final tokens = await _analysisWorker.tokenize(
      text,
      useDictionary: useDictionary,
    );
    if (!_disposed) {
      _storeLru(_tokenizeCache, cacheKey, tokens, _tokenizeCacheLimit);
    }
    return tokens;
  }

  @override
  Future<List<LearningDefinition>> lookup(
    LearningToken token, {
    int limit = 6,
  }) async {
    if (_disposed || !_status.installed || !token.lookupable || limit <= 0) {
      return const [];
    }
    final cacheKey = [
      token.surface,
      token.baseForm ?? '',
      token.reading ?? '',
      '$limit',
    ].join('\u0000');
    final cached = _recallLru(_lookupCache, cacheKey);
    if (cached != null) return cached;
    final candidates = <String>{
      if (_usable(token.baseForm)) token.baseForm!,
      ...japaneseLookupCandidates(token.surface),
      if (_usable(token.reading)) token.reading!,
      if (_usable(token.reading)) katakanaToHiragana(token.reading!),
      if (_usable(token.reading)) hiraganaToKatakana(token.reading!),
    }..removeWhere((value) => value.trim().isEmpty);
    final results = <LearningDefinition>[];
    final seen = <int>{};
    for (final candidate in candidates) {
      if (results.length >= limit) break;
      final rows = _db.select(
        'SELECT id, term, reading, definitions, parts_of_speech, rules '
        'FROM learning_terms WHERE term = ? OR reading = ? '
        'ORDER BY score DESC, id LIMIT ?',
        [candidate, candidate, limit - results.length],
      );
      for (final row in rows) {
        final id = row['id'] as int;
        if (!seen.add(id)) continue;
        results.add(
          LearningDefinition(
            term: row['term'] as String,
            reading: _nullableString(row['reading']),
            definitions: _stringList(row['definitions']),
            partsOfSpeech: {
              ..._stringList(row['parts_of_speech']),
              ..._stringList(row['rules']),
            }.toList(),
          ),
        );
      }
    }
    _storeLru(_lookupCache, cacheKey, results, _lookupCacheLimit);
    return results;
  }

  @override
  Future<void> installDictionary() {
    final active = _activeInstall;
    if (active != null) return active;
    final install = _install();
    _activeInstall = install;
    return install.whenComplete(() => _activeInstall = null);
  }

  Future<void> _install() async {
    if (_disposed) return;
    final previous = _status.installed ? _status : null;
    _setStatus(
      LearningDictionaryStatus(
        phase: LearningDictionaryPhase.downloading,
        title: 'JMdict English',
        version: previous?.version,
        entryCount: previous?.entryCount ?? 0,
        message: 'Downloading the local dictionary…',
      ),
    );
    try {
      final response = await transport.send(
        HttpRequest(
          HttpMethod.get,
          Uri.parse(_jmdictDownload),
          headers: const {'accept': 'application/zip'},
          timeout: const Duration(minutes: 3),
        ),
      );
      if (!response.ok) {
        throw StateError('Dictionary download returned ${response.status}.');
      }
      if (response.bodyBytes.isEmpty) {
        throw StateError('The dictionary download was empty.');
      }
      _setStatus(
        LearningDictionaryStatus(
          phase: LearningDictionaryPhase.importing,
          title: 'JMdict English',
          version: previous?.version,
          entryCount: previous?.entryCount ?? 0,
          message: 'Building the offline search index…',
        ),
      );
      final databasePath = _databasePath;
      final archiveBytes = response.bodyBytes;
      await Isolate.run(
        () => importYomitanDictionary(
          databasePath: databasePath,
          archiveBytes: archiveBytes,
        ),
      );
      if (_disposed) return;
      _clearAnalysisCaches();
      _setStatus(_readStatus(_db));
    } catch (error) {
      if (_disposed) return;
      _setStatus(
        LearningDictionaryStatus(
          phase: LearningDictionaryPhase.failed,
          title: 'JMdict English',
          version: previous?.version,
          entryCount: previous?.entryCount ?? 0,
          message: _friendlyInstallError(error),
        ),
      );
      rethrow;
    }
  }

  @override
  Future<void> removeDictionary() async {
    if (_disposed || _activeInstall != null) return;
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM learning_terms');
      _db.execute('DELETE FROM learning_dictionary_meta');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _clearAnalysisCaches();
    _setStatus(const LearningDictionaryStatus.missing());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _analysisWorker.dispose();
    await _statusController.close();
    _db.close();
  }
}

class _DictionaryMatch {
  const _DictionaryMatch({
    required this.term,
    required this.reading,
    required this.partsOfSpeech,
  });

  final String term;
  final String? reading;
  final List<String> partsOfSpeech;
}

List<LearningToken> _enrichTokens(Database db, List<LearningToken> tokens) {
  final candidatesBySpan = <(int, int), List<String>>{};
  final allCandidates = <String>{};
  for (var start = 0; start < tokens.length; start++) {
    if (!tokens[start].lookupable) continue;
    var characterCount = 0;
    for (var end = start; end < tokens.length && end - start < 6; end++) {
      if (!tokens[end].lookupable) break;
      characterCount += tokens[end].surface.length;
      if (characterCount > 24) break;
      final surface = tokens
          .sublist(start, end + 1)
          .map((token) => token.surface)
          .join();
      final candidates = japaneseLookupCandidates(surface);
      candidatesBySpan[(start, end + 1)] = candidates;
      allCandidates.addAll(candidates);
    }
  }
  final matches = _dictionaryMatches(db, allCandidates);
  final output = <LearningToken>[];
  var index = 0;
  while (index < tokens.length) {
    final first = tokens[index];
    if (!first.lookupable) {
      output.add(first);
      index++;
      continue;
    }

    _DictionaryMatch? match;
    var matchedEnd = index + 1;
    final possibleEnds =
        candidatesBySpan.keys
            .where((span) => span.$1 == index)
            .map((span) => span.$2)
            .toList()
          ..sort((a, b) => b.compareTo(a));
    for (final end in possibleEnds) {
      for (final candidate in candidatesBySpan[(index, end)]!) {
        match = matches[candidate];
        if (match != null) {
          matchedEnd = end;
          break;
        }
      }
      if (match != null) break;
    }
    if (match == null) {
      output.add(first);
      index++;
      continue;
    }

    final surface = tokens
        .sublist(index, matchedEnd)
        .map((token) => token.surface)
        .join();
    final reading = match.reading == null
        ? null
        : _readingForSurface(
            surface: surface,
            term: match.term,
            dictionaryReading: match.reading!,
          );
    output.add(
      LearningToken(
        surface: surface,
        start: first.start,
        end: tokens[matchedEnd - 1].end,
        baseForm: match.term,
        reading: reading,
        pronunciation: reading,
        romanization: reading == null ? null : kanaToRomaji(reading),
        partOfSpeech: _describePartsOfSpeech(match.partsOfSpeech),
        containsKanji: hasKanji(surface),
      ),
    );
    index = matchedEnd;
  }
  return output;
}

/// Adapts a dictionary-form reading to the inflected text that is actually on
/// screen. Dictionary hits intentionally retain [term] as their lookup key,
/// but showing its unmodified reading for `食べたい` (`たべる`) drops the
/// visible `たい` ending from both furigana and romaji.
String _readingForSurface({
  required String surface,
  required String term,
  required String dictionaryReading,
}) {
  final reading = katakanaToHiragana(dictionaryReading);
  if (surface == term) return reading;
  if (_isKanaOnly(surface)) return katakanaToHiragana(surface);

  final surfaceRunes = surface.runes.toList(growable: false);
  final termRunes = term.runes.toList(growable: false);
  var shared = 0;
  while (shared < surfaceRunes.length &&
      shared < termRunes.length &&
      surfaceRunes[shared] == termRunes[shared]) {
    shared++;
  }
  if (shared == 0) return reading;

  final termEnding = String.fromCharCodes(termRunes.skip(shared));
  final surfaceEnding = String.fromCharCodes(surfaceRunes.skip(shared));
  if (termEnding.isEmpty ||
      !_isKanaOnly(termEnding) ||
      !_isKanaOnly(surfaceEnding)) {
    return reading;
  }
  final normalizedTermEnding = katakanaToHiragana(termEnding);
  if (!reading.endsWith(normalizedTermEnding)) return reading;
  return '${reading.substring(0, reading.length - normalizedTermEnding.length)}'
      '${katakanaToHiragana(surfaceEnding)}';
}

Map<String, _DictionaryMatch> _dictionaryMatches(
  Database db,
  Set<String> candidates,
) {
  final matches = <String, _DictionaryMatch>{};
  final values = candidates.toList(growable: false);
  const chunkSize = 400;
  for (var offset = 0; offset < values.length; offset += chunkSize) {
    final end = offset + chunkSize < values.length
        ? offset + chunkSize
        : values.length;
    final chunk = values.sublist(offset, end);
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final rows = db.select(
      'SELECT term, reading, parts_of_speech, rules FROM learning_terms '
      'WHERE term IN ($placeholders) ORDER BY score DESC, id',
      chunk,
    );
    for (final row in rows) {
      final term = row['term'] as String;
      matches.putIfAbsent(
        term,
        () => _DictionaryMatch(
          term: term,
          reading: _nullableString(row['reading']),
          partsOfSpeech: {
            ..._stringList(row['parts_of_speech']),
            ..._stringList(row['rules']),
          }.toList(),
        ),
      );
    }
  }
  return matches;
}

void _prepareDatabase(Database db) {
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('PRAGMA synchronous = NORMAL');
  db.execute('''
    CREATE TABLE IF NOT EXISTS learning_dictionary_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS learning_terms (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      term TEXT NOT NULL,
      reading TEXT,
      definitions TEXT NOT NULL,
      parts_of_speech TEXT NOT NULL,
      rules TEXT NOT NULL DEFAULT '[]',
      score INTEGER NOT NULL DEFAULT 0,
      sequence INTEGER
    )
  ''');
  final columns = db
      .select('PRAGMA table_info(learning_terms)')
      .map((row) => row['name'])
      .whereType<String>();
  if (!columns.contains('rules')) {
    db.execute(
      "ALTER TABLE learning_terms ADD COLUMN rules TEXT NOT NULL DEFAULT '[]'",
    );
  }
  db.execute(
    'CREATE INDEX IF NOT EXISTS learning_terms_term '
    'ON learning_terms (term)',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS learning_terms_reading '
    'ON learning_terms (reading)',
  );
}

LearningDictionaryStatus _readStatus(Database db) {
  final meta = <String, String>{
    for (final row in db.select(
      'SELECT key, value FROM learning_dictionary_meta',
    ))
      row['key'] as String: row['value'] as String,
  };
  if (meta['installed'] != 'true') {
    return const LearningDictionaryStatus.missing();
  }
  return LearningDictionaryStatus(
    phase: LearningDictionaryPhase.ready,
    title: meta['title'] ?? 'JMdict English',
    version: meta['revision'],
    entryCount: int.tryParse(meta['entry_count'] ?? '') ?? 0,
  );
}

/// Imports the standard Yomitan dictionary interchange format. This function
/// is public for hermetic importer tests and is called in an isolate in
/// production.
int importYomitanDictionary({
  required String databasePath,
  required Uint8List archiveBytes,
}) {
  final archive = ZipDecoder().decodeBytes(archiveBytes, verify: true);
  final expandedSize = archive.files.fold<int>(
    0,
    (total, file) => total + (file.isFile ? file.size : 0),
  );
  if (expandedSize > _maximumUncompressedDictionaryBytes) {
    throw const FormatException('The dictionary archive is too large.');
  }
  final indexFile = archive.files.where((file) => file.name == 'index.json');
  if (indexFile.isEmpty) {
    throw const FormatException('The dictionary archive has no index.json.');
  }
  final index = jsonDecode(utf8.decode(indexFile.first.content));
  if (index is! Map) {
    throw const FormatException('The dictionary index is invalid.');
  }
  final banks = archive.files.where(
    (file) =>
        file.isFile && RegExp(r'(^|/)term_bank_\d+\.json$').hasMatch(file.name),
  );
  if (banks.isEmpty) {
    throw const FormatException('The archive has no term banks.');
  }

  final db = sqlite3.open(databasePath);
  try {
    _prepareDatabase(db);
    var count = 0;
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM learning_terms');
      db.execute('DELETE FROM learning_dictionary_meta');
      final insert = db.prepare(
        'INSERT INTO learning_terms '
        '(term, reading, definitions, parts_of_speech, rules, score, sequence) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
      );
      try {
        for (final bank in banks) {
          final decoded = jsonDecode(utf8.decode(bank.content));
          if (decoded is! List) continue;
          for (final dynamic value in decoded) {
            if (value is! List || value.length < 6 || value[0] is! String) {
              continue;
            }
            final definitionTags = _splitTags(
              value.length > 2 ? value[2] : null,
            );
            if (definitionTags.contains('forms')) continue;
            final definitions = flattenYomitanGlossary(value[5]);
            if (definitions.isEmpty) continue;
            count++;
            if (count > _maximumDictionaryEntries) {
              throw const FormatException('The dictionary has too many terms.');
            }
            insert.execute([
              value[0] as String,
              value[1] is String && (value[1] as String).isNotEmpty
                  ? value[1]
                  : null,
              jsonEncode(definitions),
              jsonEncode(definitionTags),
              jsonEncode(_splitTags(value.length > 3 ? value[3] : null)),
              value.length > 4 && value[4] is num
                  ? (value[4] as num).toInt()
                  : 0,
              value.length > 6 && value[6] is num
                  ? (value[6] as num).toInt()
                  : null,
            ]);
          }
          bank.clear();
        }
      } finally {
        insert.close();
      }
      if (count == 0) {
        throw const FormatException('The dictionary contains no usable terms.');
      }
      final meta = <String, String>{
        'installed': 'true',
        'title': _mapString(index, 'title') ?? 'JMdict English',
        'revision': _mapString(index, 'revision') ?? 'unknown',
        'entry_count': '$count',
        'source': _jmdictDownload,
      };
      final metaInsert = db.prepare(
        'INSERT INTO learning_dictionary_meta (key, value) VALUES (?, ?)',
      );
      try {
        for (final entry in meta.entries) {
          metaInsert.execute([entry.key, entry.value]);
        }
      } finally {
        metaInsert.close();
      }
      db.execute('COMMIT');
      return count;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    archive.clearSync();
    db.close();
  }
}

List<String> flattenYomitanGlossary(dynamic glossary) {
  final output = <String>[];
  if (glossary is List) {
    for (final item in glossary) {
      final text = _flattenStructuredContent(item).trim();
      if (text.isNotEmpty && !output.contains(text)) output.add(text);
    }
  } else {
    final text = _flattenStructuredContent(glossary).trim();
    if (text.isNotEmpty) output.add(text);
  }
  return output;
}

String _flattenStructuredContent(dynamic value) {
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  if (value is List) {
    return value
        .map(_flattenStructuredContent)
        .where((part) => part.isNotEmpty)
        .join(' ');
  }
  if (value is Map) {
    final data = value['data'];
    final contentKind = data is Map ? data['content'] : null;
    if (contentKind == 'references' || contentKind == 'formsTable') return '';
    for (final key in const ['content', 'text', 'alt']) {
      if (value[key] != null) return _flattenStructuredContent(value[key]);
    }
  }
  return '';
}

List<String> _splitTags(dynamic value) => value is String
    ? value.split(RegExp(r'\s+')).where((tag) => tag.isNotEmpty).toList()
    : const [];

String? _mapString(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

List<String> _stringList(dynamic encoded) {
  if (encoded is! String) return const [];
  final decoded = jsonDecode(encoded);
  return decoded is List ? decoded.whereType<String>().toList() : const [];
}

String? _nullableString(dynamic value) =>
    value is String && value.isNotEmpty ? value : null;

bool _usable(String? value) =>
    value != null && value.isNotEmpty && value != '*';

String _friendlyInstallError(Object error) => switch (error) {
  TimeoutException() => 'The dictionary download timed out. Try again.',
  NetworkException() =>
    'The dictionary could not be downloaded. Check your connection.',
  _ => 'The dictionary could not be installed. Try again.',
};

/// Converts the segmenter's exact source slices into stable, UTF-16 subtitle
/// offsets. Gaps and punctuation stay present so the rendered cue is lossless.
List<LearningToken> learningTokensFromSegments(
  String source,
  List<String> segments,
) {
  final output = <LearningToken>[];
  var cursor = 0;
  for (final surface in segments) {
    if (surface.isEmpty) continue;
    final start = source.indexOf(surface, cursor);
    if (start < 0) continue;
    if (start > cursor) {
      output.add(
        LearningToken(
          surface: source.substring(cursor, start),
          start: cursor,
          end: start,
          lookupable: false,
        ),
      );
    }
    final end = start + surface.length;
    output.add(_unannotatedToken(source.substring(start, end), start, end));
    cursor = end;
  }
  if (cursor < source.length) {
    output.add(
      LearningToken(
        surface: source.substring(cursor),
        start: cursor,
        end: source.length,
        lookupable: false,
      ),
    );
  }
  if (output.isEmpty && source.isNotEmpty) {
    output.add(
      LearningToken(
        surface: source,
        start: 0,
        end: source.length,
        containsKanji: hasKanji(source),
        lookupable: hasJapaneseText(source),
      ),
    );
  }
  return output;
}

LearningToken _unannotatedToken(String surface, int start, int end) {
  final lookupable = hasJapaneseText(surface);
  final reading = lookupable && _isKanaOnly(surface)
      ? katakanaToHiragana(surface)
      : null;
  return LearningToken(
    surface: surface,
    start: start,
    end: end,
    reading: reading,
    pronunciation: reading,
    romanization: reading == null ? null : kanaToRomaji(reading),
    containsKanji: hasKanji(surface),
    lookupable: lookupable,
  );
}

/// Produces conservative local dictionary candidates for common subtitle
/// inflections. Every guess is verified against JMdict before it is shown.
List<String> japaneseLookupCandidates(String surface) {
  const maximumCandidates = 96;
  final output = <String>{surface};
  var frontier = <String>{surface};
  for (var depth = 0; depth < 2 && frontier.isNotEmpty; depth++) {
    final expanded = <String>{};
    for (final form in frontier) {
      _addDirectLookupCandidates(expanded, form);
    }
    expanded.removeAll(output);
    final next = <String>{};
    for (final candidate in expanded) {
      if (output.length >= maximumCandidates) break;
      output.add(candidate);
      next.add(candidate);
    }
    frontier = next;
  }
  return output.toList(growable: false);
}

void _addDirectLookupCandidates(Set<String> output, String surface) {
  for (final suffix in const ['ませんでした', 'ません', 'ました', 'ましょう', 'ます']) {
    if (!surface.endsWith(suffix) || surface.length <= suffix.length) continue;
    _addMasuStemCandidates(
      output,
      surface.substring(0, surface.length - suffix.length),
    );
  }
  for (final suffix in const ['たくなかった', 'たくない', 'たかった', 'たい']) {
    if (!surface.endsWith(suffix) || surface.length <= suffix.length) continue;
    _addMasuStemCandidates(
      output,
      surface.substring(0, surface.length - suffix.length),
    );
  }
  for (final suffix in const ['なかった', 'ない']) {
    if (!surface.endsWith(suffix) || surface.length <= suffix.length) continue;
    _addNegativeStemCandidates(
      output,
      surface.substring(0, surface.length - suffix.length),
    );
  }

  _addPastAndTeCandidates(output, surface);
  if (surface.endsWith('くなかった') && surface.length > 5) {
    output.add('${surface.substring(0, surface.length - 5)}い');
  }
  if (surface.endsWith('くない') && surface.length > 3) {
    output.add('${surface.substring(0, surface.length - 3)}い');
  }
  if (surface.endsWith('かった') && surface.length > 3) {
    output.add('${surface.substring(0, surface.length - 3)}い');
  }
}

void _addMasuStemCandidates(Set<String> output, String stem) {
  if (stem.isEmpty) return;
  if (stem == 'し') output.add('する');
  if (stem == 'き') output.add('くる');
  const godan = {
    'い': 'う',
    'き': 'く',
    'ぎ': 'ぐ',
    'し': 'す',
    'ち': 'つ',
    'に': 'ぬ',
    'び': 'ぶ',
    'み': 'む',
    'り': 'る',
  };
  final last = stem.substring(stem.length - 1);
  final ending = godan[last];
  output.add('$stemる');
  if (ending != null) {
    output.add('${stem.substring(0, stem.length - 1)}$ending');
  }
  if (stem.endsWith('し')) {
    final suruStem = stem.substring(0, stem.length - 1);
    output.add('$suruStemする');
    if (suruStem.isNotEmpty) output.add(suruStem);
  }
}

void _addNegativeStemCandidates(Set<String> output, String stem) {
  if (stem.isEmpty) return;
  if (stem == 'し') output.add('する');
  if (stem.endsWith('し')) {
    output.add('${stem.substring(0, stem.length - 1)}する');
  }
  if (stem == 'こ') output.add('くる');
  const godan = {
    'わ': 'う',
    'か': 'く',
    'が': 'ぐ',
    'さ': 'す',
    'た': 'つ',
    'な': 'ぬ',
    'ば': 'ぶ',
    'ま': 'む',
    'ら': 'る',
  };
  final last = stem.substring(stem.length - 1);
  final ending = godan[last];
  if (ending != null) {
    output.add('${stem.substring(0, stem.length - 1)}$ending');
  }
  output.add('$stemる');
}

void _addPastAndTeCandidates(Set<String> output, String surface) {
  void replace(String suffix, List<String> endings) {
    if (!surface.endsWith(suffix) || surface.length <= suffix.length) return;
    final stem = surface.substring(0, surface.length - suffix.length);
    for (final ending in endings) {
      output.add('$stem$ending');
    }
  }

  for (final continuation in const ['', 'いる', 'いた']) {
    replace('いて$continuation', const ['く']);
    replace('いで$continuation', const ['ぐ']);
    replace('して$continuation', const ['す', 'する', '']);
    replace('って$continuation', const ['う', 'つ', 'る']);
    replace('んで$continuation', const ['ぬ', 'ぶ', 'む']);
    replace('て$continuation', const ['る']);
  }
  replace('いた', const ['く']);
  replace('いだ', const ['ぐ']);
  replace('した', const ['す', 'する', '']);
  replace('った', const ['う', 'つ', 'る']);
  replace('んだ', const ['ぬ', 'ぶ', 'む']);
  replace('た', const ['る']);
  if (surface == 'した') output.add('する');
  if (surface == 'して') output.add('する');
  if (surface == 'きた') output.add('くる');
}

String? _describePartsOfSpeech(List<String> tags) {
  final descriptions = <String>{
    for (final tag in tags) ?_partOfSpeechLabel(tag),
  };
  return descriptions.isEmpty ? null : descriptions.take(3).join(' · ');
}

String? _partOfSpeechLabel(String tag) {
  final exact = _partOfSpeechLabels[tag];
  if (exact != null) return exact;
  if (tag.startsWith('v5')) return 'godan verb';
  if (tag.startsWith('v4') || tag.startsWith('v2')) return 'archaic verb';
  if (tag.startsWith('v1')) return 'ichidan verb';
  if (tag.startsWith('adj-')) return 'adjective';
  if (tag.startsWith('adv-')) return 'adverb';
  if (tag.startsWith('aux-')) return 'auxiliary';
  if (tag.startsWith('n-')) return 'noun';
  return null;
}

const _partOfSpeechLabels = <String, String>{
  'n': 'noun',
  'num': 'number',
  'ctr': 'counter',
  'pn': 'pronoun',
  'prt': 'particle',
  'pref': 'prefix',
  'suf': 'suffix',
  'exp': 'expression',
  'int': 'interjection',
  'conj': 'conjunction',
  'cop': 'copula',
  'adv': 'adverb',
  'adj-i': 'い-adjective',
  'adj-na': 'な-adjective',
  'aux': 'auxiliary',
  'aux-v': 'auxiliary verb',
  'v1': 'ichidan verb',
  'v5k': 'godan verb',
  'v5g': 'godan verb',
  'v5s': 'godan verb',
  'v5t': 'godan verb',
  'v5n': 'godan verb',
  'v5b': 'godan verb',
  'v5m': 'godan verb',
  'v5r': 'godan verb',
  'v5u': 'godan verb',
  'vs': 'する verb',
  'vs-i': 'する verb',
  'vs-s': 'する verb',
  'vk': 'くる verb',
  'vi': 'intransitive',
  'vt': 'transitive',
  'unc': 'unclassified',
};

bool _isKanaOnly(String text) =>
    text.isNotEmpty &&
    text.runes.every(
      (rune) => (rune >= 0x3040 && rune <= 0x30ff) || rune == 0x30fc,
    );

bool hasJapaneseText(String text) => text.runes.any(
  (rune) =>
      (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x3400 && rune <= 0x9fff) ||
      (rune >= 0xf900 && rune <= 0xfaff),
);

bool hasKanji(String text) => text.runes.any(
  (rune) =>
      (rune >= 0x3400 && rune <= 0x9fff) || (rune >= 0xf900 && rune <= 0xfaff),
);

String katakanaToHiragana(String value) => String.fromCharCodes(
  value.runes.map(
    (rune) => rune >= 0x30a1 && rune <= 0x30f6 ? rune - 0x60 : rune,
  ),
);

String hiraganaToKatakana(String value) => String.fromCharCodes(
  value.runes.map(
    (rune) => rune >= 0x3041 && rune <= 0x3096 ? rune + 0x60 : rune,
  ),
);

String kanaToRomaji(String value) {
  final kana = katakanaToHiragana(value);
  final runes = kana.runes.toList();
  final output = StringBuffer();
  var geminate = false;
  for (var i = 0; i < runes.length; i++) {
    final character = String.fromCharCode(runes[i]);
    if (character == 'っ') {
      geminate = true;
      continue;
    }
    if (character == 'ー') {
      final text = output.toString();
      final match = RegExp(r'[aeiou](?!.*[aeiou])').firstMatch(text);
      if (match != null) output.write(match.group(0));
      continue;
    }
    var syllable = '';
    if (i + 1 < runes.length) {
      final pair = '$character${String.fromCharCode(runes[i + 1])}';
      syllable = _romajiPairs[pair] ?? '';
      if (syllable.isNotEmpty) i++;
    }
    syllable = syllable.isEmpty
        ? (_romajiKana[character] ?? character)
        : syllable;
    if (geminate && syllable.isNotEmpty) {
      final first = syllable[0];
      if (!'aeioun'.contains(first)) output.write(first);
      geminate = false;
    }
    output.write(syllable);
  }
  return output.toString();
}

const _romajiPairs = <String, String>{
  'きゃ': 'kya',
  'きゅ': 'kyu',
  'きょ': 'kyo',
  'ぎゃ': 'gya',
  'ぎゅ': 'gyu',
  'ぎょ': 'gyo',
  'しゃ': 'sha',
  'しゅ': 'shu',
  'しょ': 'sho',
  'じゃ': 'ja',
  'じゅ': 'ju',
  'じょ': 'jo',
  'ちゃ': 'cha',
  'ちゅ': 'chu',
  'ちょ': 'cho',
  'にゃ': 'nya',
  'にゅ': 'nyu',
  'にょ': 'nyo',
  'ひゃ': 'hya',
  'ひゅ': 'hyu',
  'ひょ': 'hyo',
  'びゃ': 'bya',
  'びゅ': 'byu',
  'びょ': 'byo',
  'ぴゃ': 'pya',
  'ぴゅ': 'pyu',
  'ぴょ': 'pyo',
  'みゃ': 'mya',
  'みゅ': 'myu',
  'みょ': 'myo',
  'りゃ': 'rya',
  'りゅ': 'ryu',
  'りょ': 'ryo',
  'ふぁ': 'fa',
  'ふぃ': 'fi',
  'ふぇ': 'fe',
  'ふぉ': 'fo',
  'てぃ': 'ti',
  'でぃ': 'di',
  'うぃ': 'wi',
  'うぇ': 'we',
  'うぉ': 'wo',
};

const _romajiKana = <String, String>{
  'あ': 'a',
  'い': 'i',
  'う': 'u',
  'え': 'e',
  'お': 'o',
  'か': 'ka',
  'き': 'ki',
  'く': 'ku',
  'け': 'ke',
  'こ': 'ko',
  'が': 'ga',
  'ぎ': 'gi',
  'ぐ': 'gu',
  'げ': 'ge',
  'ご': 'go',
  'さ': 'sa',
  'し': 'shi',
  'す': 'su',
  'せ': 'se',
  'そ': 'so',
  'ざ': 'za',
  'じ': 'ji',
  'ず': 'zu',
  'ぜ': 'ze',
  'ぞ': 'zo',
  'た': 'ta',
  'ち': 'chi',
  'つ': 'tsu',
  'て': 'te',
  'と': 'to',
  'だ': 'da',
  'ぢ': 'ji',
  'づ': 'zu',
  'で': 'de',
  'ど': 'do',
  'な': 'na',
  'に': 'ni',
  'ぬ': 'nu',
  'ね': 'ne',
  'の': 'no',
  'は': 'ha',
  'ひ': 'hi',
  'ふ': 'fu',
  'へ': 'he',
  'ほ': 'ho',
  'ば': 'ba',
  'び': 'bi',
  'ぶ': 'bu',
  'べ': 'be',
  'ぼ': 'bo',
  'ぱ': 'pa',
  'ぴ': 'pi',
  'ぷ': 'pu',
  'ぺ': 'pe',
  'ぽ': 'po',
  'ま': 'ma',
  'み': 'mi',
  'む': 'mu',
  'め': 'me',
  'も': 'mo',
  'や': 'ya',
  'ゆ': 'yu',
  'よ': 'yo',
  'ら': 'ra',
  'り': 'ri',
  'る': 'ru',
  'れ': 're',
  'ろ': 'ro',
  'わ': 'wa',
  'ゐ': 'wi',
  'ゑ': 'we',
  'を': 'o',
  'ん': 'n',
  'ぁ': 'a',
  'ぃ': 'i',
  'ぅ': 'u',
  'ぇ': 'e',
  'ぉ': 'o',
  'ゔ': 'vu',
};

/// Owns segmentation and SQLite enrichment away from Flutter's UI isolate.
/// Unlike a full morphological model, this worker has no expensive warm-up;
/// its database connection remains open so each cue avoids isolate and SQLite
/// setup churn.
class _JapaneseAnalysisWorker {
  _JapaneseAnalysisWorker(this.databasePath);

  final String databasePath;
  final _ready = Completer<SendPort>();
  final _receive = ReceivePort();
  final _requests = <int, Completer<List<LearningToken>>>{};
  StreamSubscription<dynamic>? _subscription;
  Future<SendPort>? _startFuture;
  Isolate? _isolate;
  var _nextId = 0;
  var _disposed = false;

  Future<SendPort> _start() => _startFuture ??= _spawn();

  Future<SendPort> _spawn() async {
    _subscription = _receive.listen(_onMessage);
    final isolate = await Isolate.spawn(_analysisIsolateMain, [
      _receive.sendPort,
      databasePath,
    ]);
    _isolate = isolate;
    if (_disposed) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('Japanese analysis was closed.');
    }
    return _ready.future;
  }

  void _onMessage(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! List || message.length < 3 || message[0] is! int) return;
    final id = message[0] as int;
    if (id == -1 && !_ready.isCompleted) {
      _ready.completeError(StateError('Japanese analysis could not start.'));
      return;
    }
    final completer = _requests.remove(id);
    if (completer == null) return;
    if (message[1] == true && message[2] is List) {
      completer.complete(
        (message[2] as List)
            .whereType<List>()
            .map(_decodeLearningToken)
            .toList(growable: false),
      );
    } else {
      completer.completeError(StateError('Japanese analysis failed.'));
    }
  }

  Future<List<LearningToken>> tokenize(
    String text, {
    required bool useDictionary,
  }) async {
    if (_disposed) return const [];
    final port = await _start();
    if (_disposed) return const [];
    final id = _nextId++;
    final completer = Completer<List<LearningToken>>();
    _requests[id] = completer;
    port.send([id, text, useDictionary]);
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_startFuture != null && !_ready.isCompleted) {
      _ready.completeError(StateError('Japanese analysis was closed.'));
    }
    for (final completer in _requests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Japanese analysis was closed.'));
      }
    }
    _requests.clear();
    _isolate?.kill(priority: Isolate.immediate);
    await _subscription?.cancel();
    _receive.close();
  }
}

@pragma('vm:entry-point')
Future<void> _analysisIsolateMain(List<dynamic> bootstrap) async {
  final owner = bootstrap[0] as SendPort;
  final databasePath = bootstrap[1] as String;
  final requests = ReceivePort();
  Database? db;
  try {
    db = sqlite3.open(databasePath);
    final segmenter = TinySegmenter();
    owner.send(requests.sendPort);
    await for (final dynamic message in requests) {
      if (message is! List ||
          message.length < 3 ||
          message[0] is! int ||
          message[1] is! String ||
          message[2] is! bool) {
        continue;
      }
      final id = message[0] as int;
      try {
        final text = message[1] as String;
        var tokens = learningTokensFromSegments(text, segmenter.segment(text));
        if (message[2] as bool) tokens = _enrichTokens(db, tokens);
        owner.send([
          id,
          true,
          tokens.map(_encodeLearningToken).toList(growable: false),
        ]);
      } catch (_) {
        owner.send([id, false, null]);
      }
    }
  } catch (_) {
    owner.send([-1, false, null]);
  } finally {
    db?.close();
    requests.close();
  }
}

List<Object?> _encodeLearningToken(LearningToken token) => [
  token.surface,
  token.start,
  token.end,
  token.baseForm,
  token.reading,
  token.pronunciation,
  token.romanization,
  token.partOfSpeech,
  token.containsKanji,
  token.lookupable,
];

LearningToken _decodeLearningToken(List<dynamic> value) => LearningToken(
  surface: value[0] as String,
  start: value[1] as int,
  end: value[2] as int,
  baseForm: value[3] as String?,
  reading: value[4] as String?,
  pronunciation: value[5] as String?,
  romanization: value[6] as String?,
  partOfSpeech: value[7] as String?,
  containsKanji: value[8] as bool,
  lookupable: value[9] as bool,
);
