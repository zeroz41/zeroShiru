import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zero/domain/ports/language_learning.dart';
import 'package:zero/infrastructure/learning/local_japanese_learning_tools.dart';
import 'package:zero/domain/ports/http_transport.dart';

void main() {
  test('kana helpers provide readable local annotations', () {
    expect(katakanaToHiragana('ニホンゴ'), 'にほんご');
    expect(hiraganaToKatakana('にほんご'), 'ニホンゴ');
    expect(kanaToRomaji('べんきょうする'), 'benkyousuru');
    expect(kanaToRomaji('ガッコウ'), 'gakkou');
  });

  test('segments retain subtitle punctuation and source offsets', () {
    final tokens = learningTokensFromSegments('日本語、です。', ['日本語', 'です']);

    expect(tokens.map((token) => token.surface).join(), '日本語、です。');
    expect(tokens.first.reading, isNull);
    expect(tokens.first.containsKanji, isTrue);
    expect(tokens[1].lookupable, isFalse);
    expect(tokens[2].reading, 'です');
    expect(tokens[2].romanization, 'desu');
    expect(tokens.last.end, '日本語、です。'.length);
  });

  test('the bundled segmenter handles a subtitle cue without warmup', () async {
    final directory = await Directory.systemTemp.createTemp('zero-tokenizer-');
    addTearDown(() => directory.delete(recursive: true));
    final tools = LocalJapaneseLearningTools(
      databasePath: '${directory.path}/learning.db',
      transport: _NoNetworkTransport(),
    );
    addTearDown(tools.dispose);

    final tokens = await tools.tokenizeJapanese('彼は寿司を食べたい。');

    expect(tokens.map((token) => token.surface).join(), '彼は寿司を食べたい。');
    expect(tokens.where((token) => token.lookupable), isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 2)));

  test('common inflections produce dictionary-verified base candidates', () {
    expect(japaneseLookupCandidates('食べました'), contains('食べる'));
    expect(japaneseLookupCandidates('書かない'), contains('書く'));
    expect(japaneseLookupCandidates('高かった'), contains('高い'));
    expect(japaneseLookupCandidates('勉強しています'), contains('勉強する'));
    final iru = japaneseLookupCandidates('います');
    expect(iru.indexOf('いる'), lessThan(iru.indexOf('う')));
  });

  test('install and remove publish a replaceable offline cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zero-jmdict-install-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final tools = LocalJapaneseLearningTools(
      databasePath: '${directory.path}/learning.db',
      transport: _BytesTransport(_testDictionaryBytes()),
    );
    addTearDown(tools.dispose);
    final phases = <LearningDictionaryPhase>[];
    final subscription = tools.dictionaryStatuses.listen(
      (status) => phases.add(status.phase),
    );
    addTearDown(subscription.cancel);

    await tools.installJapaneseEnglishDictionary();
    await Future<void>.delayed(Duration.zero);

    expect(tools.dictionaryStatus.installed, isTrue);
    expect(tools.dictionaryStatus.entryCount, 2);
    expect(
      phases,
      containsAllInOrder([
        LearningDictionaryPhase.downloading,
        LearningDictionaryPhase.importing,
        LearningDictionaryPhase.ready,
      ]),
    );
    final definitions = await tools.lookup(
      const LearningToken(surface: '食べました', start: 0, end: 5),
    );
    expect(definitions.first.term, '食べる');
    expect(definitions.first.definitions, contains('to eat'));

    await tools.removeJapaneseEnglishDictionary();
    expect(tools.dictionaryStatus.phase, LearningDictionaryPhase.missing);
  });

  test('Yomitan term banks import into a replaceable SQLite cache', () async {
    final directory = await Directory.systemTemp.createTemp('zero-jmdict-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/learning.db';

    final count = importYomitanDictionary(
      databasePath: path,
      archiveBytes: _testDictionaryBytes(),
    );

    expect(count, 2);
    final db = sqlite3.open(path);
    addTearDown(db.close);
    final rows = db.select(
      'SELECT term, reading, definitions, rules FROM learning_terms ORDER BY term',
    );
    expect(rows, hasLength(2));
    expect(rows.last['term'], '食べる');
    expect(jsonDecode(rows.first['definitions'] as String), [
      'Japanese language',
    ]);
    expect(jsonDecode(rows.last['rules'] as String), ['v1']);
    expect(
      db
          .select(
            "SELECT value FROM learning_dictionary_meta WHERE key = 'revision'",
          )
          .single['value'],
      'test-2026-08',
    );

    final tools = LocalJapaneseLearningTools(
      databasePath: path,
      transport: _NoNetworkTransport(),
    );
    addTearDown(tools.dispose);
    final tokens = await tools.tokenizeJapanese('寿司を食べたい。');
    final verb = tokens.firstWhere((token) => token.baseForm == '食べる');
    expect(verb.surface, '食べたい');
    expect(verb.reading, 'たべる');
    expect(verb.romanization, 'taberu');
    expect(verb.partOfSpeech, 'ichidan verb');
  });
}

Uint8List _testDictionaryBytes() {
  final archive = Archive()
    ..add(
      ArchiveFile.string(
        'index.json',
        jsonEncode({'title': 'JMdict English', 'revision': 'test-2026-08'}),
      ),
    )
    ..add(
      ArchiveFile.string(
        'term_bank_1.json',
        jsonEncode([
          [
            '食べる',
            'たべる',
            '',
            'v1',
            8,
            ['to eat', 'to live on'],
            1001,
            '',
          ],
          [
            '日本語',
            'にほんご',
            'n',
            '',
            10,
            [
              {
                'type': 'structured-content',
                'content': [
                  {
                    'tag': 'ul',
                    'data': {'content': 'glossary'},
                    'content': {'tag': 'li', 'content': 'Japanese language'},
                  },
                  {
                    'tag': 'ul',
                    'data': {'content': 'references'},
                    'content': {'tag': 'li', 'content': 'internal reference'},
                  },
                ],
              },
            ],
            1002,
            '',
          ],
        ]),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

class _NoNetworkTransport implements HttpTransport {
  @override
  Future<HttpResponse> send(HttpRequest request) =>
      Future.error(StateError('network access was not expected'));
}

class _BytesTransport implements HttpTransport {
  const _BytesTransport(this.bytes);

  final Uint8List bytes;

  @override
  Future<HttpResponse> send(HttpRequest request) async =>
      HttpResponse(200, const {'content-type': 'application/zip'}, bytes);
}
