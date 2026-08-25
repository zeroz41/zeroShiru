import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/ports/learning_subtitles.dart';
import 'package:zeroshiru/infrastructure/learning/jimaku_learning_subtitle_repository.dart';
import 'package:zeroshiru/infrastructure/network/transport.dart';

void main() {
  test(
    'resolves AniList episode text to a local cache without leaking auth',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zeroshiru-jimaku-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final transport = _JimakuTransport(
        files: const [
          {
            'name': '[JP] Test Show - 07.ass',
            'url': 'https://files.example/show-07.ass',
            'size': 100,
            'last_modified': '2026-08-24T00:00:00Z',
          },
        ],
        downloads: {
          '/show-07.ass': utf8.encode(
            '[Script Info]\n[Events]\nDialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,日本語を勉強する。',
          ),
        },
      );
      final repository = JimakuLearningSubtitleRepository(
        transport: transport,
        cacheDirectory: directory.path,
      );
      const query = LearningSubtitleQuery(
        anilistId: 123,
        episode: 7,
        releaseName: '[Group] Test Show - 07 1080p.mkv',
      );

      final first = await repository.findJapanese(
        query,
        credential: 'personal-key',
      );
      final second = await repository.findJapanese(query, credential: '');

      expect(first, isNotNull);
      expect(second?.source, first?.source);
      final cached = File.fromUri(Uri.parse(first!.source));
      expect(await cached.exists(), isTrue);
      expect(cached.path, contains('v4-source-aware'));
      expect(first.originalName, '[JP] Test Show - 07.ass');
      expect(second?.originalName, '[JP] Test Show - 07.ass');
      expect(first.title, contains('[JP] Test Show - 07.ass'));
      expect(await cached.readAsString(), contains('日本語'));
      expect(transport.downloadRequests, hasLength(1));
      expect(transport.fileEpisodeQueries, ['7']);
      expect(
        transport.apiRequests.every(
          (request) => request.headers['authorization'] == 'personal-key',
        ),
        isTrue,
      );
      expect(
        transport.downloadRequests.single.headers.containsKey('authorization'),
        isFalse,
      );
    },
  );

  test('selects the requested non-OCR episode inside a bounded zip', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zeroshiru-jimaku-zip-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'Test Show - 06.ass',
          '[Events]\nDialogue: 0,0:00:01,0:00:02,Default,,0,0,0,,前の話です。',
        ),
      )
      ..add(
        ArchiveFile.string(
          'nested/Test Show - 07.ass',
          '[Events]\nDialogue: 0,0:00:01,0:00:02,Default,,0,0,0,,七話の日本語です。',
        ),
      );
    final transport = _JimakuTransport(
      files: const [
        {
          'name': 'Test Show complete.zip',
          'url': 'https://files.example/show.zip',
          'size': 1000,
          'last_modified': '2026-08-24T00:00:00Z',
        },
        {
          'name': 'Test Show - 07 (OCR converted).ass',
          'url': 'https://files.example/ocr.ass',
          'size': 100,
          'last_modified': '2026-08-24T00:00:00Z',
        },
      ],
      downloads: {
        '/show.zip': Uint8List.fromList(ZipEncoder().encodeBytes(archive)),
      },
    );
    final repository = JimakuLearningSubtitleRepository(
      transport: transport,
      cacheDirectory: directory.path,
    );

    final match = await repository.findJapanese(
      const LearningSubtitleQuery(
        anilistId: 123,
        episode: 7,
        releaseName: 'Test Show - 07.mkv',
      ),
      credential: 'personal-key',
    );

    expect(match, isNotNull);
    expect(
      await File.fromUri(Uri.parse(match!.source)).readAsString(),
      contains('七話'),
    );
    expect(transport.downloadRequests.single.url.path, '/show.zip');
  });

  test('prefers the subtitle timed for the active release source', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zeroshiru-jimaku-release-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final transport = _JimakuTransport(
      files: const [
        {
          'name': 'Test Show - 07 [BluRay].ass',
          'url': 'https://files.example/bluray.ass',
          'last_modified': '2026-08-24T00:00:00Z',
        },
        {
          'name': '[SubsPlease] Test Show - 07 [WEB-DL].srt',
          'url': 'https://files.example/web.srt',
          'last_modified': '2026-08-24T00:00:00Z',
        },
      ],
      downloads: {
        '/bluray.ass': utf8.encode(
          '[Events]\nDialogue: 0,0:00:01,0:00:02,Default,,0,0,0,,違う版の日本語です。',
        ),
        '/web.srt': utf8.encode(
          '1\n00:00:01,000 --> 00:00:02,000\n正しい版の日本語です。',
        ),
      },
    );
    final repository = JimakuLearningSubtitleRepository(
      transport: transport,
      cacheDirectory: directory.path,
    );

    final match = await repository.findJapanese(
      const LearningSubtitleQuery(
        anilistId: 123,
        episode: 7,
        releaseName: '[SubsPlease] Test Show - 07 WEB-DL 1080p.mkv',
      ),
      credential: 'personal-key',
    );

    expect(match?.originalName, contains('SubsPlease'));
    expect(transport.downloadRequests.single.url.path, '/web.srt');
    expect(
      await File.fromUri(Uri.parse(match!.source)).readAsString(),
      contains('正しい版'),
    );
  });

  test('a debrid episode never defaults to differently timed NTV captions', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zeroshiru-jimaku-source-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final transport = _JimakuTransport(
      files: const [
        {
          'name':
              '[NanakoRaws] Sousou no Frieren S2 - 01 (NTV 1080p HEVC AAC).ass',
          'url': 'https://files.example/ntv.ass',
          'last_modified': '2026-06-24T00:00:00Z',
        },
        {
          'name': 'Sousou.no.Frieren.S02E01.WEBRip.Amazon.ja-jp[sdh].srt',
          'url': 'https://files.example/amazon.srt',
          'last_modified': '2026-06-24T00:00:00Z',
        },
      ],
      downloads: {
        '/ntv.ass': utf8.encode(
          '[Events]\nDialogue: 0,0:00:04,0:00:06,Default,,0,0,0,,放送版の日本語です。',
        ),
        '/amazon.srt': utf8.encode(
          '1\n00:00:01,000 --> 00:00:03,000\n配信版の日本語です。',
        ),
      },
    );
    final repository = JimakuLearningSubtitleRepository(
      transport: transport,
      cacheDirectory: directory.path,
    );
    const query = LearningSubtitleQuery(
      anilistId: 123,
      episode: 1,
      releaseName: '[EMBER] Sousou no Frieren S02E01 1080p HEVC.mkv',
    );

    final first = await repository.findJapanese(
      query,
      credential: 'personal-key',
    );
    final cached = await repository.findJapanese(query, credential: '');

    expect(first?.originalName, contains('Amazon'));
    expect(cached?.originalName, contains('Amazon'));
    expect(transport.downloadRequests.single.url.path, '/amazon.srt');
    expect(
      await File.fromUri(Uri.parse(first!.source)).readAsString(),
      contains('配信版'),
    );
  });

  test('rejects ambiguous and wrong-episode direct files even when the API returns them', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zeroshiru-jimaku-strict-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final transport = _JimakuTransport(
      files: const [
        {
          'name': 'Test Show Japanese.ass',
          'url': 'https://files.example/ambiguous.ass',
          'last_modified': '2026-08-24T00:00:00Z',
        },
        {
          'name': 'Test Show - 06.ass',
          'url': 'https://files.example/show-06.ass',
          'last_modified': '2026-08-24T00:00:00Z',
        },
      ],
      downloads: const {},
    );
    final repository = JimakuLearningSubtitleRepository(
      transport: transport,
      cacheDirectory: directory.path,
    );

    final match = await repository.findJapanese(
      const LearningSubtitleQuery(
        anilistId: 123,
        episode: 7,
        releaseName: 'Test Show - 07.mkv',
      ),
      credential: 'personal-key',
    );

    expect(match, isNull);
    expect(transport.downloadRequests, isEmpty);
  });

  test('does not reuse subtitle files from the unsafe legacy cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zeroshiru-jimaku-legacy-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final legacy = File('${directory.path}/123/7/legacy-release/wrong.ass');
    await legacy.create(recursive: true);
    await legacy.writeAsString(
      '[Events]\nDialogue: 0,0:00:01,0:00:02,Default,,0,0,0,,別の話の日本語です。',
    );
    final transport = _JimakuTransport(files: const [], downloads: const {});
    final repository = JimakuLearningSubtitleRepository(
      transport: transport,
      cacheDirectory: directory.path,
    );

    final match = await repository.findJapanese(
      const LearningSubtitleQuery(
        anilistId: 123,
        episode: 7,
        releaseName: 'Test Show - 07.mkv',
      ),
      credential: 'personal-key',
    );

    expect(match, isNull);
    expect(transport.apiRequests, isNotEmpty);
  });

  test('surfaces authentication failures without response details', () async {
    final repository = JimakuLearningSubtitleRepository(
      transport: _StatusTransport(401),
      cacheDirectory: Directory.systemTemp.path,
    );

    await expectLater(
      repository.validateCredential('bad-key'),
      throwsA(
        isA<LearningSubtitleFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              LearningSubtitleFailureKind.authentication,
            )
            .having(
              (failure) => failure.message,
              'message',
              isNot(contains('bad-key')),
            ),
      ),
    );
  });
}

class _JimakuTransport implements HttpTransport {
  _JimakuTransport({required this.files, required this.downloads});

  final List<Map<String, Object>> files;
  final Map<String, List<int>> downloads;
  final apiRequests = <HttpRequest>[];
  final downloadRequests = <HttpRequest>[];
  final fileEpisodeQueries = <String?>[];

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    if (request.url.host == 'files.example') {
      downloadRequests.add(request);
      return HttpResponse(200, const {
        'content-type': 'application/octet-stream',
      }, Uint8List.fromList(downloads[request.url.path]!));
    }
    apiRequests.add(request);
    if (request.url.path == '/api/entries/search') {
      return _jsonResponse([
        {
          'id': 9,
          'anilist_id': 123,
          'name': 'Test Show',
          'flags': {'anime': true},
          'last_modified': '2026-08-24T00:00:00Z',
        },
      ]);
    }
    if (request.url.path == '/api/entries/9/files') {
      fileEpisodeQueries.add(request.url.queryParameters['episode']);
      return _jsonResponse(files);
    }
    return HttpResponse(404, const {}, Uint8List(0));
  }

  HttpResponse _jsonResponse(Object value) => HttpResponse(200, const {
    'content-type': 'application/json',
  }, Uint8List.fromList(utf8.encode(jsonEncode(value))));
}

class _StatusTransport implements HttpTransport {
  const _StatusTransport(this.status);

  final int status;

  @override
  Future<HttpResponse> send(HttpRequest request) async =>
      HttpResponse(status, const {}, Uint8List(0));
}
