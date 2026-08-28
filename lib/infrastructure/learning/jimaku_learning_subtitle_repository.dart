import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:koni_archive/koni_archive.dart' as koni;
import 'package:path/path.dart' as p;

import '../../domain/ports/learning_subtitles.dart';
import '../../domain/media/filename.dart';
import '../../domain/ports/http_transport.dart';

/// Read-only Jimaku API client with a bounded, rebuildable episode cache.
///
/// Jimaku directories are keyed by AniList ID, which avoids fuzzy show-name
/// matching. Its episode filter is best effort, so candidates are scored and
/// checked again locally before any file reaches the player.
class JimakuLearningSubtitleRepository implements LearningSubtitleRepository {
  JimakuLearningSubtitleRepository({
    required this.transport,
    required this.cacheDirectory,
  });

  static const _host = 'jimaku.cc';
  static const _provider = 'Jimaku';
  // A matcher change gets a new cache generation: a cached subtitle is a
  // release decision, not merely a downloaded file. Never let a decision made
  // by an older ranker silently override the current release-aware result.
  static const _cacheVersion = 'v8-learning-cues';
  static const _maximumArchiveExpansion = 64 * 1024 * 1024;
  static const _maximumSubtitleBytes = 8 * 1024 * 1024;
  static const _maximumArchiveEntries = 2048;
  static const _textExtensions = {'.ass', '.ssa', '.srt', '.vtt'};
  static const _archiveExtensions = {'.zip', '.7z'};

  final HttpTransport transport;
  final String cacheDirectory;

  @override
  Future<void> validateCredential(String credential) async {
    _credential(credential);
    await _json(
      Uri.https(_host, '/api/entries/search', const {'anilist_id': '21'}),
      credential,
    );
  }

  @override
  Future<LearningSubtitleMatch?> findJapanese(
    LearningSubtitleQuery query, {
    required String credential,
  }) async {
    final existing = await _existingMatch(query);
    if (existing != null) return existing;
    final key = _credential(credential);
    final entries = await _json(
      Uri.https(_host, '/api/entries/search', {
        'anilist_id': '${query.anilistId}',
      }),
      key,
    );
    if (entries is! List) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.invalidResponse,
        'The Japanese subtitle catalog returned an invalid show match.',
      );
    }

    final matchingEntries = entries.whereType<Map>().where(
      (entry) => _positiveInt(entry['anilist_id']) == query.anilistId,
    );
    final files = <_RemoteSubtitle>[];
    final seenFiles = <String>{};
    for (final entry in matchingEntries) {
      final id = _positiveInt(entry['id']);
      if (id == null) continue;
      for (final remote in await _entryCandidates(id, query, key)) {
        if (seenFiles.add('${remote.url}\n${remote.name}')) {
          files.add(remote);
        }
      }
    }
    files.sort(
      (a, b) => _candidateScore(
        b.name,
        query,
      ).compareTo(_candidateScore(a.name, query)),
    );

    LearningSubtitleFailure? lastDownloadFailure;
    for (final remote in files) {
      final _CachedSubtitle? cached;
      try {
        cached = await _cachedOrDownload(remote, query);
      } on LearningSubtitleFailure catch (failure) {
        // One stale or malformed catalog object must not hide a valid lower
        // ranked release. Authentication/rate-limit failures happen on the API
        // calls above and still surface immediately.
        if (failure.kind == LearningSubtitleFailureKind.authentication ||
            failure.kind == LearningSubtitleFailureKind.rateLimited) {
          rethrow;
        }
        lastDownloadFailure = failure;
        continue;
      } catch (_) {
        continue;
      }
      if (cached == null) continue;
      return LearningSubtitleMatch(
        source: cached.file.uri.toString(),
        title: _trackTitle(cached.originalName),
        provider: _provider,
        originalName: cached.originalName,
      );
    }
    if (lastDownloadFailure != null) throw lastDownloadFailure;
    return null;
  }

  static List<_RemoteSubtitle> _remoteCandidates(
    List<Object?> rows,
    LearningSubtitleQuery query,
  ) => [
    for (final row in rows.whereType<Map>())
      if (_RemoteSubtitle.fromJson(row) case final remote?
          when _candidateScore(remote.name, query) >= 0)
        remote,
  ];

  Future<List<_RemoteSubtitle>> _entryCandidates(
    int entryId,
    LearningSubtitleQuery query,
    String credential,
  ) async {
    var response = await _json(
      Uri.https(_host, '/api/entries/$entryId/files', {
        if (!query.movie) 'episode': '${query.episode}',
      }),
      credential,
    );
    if (response is! List) return const [];
    var accepted = _remoteCandidates(response, query);
    if (accepted.isNotEmpty || query.movie) return accepted;

    // Jimaku's episode filter is intentionally best effort and can omit
    // archives whose own name has no episode even though their members do.
    // Retry the exact AniList entry unfiltered only when the cheap lookup had
    // nothing locally safe to try.
    response = await _json(
      Uri.https(_host, '/api/entries/$entryId/files'),
      credential,
    );
    return response is List ? _remoteCandidates(response, query) : const [];
  }

  Future<_CachedSubtitle?> _cachedOrDownload(
    _RemoteSubtitle remote,
    LearningSubtitleQuery query,
  ) async {
    final extension = p.extension(remote.name).toLowerCase();
    final identity = sha256
        .convert(utf8.encode('${remote.url}|${remote.modified}'))
        .toString()
        .substring(0, 24);
    final directory = _cacheDirectory(query);

    if (_textExtensions.contains(extension)) {
      final target = File(
        p.join(directory.path, _cacheFileName(identity, remote.name)),
      );
      if (await target.exists()) {
        final existing = await target.readAsBytes();
        if (_containsJapanese(existing)) {
          return _CachedSubtitle(target, remote.name);
        }
      }
      final bytes = _prepareJapaneseSubtitle(
        await _download(remote.url),
        extension,
      );
      if (bytes == null) return null;
      await directory.create(recursive: true);
      await _writeAtomically(target, bytes);
      await _prune(directory, keeping: target);
      return _CachedSubtitle(target, remote.name);
    }

    if (!_archiveExtensions.contains(extension)) return null;
    final archiveBytes = await _download(remote.url);
    final archive = await koni.Archive.openBytes(
      archiveBytes,
      options: const koni.ArchiveReadOptions(
        maxEntrySize: _maximumSubtitleBytes,
        maxEntryCount: _maximumArchiveEntries,
        maxContainerDecodeSize: _maximumArchiveExpansion,
      ),
    );
    final expanded = archive.entries.fold<int>(
      0,
      (sum, file) => sum + (file.isFile ? file.uncompressedSize : 0),
    );
    if (expanded > _maximumArchiveExpansion) {
      await archive.close();
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.unsafeFile,
        'The subtitle archive expands beyond the safe local limit.',
      );
    }
    try {
      final candidates =
          archive.entries.where((file) {
            if (!file.isFile ||
                file.pathEscapedRoot ||
                file.uncompressedSize > _maximumSubtitleBytes) {
              return false;
            }
            final name = p.basename(file.path);
            return _textExtensions.contains(p.extension(name).toLowerCase()) &&
                _archiveMemberScore(remote.name, name, query) >= 0;
          }).toList()..sort(
            (a, b) =>
                _archiveMemberScore(
                  remote.name,
                  p.basename(b.path),
                  query,
                ).compareTo(
                  _archiveMemberScore(remote.name, p.basename(a.path), query),
                ),
          );
      for (final member in candidates) {
        final memberName = p.basename(member.path);
        final memberExtension = p.extension(memberName).toLowerCase();
        final bytes = _prepareJapaneseSubtitle(
          await archive.readBytes(member, maxSize: _maximumSubtitleBytes),
          memberExtension,
        );
        if (bytes == null) continue;
        final target = File(
          p.join(
            directory.path,
            _cacheFileName(identity, memberName, extension: memberExtension),
          ),
        );
        await directory.create(recursive: true);
        await _writeAtomically(target, bytes);
        await _prune(directory, keeping: target);
        return _CachedSubtitle(target, '${remote.name} → $memberName');
      }
      return null;
    } finally {
      await archive.close();
    }
  }

  Future<Object?> _json(Uri uri, String credential) async {
    final response = await _send(
      HttpRequest(
        HttpMethod.get,
        uri,
        headers: {
          'accept': 'application/json',
          'authorization': credential,
          'user-agent': 'Zero/0.1',
        },
        timeout: const Duration(seconds: 12),
      ),
    );
    _checkResponse(response, api: true);
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.invalidResponse,
        'The Japanese subtitle catalog returned unreadable data.',
      );
    }
  }

  Future<Uint8List> _download(String source) async {
    final parsed = Uri.tryParse(source);
    final uri = parsed == null
        ? null
        : parsed.hasScheme
        ? parsed
        : Uri.https(_host).resolveUri(parsed);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.unsafeFile,
        'The subtitle catalog returned an unsafe download address.',
      );
    }
    // Deliberately do not forward the Jimaku credential to a file host or a
    // redirected download. File URLs are bearer-free public downloads.
    final response = await _send(
      HttpRequest(
        HttpMethod.get,
        uri,
        headers: const {
          'accept': 'application/octet-stream',
          'user-agent': 'Zero/0.1',
        },
        timeout: const Duration(seconds: 20),
      ),
    );
    _checkResponse(response, api: false);
    if (response.bodyBytes.length > _maximumSubtitleBytes * 2) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.unsafeFile,
        'The subtitle download is larger than the safe local limit.',
      );
    }
    return response.bodyBytes;
  }

  Future<HttpResponse> _send(HttpRequest request) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await transport.send(request);
        if (response.status < 500 || attempt == 1) return response;
        last = response;
      } catch (error) {
        last = error;
        if (attempt == 1) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    if (last is HttpResponse) return last;
    throw const LearningSubtitleFailure(
      LearningSubtitleFailureKind.unavailable,
      'The Japanese subtitle catalog could not be reached.',
    );
  }

  static void _checkResponse(HttpResponse response, {required bool api}) {
    if (response.ok) return;
    if (api && (response.status == 401 || response.status == 403)) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.authentication,
        'Jimaku did not accept that API key.',
      );
    }
    if (response.status == 429) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.rateLimited,
        'Jimaku is rate-limiting requests. Try again in a moment.',
      );
    }
    throw const LearningSubtitleFailure(
      LearningSubtitleFailureKind.unavailable,
      'The Japanese subtitle catalog is temporarily unavailable.',
    );
  }

  static String _credential(String value) {
    final credential = value.trim();
    if (credential.isEmpty) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.authentication,
        'Connect Jimaku in Learning settings to fetch Japanese subtitles.',
      );
    }
    return credential;
  }

  static Future<void> _writeAtomically(File target, Uint8List bytes) async {
    final temporary = File('${target.path}.part');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<LearningSubtitleMatch?> _existingMatch(
    LearningSubtitleQuery query,
  ) async {
    final directory = _cacheDirectory(query);
    if (!await directory.exists()) return null;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !_textExtensions.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      final bytes = await entity.readAsBytes();
      if (!_containsJapanese(bytes)) continue;
      final originalName = _cachedOriginalName(entity.path);
      return LearningSubtitleMatch(
        source: entity.uri.toString(),
        title: _trackTitle(originalName),
        provider: _provider,
        originalName: originalName,
      );
    }
    return null;
  }

  Directory _cacheDirectory(LearningSubtitleQuery query) {
    final release = sha256
        .convert(utf8.encode(query.releaseName.trim().toLowerCase()))
        .toString()
        .substring(0, 16);
    return Directory(
      p.join(
        cacheDirectory,
        _cacheVersion,
        '${query.anilistId}',
        '${query.episode}',
        release,
      ),
    );
  }

  static Future<void> _prune(
    Directory directory, {
    required File keeping,
  }) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path != keeping.path) {
        await entity.delete();
      }
    }
  }

  static bool _containsJapanese(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maximumSubtitleBytes) return false;
    final text = utf8.decode(bytes, allowMalformed: true);
    var count = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x3040 && rune <= 0x30ff) ||
          (rune >= 0x3400 && rune <= 0x9fff)) {
        if (++count >= 4) return true;
      }
    }
    return false;
  }

  static Uint8List? _prepareJapaneseSubtitle(
    List<int> source,
    String extension,
  ) {
    if (!_containsJapanese(source)) return null;
    if (extension != '.ass' && extension != '.ssa') {
      return Uint8List.fromList(source);
    }
    final text = utf8.decode(source, allowMalformed: true);
    final prepared = utf8.encode(_japaneseOnlyAss(text));
    return _containsJapanese(prepared) ? Uint8List.fromList(prepared) : null;
  }

  /// Prepares ASS/SSA for the plain-text Learning renderer.
  ///
  /// Foreign event layers are removed from bilingual downloads. Adjacent
  /// animation frames with the same visible Japanese text are also coalesced:
  /// karaoke typesetting commonly emits dozens of alpha/clip frames for one
  /// lyric, but Learning needs one stable textual cue rather than a new cue on
  /// every highlighted syllable.
  static String _japaneseOnlyAss(String source) {
    final lines = source.split('\n');
    final events = <_AssDialogue>[];
    var inEvents = false;
    List<String>? format;
    for (final (index, original) in lines.indexed) {
      final line = original.trimRight();
      if (line.startsWith('[') && line.endsWith(']')) {
        inEvents = line.toLowerCase() == '[events]';
        format = null;
        continue;
      }
      if (!inEvents) continue;
      final separator = line.indexOf(':');
      if (separator < 0) continue;
      final kind = line.substring(0, separator).trim().toLowerCase();
      final body = line.substring(separator + 1).trimLeft();
      if (kind == 'format') {
        format = body
            .split(',')
            .map((field) => field.trim().toLowerCase())
            .toList(growable: false);
        continue;
      }
      if (kind != 'dialogue' || format == null) continue;
      final fields = _assFields(body, format.length);
      if (fields == null) continue;
      final textIndex = format.indexOf('text');
      if (textIndex < 0 || textIndex >= fields.length) continue;
      final styleIndex = format.indexOf('style');
      final style = styleIndex < 0
          ? ''
          : fields[styleIndex].trim().toLowerCase();
      final startIndex = format.indexOf('start');
      final endIndex = format.indexOf('end');
      if (startIndex < 0 || endIndex < 0) continue;
      final start = _assTimestamp(fields[startIndex]);
      final end = _assTimestamp(fields[endIndex]);
      if (start == null || end == null) continue;
      final visible = fields[textIndex]
          .replaceAll(_assOverridePattern, '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', ' ');
      events.add(
        _AssDialogue(
          lineIndex: index,
          style: style,
          start: start,
          end: end,
          visible: visible.replaceAll(_assWhitespacePattern, ' ').trim(),
          fields: fields,
          endIndex: endIndex,
          japanese: _containsJapaneseText(visible),
          foreign: _containsForeignScriptText(visible),
        ),
      );
    }

    final japaneseCount = events.where((event) => event.japanese).length;
    final foreignCount = events
        .where((event) => !event.japanese && event.foreign)
        .length;
    final removed = <int>{};
    if (japaneseCount >= 2 && foreignCount >= 2) {
      final japaneseByStyle = <String, int>{};
      final foreignByStyle = <String, int>{};
      for (final event in events) {
        if (event.japanese) {
          japaneseByStyle.update(
            event.style,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        } else if (event.foreign) {
          foreignByStyle.update(
            event.style,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
      }
      final japaneseStyles = <String>{
        for (final style in {...japaneseByStyle.keys, ...foreignByStyle.keys})
          if (_japaneseAssStylePattern.hasMatch(style) ||
              ((japaneseByStyle[style] ?? 0) > 0 &&
                  (foreignByStyle[style] ?? 0) == 0))
            style,
      };
      removed.addAll({
        for (final event in events)
          if (!event.japanese &&
              event.foreign &&
              !japaneseStyles.contains(event.style))
            event.lineIndex,
      });
    }

    final replacementEnds = <int, Duration>{};
    final active = <String, _AssDialogue>{};
    final chronological = events.where((event) => event.japanese).toList()
      ..sort((left, right) {
        final start = left.start.compareTo(right.start);
        return start != 0 ? start : left.lineIndex.compareTo(right.lineIndex);
      });
    for (final event in chronological) {
      if (event.visible.isEmpty) continue;
      final signature = '${event.style}\u0000${event.visible}';
      final previous = active[signature];
      final previousEnd = previous == null
          ? null
          : replacementEnds[previous.lineIndex] ?? previous.end;
      if (previous != null &&
          previousEnd != null &&
          event.start <= previousEnd + const Duration(milliseconds: 80)) {
        removed.add(event.lineIndex);
        if (event.end > previousEnd) {
          replacementEnds[previous.lineIndex] = event.end;
        }
      } else {
        active[signature] = event;
      }
    }

    if (removed.isEmpty && replacementEnds.isEmpty) return source;
    final eventsByLine = {for (final event in events) event.lineIndex: event};
    return [
      for (final (index, line) in lines.indexed)
        if (!removed.contains(index))
          if (replacementEnds[index] case final end?)
            eventsByLine[index]!.withEnd(end)
          else
            line,
    ].join('\n');
  }

  static Duration? _assTimestamp(String value) {
    final match = _assTimestampPattern.firstMatch(value.trim());
    if (match == null) return null;
    final hours = int.tryParse(match.group(1)!);
    final minutes = int.tryParse(match.group(2)!);
    final seconds = int.tryParse(match.group(3)!);
    final fraction = match.group(4) ?? '0';
    if (hours == null || minutes == null || seconds == null) return null;
    final milliseconds = int.tryParse(fraction.padRight(3, '0'));
    if (milliseconds == null) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  static String _formatAssTimestamp(Duration value) {
    final totalCentiseconds = value.inMilliseconds ~/ 10;
    final centiseconds = totalCentiseconds % 100;
    final totalSeconds = totalCentiseconds ~/ 100;
    final seconds = totalSeconds % 60;
    final totalMinutes = totalSeconds ~/ 60;
    final minutes = totalMinutes % 60;
    final hours = totalMinutes ~/ 60;
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${centiseconds.toString().padLeft(2, '0')}';
  }

  static List<String>? _assFields(String source, int count) {
    if (count <= 0) return null;
    final fields = <String>[];
    var start = 0;
    for (var index = 1; index < count; index++) {
      final comma = source.indexOf(',', start);
      if (comma < 0) return null;
      fields.add(source.substring(start, comma));
      start = comma + 1;
    }
    fields.add(source.substring(start));
    return fields;
  }

  static bool _containsJapaneseText(String text) => text.runes.any(
    (rune) =>
        (rune >= 0x3040 && rune <= 0x30ff) ||
        (rune >= 0x3400 && rune <= 0x9fff) ||
        (rune >= 0xf900 && rune <= 0xfaff),
  );

  static bool _containsForeignScriptText(String text) => text.runes.any(
    (rune) =>
        (rune >= 0x0041 && rune <= 0x005a) ||
        (rune >= 0x0061 && rune <= 0x007a) ||
        (rune >= 0x00c0 && rune <= 0x024f) ||
        (rune >= 0x0400 && rune <= 0x052f) ||
        (rune >= 0x0600 && rune <= 0x06ff) ||
        (rune >= 0x0750 && rune <= 0x077f) ||
        (rune >= 0x08a0 && rune <= 0x08ff) ||
        (rune >= 0x0900 && rune <= 0x097f) ||
        (rune >= 0x0e00 && rune <= 0x0e7f) ||
        (rune >= 0x1100 && rune <= 0x11ff) ||
        (rune >= 0x3130 && rune <= 0x318f) ||
        (rune >= 0xac00 && rune <= 0xd7af),
  );

  static final _assOverridePattern = RegExp(r'\{\\[^}]*\}');
  static final _assWhitespacePattern = RegExp(r'\s+');
  static final _assTimestampPattern = RegExp(
    r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?$',
  );
  static final _japaneseAssStylePattern = RegExp(
    r'(^|[ ._-])(ja|jp|jpn|japanese)($|[ ._-])',
  );

  static int _candidateScore(String name, LearningSubtitleQuery query) {
    final lower = name.toLowerCase();
    final extension = p.extension(lower);
    if (!_textExtensions.contains(extension) &&
        !_archiveExtensions.contains(extension)) {
      return -1;
    }
    if (!_archiveExtensions.contains(extension)) {
      return _textCandidateScore(
        episodeName: name,
        releaseIdentity: name,
        query: query,
      );
    }
    if (_isGeneratedOrOcr(name)) return -1;
    final episodeScore = _episodeScore(name, query, allowUnnumbered: true);
    if (episodeScore < 0) return -1;
    return episodeScore +
        _releaseCompatibilityScore(name, query.releaseName) +
        _releaseSimilarity(name, query.releaseName);
  }

  static int _archiveMemberScore(
    String archiveName,
    String memberName,
    LearningSubtitleQuery query,
  ) => _textCandidateScore(
    episodeName: memberName,
    releaseIdentity: '$archiveName / $memberName',
    query: query,
  );

  static int _textCandidateScore({
    required String episodeName,
    required String releaseIdentity,
    required LearningSubtitleQuery query,
  }) {
    if (_isGeneratedOrOcr(releaseIdentity)) return -1;
    final extension = p.extension(episodeName).toLowerCase();
    final formatScore = _subtitleFormatScore(extension);
    if (formatScore < 0) return -1;
    final episodeScore = _episodeScore(episodeName, query);
    if (episodeScore < 0) return -1;
    return episodeScore +
        _releaseCompatibilityScore(releaseIdentity, query.releaseName) +
        _releaseSimilarity(releaseIdentity, query.releaseName) +
        formatScore;
  }

  static int _subtitleFormatScore(String extension) => switch (extension) {
    '.ass' => 5,
    '.srt' => 4,
    '.vtt' => 3,
    '.ssa' => 2,
    _ => -1,
  };

  static int _episodeScore(
    String name,
    LearningSubtitleQuery query, {
    bool allowUnnumbered = false,
  }) {
    if (query.movie) return 0;
    final episodes = parseFilename(name).episodeNumbers;
    // The remote episode filter is deliberately not the source of truth. A
    // direct subtitle (and every subtitle inside an archive) must name the
    // requested episode, otherwise a valid file for another episode can be
    // attached and cached here. Archives themselves are the only exception
    // because their members are validated independently.
    if (episodes.isEmpty) return allowUnnumbered ? 0 : -1;
    final wanted = query.episode.toDouble();
    if (episodes.contains(wanted)) {
      return 200;
    } else if (episodes.length >= 2 &&
        episodes.reduce((a, b) => a < b ? a : b) <= wanted &&
        episodes.reduce((a, b) => a > b ? a : b) >= wanted) {
      return 150;
    }
    return -1;
  }

  static final _generatedOrOcrPattern = RegExp(
    r'\b(ocr|whisper|subgen|machine[ ._-]*generated|generated[ ._-]*by|ai[ ._-]*generated)\b',
  );

  static bool _isGeneratedOrOcr(String value) =>
      _generatedOrOcrPattern.hasMatch(value.toLowerCase());

  static int _releaseCompatibilityScore(String subtitle, String release) {
    final candidate = _ReleaseProfile.fromName(subtitle);
    final target = _ReleaseProfile.fromName(release);
    var score = 0;

    final groupMatches = candidate.groups.intersection(target.groups).length;
    score += groupMatches * 180;
    final candidateWords = _normalizedWords(subtitle).join(' ');
    final targetWords = _normalizedWords(release).join(' ');
    final looseGroupMatches = {
      for (final group in target.groups)
        if (_containsReleaseSignal(candidateWords, group)) group,
      for (final group in candidate.groups)
        if (_containsReleaseSignal(targetWords, group)) group,
    }.length;
    score += (looseGroupMatches - groupMatches).clamp(0, 99) * 180;

    final platformMatches = candidate.platforms
        .intersection(target.platforms)
        .length;
    score += platformMatches * 140;
    if (target.platforms.isNotEmpty &&
        candidate.platforms.isNotEmpty &&
        platformMatches == 0) {
      score -= 130;
    }

    if (target.source == _SubtitleTimingSource.unknown) {
      // An unlabelled anime release is more often a WEB encode than a TV
      // transport or Blu-ray cut, but this is deliberately a small tiebreaker
      // rather than the old assumption that could dominate real evidence.
      score += switch (candidate.source) {
        _SubtitleTimingSource.web => 18,
        _SubtitleTimingSource.broadcast => -24,
        _SubtitleTimingSource.bluray => -8,
        _SubtitleTimingSource.unknown => 0,
      };
    } else if (candidate.source == target.source) {
      score += 100;
    } else if (candidate.source == _SubtitleTimingSource.unknown) {
      score -= 20;
    } else {
      score -= 150;
    }

    score += _explicitRetimeScore(subtitle, target);
    return score;
  }

  static int _explicitRetimeScore(String subtitle, _ReleaseProfile target) {
    final normalized = _normalizedWords(subtitle).join(' ');
    if (!RegExp(r'\b(sync|synced|retime|retimed)\b').hasMatch(normalized)) {
      return 0;
    }
    final signals = {...target.groups, ...target.platforms};
    for (final signal in signals) {
      if (normalized.contains(signal.replaceAll('-', ' '))) return 220;
    }
    return 0;
  }

  static String _cacheFileName(
    String identity,
    String originalName, {
    String? extension,
  }) {
    final suffix = (extension ?? p.extension(originalName)).toLowerCase();
    final stem = p
        .basenameWithoutExtension(originalName)
        .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
        .trim();
    final shortened = String.fromCharCodes(stem.runes.take(48));
    return '$identity--${shortened.isEmpty ? 'subtitle' : shortened}$suffix';
  }

  static String _cachedOriginalName(String path) {
    final name = p.basename(path);
    final marker = name.indexOf('--');
    return marker < 0 ? name : name.substring(marker + 2);
  }

  static String _trackTitle(String originalName) {
    final compact = originalName.replaceAll(RegExp(r'\s+'), ' ').trim();
    final visible = String.fromCharCodes(compact.runes.take(64));
    return 'Japanese · $_provider · $visible${compact.runes.length > 64 ? '…' : ''}';
  }

  static int _releaseSimilarity(String subtitle, String release) {
    Set<String> words(String value) => _normalizedWords(value)
        .where((word) => word.length >= 3)
        .where(
          (word) => !RegExp(
            r'^(2160|1440|1080|720|540|480|264|265|hevc|avc|av1|aac|flac|mkv|ass|ssa|srt|vtt|episode|dual|audio|jpn|japanese)$',
          ).hasMatch(word),
        )
        .toSet();
    final left = words(subtitle);
    final right = words(release);
    if (left.isEmpty || right.isEmpty) return 0;
    // Source/group tokens such as SubsPlease, WEB, or BluRay are meaningful
    // timing signals. One matching token should outweigh the small preference
    // for ASS over SRT, while common show-title words still cancel out across
    // otherwise equivalent candidates.
    return left.intersection(right).length * 3;
  }
}

class _AssDialogue {
  const _AssDialogue({
    required this.lineIndex,
    required this.style,
    required this.start,
    required this.end,
    required this.visible,
    required this.fields,
    required this.endIndex,
    required this.japanese,
    required this.foreign,
  });

  final int lineIndex;
  final String style;
  final Duration start;
  final Duration end;
  final String visible;
  final List<String> fields;
  final int endIndex;
  final bool japanese;
  final bool foreign;

  String withEnd(Duration value) {
    final rewritten = fields.toList(growable: false);
    rewritten[endIndex] = JimakuLearningSubtitleRepository._formatAssTimestamp(
      value,
    );
    return 'Dialogue: ${rewritten.join(',')}';
  }
}

enum _SubtitleTimingSource { unknown, web, broadcast, bluray }

class _ReleaseProfile {
  const _ReleaseProfile({
    required this.source,
    required this.platforms,
    required this.groups,
  });

  final _SubtitleTimingSource source;
  final Set<String> platforms;
  final Set<String> groups;

  factory _ReleaseProfile.fromName(String value) {
    final words = _normalizedWords(value).toSet();
    final platforms = <String>{};
    const platformAliases = <String, String>{
      'amazon': 'amazon',
      'amzn': 'amazon',
      'netflix': 'netflix',
      'nf': 'netflix',
      'crunchyroll': 'crunchyroll',
      'hidive': 'hidive',
      'hulu': 'hulu',
      'disney': 'disney',
      'funimation': 'funimation',
    };
    for (final word in words) {
      final platform = platformAliases[word];
      if (platform != null) platforms.add(platform);
    }

    final groups = <String>{};
    for (final match in RegExp(r'\[([^\]]+)\]').allMatches(value)) {
      final raw = match.group(1);
      if (raw == null) continue;
      final group = _normalizedWords(raw).join('-');
      if (group.isEmpty || _technicalBracketGroup(group)) continue;
      groups.add(group);
    }

    const webGroups = <String, String>{
      'subsplease': 'crunchyroll',
      'horriblesubs': 'crunchyroll',
      'erai-raws': 'crunchyroll',
    };
    for (final group in groups) {
      final platform = webGroups[group];
      if (platform != null) platforms.add(platform);
    }

    final lower = value.toLowerCase();
    final explicitBluray = RegExp(
      r'\b(bluray|blu[ ._-]*ray|bdrip|bd[ ._-]*remux|bdmv|\bbd\b)\b',
    ).hasMatch(lower);
    final explicitWeb = RegExp(
      r'\b(web|webrip|web[ ._-]*dl|amazon|amzn|netflix|crunchyroll|hidive|hulu|disney|funimation)\b',
    ).hasMatch(lower);
    final explicitBroadcast = RegExp(
      r'\b(ntv|at[ ._-]*x|bs11|tokyo[ ._-]*mx|hdtv|broadcast|transport[ ._-]*stream|\btv\b)\b',
    ).hasMatch(lower);
    final source = explicitBluray
        ? _SubtitleTimingSource.bluray
        : explicitWeb || platforms.isNotEmpty
        ? _SubtitleTimingSource.web
        : explicitBroadcast
        ? _SubtitleTimingSource.broadcast
        : _SubtitleTimingSource.unknown;
    return _ReleaseProfile(
      source: source,
      platforms: platforms,
      groups: groups,
    );
  }
}

List<String> _normalizedWords(String value) =>
    RegExp(r'[a-z0-9]+')
        .allMatches(value.toLowerCase().replaceAll('at-x', 'atx'))
        .map((match) {
          final word = match.group(0)!;
          return switch (word) {
            'atx' => 'at-x',
            _ => word,
          };
        })
        .toList(growable: false);

bool _containsReleaseSignal(String normalizedWords, String signal) {
  final normalizedSignal = signal.replaceAll('-', ' ').trim();
  return normalizedSignal.isNotEmpty &&
      ' $normalizedWords '.contains(' $normalizedSignal ');
}

bool _technicalBracketGroup(String value) =>
    RegExp(
      r'^(\d{3,4}p?|[a-f0-9]{8,}|ja|jp|jpn|en|eng|ja-en|chs|cht|chi|cc|sdh|no-sdh|no-speaker-labels|reformatted|dual-audio|web|web-dl|webrip|bluray|blu-ray|bd|bdrip|ntv|at-x|10bit)$',
    ).hasMatch(value) ||
    RegExp(r'\b(hevc|x26[45]|av1|aac|flac|sub|audio|speaker|label)\b')
        .hasMatch(value);

class _CachedSubtitle {
  const _CachedSubtitle(this.file, this.originalName);

  final File file;
  final String originalName;
}

class _RemoteSubtitle {
  const _RemoteSubtitle({
    required this.url,
    required this.name,
    required this.modified,
  });

  final String url;
  final String name;
  final String modified;

  static _RemoteSubtitle? fromJson(Map value) {
    final url = value['url'];
    final name = value['name'];
    if (url is! String || name is! String || url.isEmpty || name.isEmpty) {
      return null;
    }
    return _RemoteSubtitle(
      url: url,
      name: name,
      modified: value['last_modified'] is String
          ? value['last_modified'] as String
          : '',
    );
  }
}

int? _positiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value');
  return parsed != null && parsed > 0 ? parsed : null;
}
