import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/language_learning.dart';

/// Production installs the local implementation at bootstrap. The calm
/// fallback keeps isolated widget tests and unsupported hosts usable.
final languageLearningToolsProvider = Provider<LanguageLearningTools>((ref) {
  return _UnavailableLanguageLearningTools();
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
  LearningDictionaryStatus get dictionaryStatus =>
      const LearningDictionaryStatus.missing();

  @override
  Stream<LearningDictionaryStatus> get dictionaryStatuses =>
      const Stream.empty();

  @override
  Future<List<LearningToken>> tokenizeJapanese(String text) async => [
    LearningToken(surface: text, start: 0, end: text.length, lookupable: false),
  ];

  @override
  Future<List<LearningDefinition>> lookup(
    LearningToken token, {
    int limit = 6,
  }) async => const [];

  @override
  Future<void> installJapaneseEnglishDictionary() => Future.error(
    StateError('Language-learning storage is unavailable on this host.'),
  );

  @override
  Future<void> removeJapaneseEnglishDictionary() async {}

  @override
  Future<void> dispose() async {}
}
