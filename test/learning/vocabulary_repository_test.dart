import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/ports/vocabulary.dart';
import 'package:zero/infrastructure/database/database.dart';
import 'package:zero/infrastructure/database/vocabulary_repository_impl.dart';

void main() {
  late AppDatabase database;
  late SqliteVocabularyRepository vocabulary;
  var now = DateTime(2026, 8, 27, 21);

  setUp(() {
    database = AppDatabase.inMemory();
    vocabulary = SqliteVocabularyRepository(database, clock: () => now);
  });

  tearDown(() {
    vocabulary.dispose();
    database.close();
  });

  SavedWord word({
    String baseForm = '食べる',
    String reading = 'たべる',
    List<String> glosses = const ['to eat'],
    String? context = '彼は寿司を食べたい。',
  }) => SavedWord(
    baseForm: baseForm,
    reading: reading,
    romaji: 'taberu',
    partOfSpeech: 'v1',
    glosses: glosses,
    context: context,
    savedAt: now,
  );

  test('save, contains, list, and remove round-trip', () async {
    expect(await vocabulary.save(word()), isTrue);
    expect(await vocabulary.contains('食べる', 'たべる'), isTrue);
    expect(await vocabulary.contains('食べる', ''), isFalse);

    final all = await vocabulary.all();
    expect(all.single.baseForm, '食べる');
    expect(all.single.glosses, ['to eat']);
    expect(all.single.romaji, 'taberu');
    expect(all.single.context, '彼は寿司を食べたい。');

    await vocabulary.remove('食べる', 'たべる');
    expect(await vocabulary.all(), isEmpty);
  });

  test('re-saving updates the entry without duplicating it', () async {
    expect(await vocabulary.save(word()), isTrue);
    expect(
      await vocabulary.save(word(glosses: ['to eat', 'to live on'])),
      isFalse,
    );
    final all = await vocabulary.all();
    expect(all, hasLength(1));
    expect(all.single.glosses, ['to eat', 'to live on']);
  });

  test('listing is most recent first and clear empties it', () async {
    await vocabulary.save(word());
    now = now.add(const Duration(minutes: 1));
    await vocabulary.save(word(baseForm: '寿司', reading: 'すし'));
    final all = await vocabulary.all();
    expect(all.first.baseForm, '寿司');

    var notified = 0;
    final subscription = vocabulary.changes.listen((_) => notified++);
    addTearDown(subscription.cancel);
    await vocabulary.clear();
    await Future<void>.delayed(Duration.zero);
    expect(await vocabulary.all(), isEmpty);
    expect(notified, 1);
  });

  test('Anki TSV export flattens embedded tabs and newlines', () {
    final tsv = savedWordsToAnkiTsv([
      word(context: 'line one\nline\ttwo'),
      word(baseForm: '寿司', reading: 'すし', glosses: ['sushi']),
    ]);
    final lines = tsv.split('\n');
    expect(lines, hasLength(2));
    expect(lines.first, '食べる\tたべる\tto eat\tline one line two');
    expect(lines.last.split('\t'), ['寿司', 'すし', 'sushi', '彼は寿司を食べたい。']);
  });
}
