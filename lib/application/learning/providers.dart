import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/language_learning.dart';
import '../../domain/ports/vocabulary.dart';

/// Production installs the local implementation at bootstrap. The calm
/// fallback keeps isolated widget tests and unsupported hosts usable.
final languageLearningToolsProvider = Provider<LanguageLearningTools>((ref) {
  return _UnavailableLanguageLearningTools();
});

/// Optional like the other bootstrap-injected stores: without it the save
/// affordances simply do not render.
final vocabularyProvider = Provider<VocabularyRepository?>((ref) => null);

final savedWordsProvider = FutureProvider<List<SavedWord>>((ref) async {
  final vocabulary = ref.watch(vocabularyProvider);
  if (vocabulary == null) return const [];
  final subscription = vocabulary.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return vocabulary.all();
});

final learningDictionaryStatusProvider = StreamProvider.autoDispose((
  ref,
) async* {
  final tools = ref.watch(languageLearningToolsProvider);
  yield tools.dictionaryStatus;
  yield* tools.dictionaryStatuses;
});

class _UnavailableLanguageLearningTools implements LanguageLearningTools {
  @override
  String get languageCode => 'ja';

  @override
  LearningDictionaryStatus get dictionaryStatus =>
      const LearningDictionaryStatus.missing();

  @override
  Stream<LearningDictionaryStatus> get dictionaryStatuses =>
      const Stream.empty();

  @override
  Future<List<LearningToken>> tokenize(String text) async => [
    LearningToken(surface: text, start: 0, end: text.length, lookupable: false),
  ];

  @override
  Future<List<LearningDefinition>> lookup(
    LearningToken token, {
    int limit = 6,
  }) async => const [];

  @override
  Future<void> installDictionary() => Future.error(
    StateError('Language-learning storage is unavailable on this host.'),
  );

  @override
  Future<void> removeDictionary() async {}

  @override
  Future<void> dispose() async {}
}
