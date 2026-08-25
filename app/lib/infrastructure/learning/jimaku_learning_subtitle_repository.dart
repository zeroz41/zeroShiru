import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/ports/learning_subtitles.dart';
import '../media/filename.dart';
import '../network/transport.dart';

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
  // v1 accepted unnumbered direct files after trusting Jimaku's best-effort
  // episode filter. v2/v3 could prefer a differently timed TV/Blu-ray file
  // over a WEB release because format and title overlap carried too much
  // weight. Keep every unsafe generation out of the lookup path permanently.
  static const _cacheVersion = 'v4-source-aware';
  static const _maximumArchiveExpansion = 64 * 1024 * 1024;
  static const _maximumSubtitleBytes = 8 * 1024 * 1024;
  static const _textExtensions = {'.ass', '.ssa', '.srt', '.vtt'};

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
      (entry) => entry['anilist_id'] == query.anilistId,
    );
    final files = <_RemoteSubtitle>[];
    for (final entry in matchingEntries) {
      final id = _positiveInt(entry['id']);
      if (id == null) continue;
      final response = await _json(
        Uri.https(_host, '/api/entries/$id/files', {
          if (!query.movie) 'episode': '${query.episode}',
        }),
        key,
      );
      if (response is! List) continue;
      for (final row in response.whereType<Map>()) {
        final remote = _RemoteSubtitle.fromJson(row);
        if (remote != null && _candidateScore(remote.name, query) >= 0) {
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

    for (final remote in files) {
      final cached = await _cachedOrDownload(remote, query);
      if (cached == null) continue;
      return LearningSubtitleMatch(
        source: cached.uri.toString(),
        title: _trackTitle(remote.name),
        provider: _provider,
        originalName: remote.name,
      );
    }
    return null;
  }

  Future<File?> _cachedOrDownload(
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
        if (_containsJapanese(existing)) return target;
      }
      final bytes = await _download(remote.url);
      if (!_containsJapanese(bytes)) return null;
      await directory.create(recursive: true);
      await _writeAtomically(target, bytes);
      await _prune(directory, keeping: target);
      return target;
    }

    if (extension != '.zip') return null;
    final archiveBytes = await _download(remote.url);
    final archive = ZipDecoder().decodeBytes(archiveBytes, verify: true);
    final expanded = archive.files.fold<int>(
      0,
      (sum, file) => sum + (file.isFile ? file.size : 0),
    );
    if (expanded > _maximumArchiveExpansion) {
      throw const LearningSubtitleFailure(
        LearningSubtitleFailureKind.unsafeFile,
        'The subtitle archive expands beyond the safe local limit.',
      );
    }
    final candidates =
        archive.files.where((file) {
          if (!file.isFile || file.size > _maximumSubtitleBytes) return false;
          final name = file.name.split(RegExp(r'[/\\]')).last;
          return _textExtensions.contains(p.extension(name).toLowerCase()) &&
              _candidateScore(name, query) >= 0;
        }).toList()..sort(
          (a, b) => _candidateScore(
            b.name,
            query,
          ).compareTo(_candidateScore(a.name, query)),
        );
    for (final member in candidates) {
      final bytes = Uint8List.fromList(member.content as List<int>);
      if (!_containsJapanese(bytes)) continue;
      final memberExtension = p.extension(member.name).toLowerCase();
      final target = File(
        p.join(
          directory.path,
          _cacheFileName(identity, member.name, extension: memberExtension),
        ),
      );
      await directory.create(recursive: true);
      await _writeAtomically(target, bytes);
      await _prune(directory, keeping: target);
      archive.clear();
      return target;
    }
    archive.clear();
    return null;
  }

  Future<Object?> _json(Uri uri, String credential) async {
    final response = await _send(
      HttpRequest(
        HttpMethod.get,
        uri,
        headers: {
          'accept': 'application/json',
          'authorization': credential,
          'user-agent': 'zeroShiru/0.1',
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
          'user-agent': 'zeroShiru/0.1',
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

  static int _candidateScore(String name, LearningSubtitleQuery query) {
    final lower = name.toLowerCase();
    if (RegExp(r'\b(ocr|whisper|generated[ ._-]*by|machine[ ._-]*generated)\b')
        .hasMatch(lower)) {
      return -1;
    }
    final extension = p.extension(lower);
    if (!_textExtensions.contains(extension) && extension != '.zip') return -1;

    var score = switch (extension) {
      '.ass' => 8,
      '.srt' => 7,
      '.vtt' => 6,
      '.ssa' => 5,
      '.zip' => 0,
      _ => 0,
    };
    score += _timingSourceScore(name, query.releaseName);
    if (query.movie) return score;
    final episodes = parseFilename(name).episodeNumbers;
    // The remote episode filter is deliberately not the source of truth. A
    // direct subtitle (and every subtitle inside an archive) must name the
    // requested episode, otherwise a valid file for another episode can be
    // attached and cached here. Archives themselves are the only exception
    // because their members are validated independently.
    if (episodes.isEmpty) return extension == '.zip' ? score : -1;
    final wanted = query.episode.toDouble();
    if (episodes.contains(wanted)) {
      score += 100;
    } else if (episodes.length >= 2 &&
        episodes.reduce((a, b) => a < b ? a : b) <= wanted &&
        episodes.reduce((a, b) => a > b ? a : b) >= wanted) {
      score += 70;
    } else {
      return -1;
    }
    score += _releaseSimilarity(name, query.releaseName);
    return score;
  }

  static int _timingSourceScore(String subtitle, String release) {
    final candidateSource = _timingSource(subtitle);
    final releaseSource = _timingSource(release);
    var score = 0;
    if (releaseSource == _SubtitleTimingSource.unknown) {
      // Debrid episode picks are normally WEB encodes even when the release
      // group omits a platform tag. Broadcast captions often include station
      // bumpers or edit points and must not win merely because they are ASS.
      score += switch (candidateSource) {
        _SubtitleTimingSource.web => 45,
        _SubtitleTimingSource.broadcast => -25,
        _SubtitleTimingSource.bluray => -15,
        _SubtitleTimingSource.unknown => 0,
      };
    } else if (candidateSource == releaseSource) {
      score += 80;
    } else if (candidateSource == _SubtitleTimingSource.unknown) {
      score -= 15;
    } else {
      score -= 80;
    }

    final releasePlatforms = _platformSignals(release);
    final candidatePlatforms = _platformSignals(subtitle);
    score += releasePlatforms.intersection(candidatePlatforms).length * 30;
    return score;
  }

  static _SubtitleTimingSource _timingSource(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\b(bluray|blu[ ._-]*ray|bdrip|bdremux|bdmv)\b')
        .hasMatch(lower)) {
      return _SubtitleTimingSource.bluray;
    }
    if (RegExp(
      r'\b(web|webrip|web[ ._-]*dl|amazon|amzn|netflix|crunchyroll|hidive|hulu|disney)\b',
    ).hasMatch(lower)) {
      return _SubtitleTimingSource.web;
    }
    if (RegExp(
      r'\b(ntv|at[ ._-]*x|bs11|tokyo[ ._-]*mx|hdtv|broadcast|transport[ ._-]*stream|tv)\b',
    ).hasMatch(lower)) {
      return _SubtitleTimingSource.broadcast;
    }
    return _SubtitleTimingSource.unknown;
  }

  static Set<String> _platformSignals(String value) {
    final lower = value.toLowerCase();
    const aliases = <String, String>{
      'amazon': 'amazon',
      'amzn': 'amazon',
      'netflix': 'netflix',
      'nf': 'netflix',
      'crunchyroll': 'crunchyroll',
      'hidive': 'hidive',
      'hulu': 'hulu',
      'disney': 'disney',
      'ntv': 'ntv',
      'atx': 'at-x',
      'bs11': 'bs11',
    };
    final words = RegExp(r'[a-z0-9]+')
        .allMatches(lower.replaceAll('at-x', 'atx'))
        .map((match) => match.group(0)!)
        .toSet();
    final signals = <String>{};
    for (final word in words) {
      final signal = aliases[word];
      if (signal != null) signals.add(signal);
    }
    return signals;
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
    Set<String> words(String value) => RegExp(r'[a-z0-9]{3,}')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .where(
          (word) =>
              !RegExp(r'^(1080|2160|720|480|mkv|ass|ssa|srt|vtt)$')
                  .hasMatch(word),
        )
        .toSet();
    final left = words(subtitle);
    final right = words(release);
    if (left.isEmpty || right.isEmpty) return 0;
    // Source/group tokens such as SubsPlease, WEB, or BluRay are meaningful
    // timing signals. One matching token should outweigh the small preference
    // for ASS over SRT, while common show-title words still cancel out across
    // otherwise equivalent candidates.
    return left.intersection(right).length * 8;
  }
}

enum _SubtitleTimingSource { unknown, web, broadcast, bluray }

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
