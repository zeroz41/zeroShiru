@Tags(['live'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/infrastructure/learning/local_japanese_learning_tools.dart';
import 'package:zero/domain/ports/http_transport.dart';

void main() {
  final archivePath = Platform.environment['ZERO_JMDICT_ARCHIVE']?.trim();

  test(
    'the current JMdict Yomitan artifact imports and enriches real cues',
    () async {
      final archive = File(archivePath!);
      expect(await archive.exists(), isTrue, reason: archive.path);
      final directory = await Directory.systemTemp.createTemp(
        'zero-live-jmdict-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final databasePath = '${directory.path}/learning.db';

      final importWatch = Stopwatch()..start();
      final count = importYomitanDictionary(
        databasePath: databasePath,
        archiveBytes: Uint8List.fromList(await archive.readAsBytes()),
      );
      importWatch.stop();
      expect(count, greaterThan(100000));

      final tools = LocalJapaneseLearningTools(
        databasePath: databasePath,
        transport: _NoNetworkTransport(),
      );
      addTearDown(tools.dispose);
      expect(tools.dictionaryStatus.installed, isTrue);
      expect(tools.dictionaryStatus.entryCount, count);

      final lookupWatch = Stopwatch()..start();
      final tokens = await tools.tokenizeJapanese(
        '昨日、友達と寿司を食べました。日本語を勉強しています。',
      );
      lookupWatch.stop();
      expect(
        tokens.map((token) => token.surface).join(),
        '昨日、友達と寿司を食べました。日本語を勉強しています。',
      );
      final verb = tokens.firstWhere((token) => token.baseForm == '食べる');
      expect(verb.surface, '食べました');
      expect(verb.reading, 'たべる');
      final study = tokens.firstWhere((token) => token.surface == '勉強しています');
      expect(study.baseForm, '勉強');
      expect(study.surface, '勉強しています');
      expect(study.reading, 'べんきょう');
      expect(study.partOfSpeech, contains('する verb'));
      final definitionWatch = Stopwatch()..start();
      final definitions = await tools.lookup(verb);
      definitionWatch.stop();
      expect(
        definitions.expand((entry) => entry.definitions),
        anyElement(contains('eat')),
      );
      expect(lookupWatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(definitionWatch.elapsed, lessThan(const Duration(seconds: 1)));

      // Kept visible in an opt-in run so dependency/release updates can be
      // compared without turning machine-specific timing into a CI gate.
      // ignore: avoid_print
      print(
        'JMdict: $count terms, import ${importWatch.elapsed}, '
        'cue lookup ${lookupWatch.elapsed}, '
        'definition lookup ${definitionWatch.elapsed}, '
        'SQLite ${await File(databasePath).length()} bytes',
      );
    },
    skip: archivePath == null || archivePath.isEmpty
        ? 'Set ZERO_JMDICT_ARCHIVE to a downloaded JMdict_english.zip.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

class _NoNetworkTransport implements HttpTransport {
  @override
  Future<HttpResponse> send(HttpRequest request) =>
      Future.error(StateError('network access was not expected'));
}
