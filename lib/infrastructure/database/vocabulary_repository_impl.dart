import 'dart:async';
import 'dart:convert';

import '../../domain/ports/vocabulary.dart';
import 'database.dart';

/// Saved vocabulary over the durable profile database (`saved_words`,
/// created by schema v2).
class SqliteVocabularyRepository implements VocabularyRepository {
  SqliteVocabularyRepository(this._database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _database;
  final DateTime Function() _clock;
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> save(SavedWord word) async {
    final existing = await contains(word.baseForm, word.reading);
    _database.db.execute(
      '''
      INSERT INTO saved_words
        (base_form, reading, romaji, part_of_speech, glosses, context, saved_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (base_form, reading) DO UPDATE SET
        romaji = excluded.romaji,
        part_of_speech = excluded.part_of_speech,
        glosses = excluded.glosses,
        context = excluded.context
      ''',
      [
        word.baseForm,
        word.reading,
        word.romaji,
        word.partOfSpeech,
        jsonEncode(word.glosses),
        word.context,
        _clock().millisecondsSinceEpoch,
      ],
    );
    _changes.add(null);
    return !existing;
  }

  @override
  Future<void> remove(String baseForm, String reading) async {
    _database.db.execute(
      'DELETE FROM saved_words WHERE base_form = ? AND reading = ?',
      [baseForm, reading],
    );
    _changes.add(null);
  }

  @override
  Future<bool> contains(String baseForm, String reading) async {
    final rows = _database.db.select(
      'SELECT 1 FROM saved_words WHERE base_form = ? AND reading = ? LIMIT 1',
      [baseForm, reading],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<SavedWord>> all() async {
    final rows = _database.db.select(
      'SELECT * FROM saved_words ORDER BY saved_at DESC, base_form',
    );
    return [
      for (final row in rows)
        SavedWord(
          baseForm: row['base_form'] as String,
          reading: row['reading'] as String,
          romaji: row['romaji'] as String?,
          partOfSpeech: row['part_of_speech'] as String?,
          glosses: _glosses(row['glosses']),
          context: row['context'] as String?,
          savedAt: DateTime.fromMillisecondsSinceEpoch(
            row['saved_at'] as int,
          ),
        ),
    ];
  }

  @override
  Future<void> clear() async {
    _database.db.execute('DELETE FROM saved_words');
    _changes.add(null);
  }

  void dispose() {
    _changes.close();
  }

  List<String> _glosses(Object? raw) {
    if (raw is! String) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List
          ? decoded.whereType<String>().toList(growable: false)
          : const [];
    } on FormatException {
      return const [];
    }
  }
}
