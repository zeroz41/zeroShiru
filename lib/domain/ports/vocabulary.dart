/// The learning mode's saved vocabulary — words bookmarked from the subtitle
/// definition popover, kept on-device in the profile database. Deliberately
/// small: a word list with export, not a spaced-repetition system. Export
/// formats target the tools that already do that well (Anki-style TSV).
library;

class SavedWord {
  const SavedWord({
    required this.baseForm,
    this.reading = '',
    this.romaji,
    this.partOfSpeech,
    this.glosses = const [],
    this.context,
    required this.savedAt,
  });

  /// Dictionary form when known, otherwise the surface as it appeared.
  final String baseForm;

  /// Kana reading; empty string when the word had none (identity is the
  /// (baseForm, reading) pair, so null and '' must not be distinct states).
  final String reading;
  final String? romaji;
  final String? partOfSpeech;
  final List<String> glosses;

  /// The subtitle line the word was saved from.
  final String? context;
  final DateTime savedAt;
}

abstract interface class VocabularyRepository {
  /// Upserts; returns true when the word was new.
  Future<bool> save(SavedWord word);

  Future<void> remove(String baseForm, String reading);

  Future<bool> contains(String baseForm, String reading);

  /// Most recently saved first.
  Future<List<SavedWord>> all();

  Future<void> clear();

  /// Fires after any mutation.
  Stream<void> get changes;
}

/// Anki-importable TSV: word, reading, gloss line, context sentence. Fields
/// are tab-separated with one word per line, so tabs/newlines inside values
/// are flattened to spaces.
String savedWordsToAnkiTsv(List<SavedWord> words) {
  String clean(String? value) =>
      (value ?? '').replaceAll(RegExp(r'[\t\r\n]+'), ' ').trim();
  return [
    for (final word in words)
      [
        clean(word.baseForm),
        clean(word.reading),
        clean(word.glosses.join('; ')),
        clean(word.context),
      ].join('\t'),
  ].join('\n');
}
