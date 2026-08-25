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
