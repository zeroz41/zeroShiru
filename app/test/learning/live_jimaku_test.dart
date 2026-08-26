@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/domain/ports/learning_subtitles.dart';
import 'package:zeroshiru/infrastructure/learning/jimaku_learning_subtitle_repository.dart';
import 'package:zeroshiru/infrastructure/network/http_transport_impl.dart';

void main() {
  final apiKey = Platform.environment['ZEROSHIRU_LIVE_JIMAKU_KEY']?.trim();

  test(
    'Jimaku resolves the current exact release into Japanese episode text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zeroshiru-live-jimaku-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final transport = PackageHttpTransport();
      addTearDown(transport.close);
      final repository = JimakuLearningSubtitleRepository(
        transport: transport,
        cacheDirectory: directory.path,
      );

      await repository.validateCredential(apiKey!);
      final match = await repository.findJapanese(
        const LearningSubtitleQuery(
          anilistId: 154587,
          episode: 1,
          releaseName: '[SubsPlease] Sousou no Frieren - 01 WEB-DL 1080p.mkv',
        ),
        credential: apiKey,
      );

      expect(match, isNotNull);
      expect(match!.provider, 'Jimaku');
      expect(match.originalName, contains('SubsPlease'));
      final cached = File.fromUri(Uri.parse(match.source));
      expect(await cached.exists(), isTrue);
      final text = await cached.readAsString();
      expect(
        text.runes.any(
          (rune) =>
              (rune >= 0x3040 && rune <= 0x30ff) ||
              (rune >= 0x3400 && rune <= 0x9fff),
        ),
        isTrue,
      );
    },
    skip: apiKey == null || apiKey.isEmpty
        ? 'Set ZEROSHIRU_LIVE_JIMAKU_KEY to opt into live catalog testing.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'Jimaku resolves Naruto DarkDream from its real 7z release pack',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zeroshiru-live-jimaku-darkdream-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final transport = PackageHttpTransport();
      addTearDown(transport.close);
      final repository = JimakuLearningSubtitleRepository(
        transport: transport,
        cacheDirectory: directory.path,
      );

      final match = await repository.findJapanese(
        const LearningSubtitleQuery(
          anilistId: 20,
          episode: 3,
          releaseName: 'Naruto Complete Series + Movies (High Quality)(Dual Audio) MKV D / Naruto - 003 - Sasuke And Sakura, Friends Or Foes [DarkDream].mkv',
        ),
        credential: apiKey!,
      );

      expect(match, isNotNull);
      expect(match!.originalName, startsWith('[DarkDream]'));
      expect(match.originalName, endsWith('[DarkDream].srt'));
      final cached = File.fromUri(Uri.parse(match.source));
      expect(await cached.exists(), isTrue);
      expect(await cached.length(), greaterThan(1000));
    },
    skip: apiKey == null || apiKey.isEmpty
        ? 'Set ZEROSHIRU_LIVE_JIMAKU_KEY to opt into live catalog testing.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
