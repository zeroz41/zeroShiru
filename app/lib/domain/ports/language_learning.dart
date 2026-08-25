/// Local-only language-learning capabilities used by the player and settings.
///
/// The interface deliberately has no translation or LLM method. Japanese
/// subtitle text is tokenized on-device, dictionary lookup is against the
/// user's local cache, and translated lines come from subtitle tracks the
/// media already provides.
library;

enum LearningDictionaryPhase { missing, downloading, importing, ready, failed }

class LearningDictionaryStatus {
  const LearningDictionaryStatus({
    required this.phase,
    this.title,
    this.version,
    this.entryCount = 0,
    this.message,
  });

  const LearningDictionaryStatus.missing()
    : this(phase: LearningDictionaryPhase.missing);

  final LearningDictionaryPhase phase;
  final String? title;
  final String? version;
  final int entryCount;
  final String? message;

  /// Existing entries remain usable while an update is downloading or if a
  /// refresh fails; imports replace the index transactionally.
  bool get installed => phase == LearningDictionaryPhase.ready || entryCount > 0;
}

class LearningToken {
  const LearningToken({
    required this.surface,
    required this.start,
    required this.end,
    this.baseForm,
    this.reading,
    this.pronunciation,
    this.romanization,
    this.partOfSpeech,
    this.containsKanji = false,
    this.lookupable = true,
  });

  final String surface;
  final int start;
  final int end;
  final String? baseForm;
  final String? reading;
  final String? pronunciation;
  final String? romanization;
  final String? partOfSpeech;
  final bool containsKanji;
  final bool lookupable;

  String get key => '$start:$end:$surface:${baseForm ?? ''}:${reading ?? ''}';
}

class LearningDefinition {
  const LearningDefinition({
    required this.term,
    required this.definitions,
    this.reading,
    this.partsOfSpeech = const [],
  });

  final String term;
  final String? reading;
  final List<String> definitions;
  final List<String> partsOfSpeech;
}

abstract interface class LanguageLearningTools {
  LearningDictionaryStatus get dictionaryStatus;
  Stream<LearningDictionaryStatus> get dictionaryStatuses;

  /// Segments a short subtitle cue and enriches it from local language data.
  Future<List<LearningToken>> tokenizeJapanese(String text);

  /// Looks up a token only in the locally installed dictionary.
  Future<List<LearningDefinition>> lookup(LearningToken token, {int limit = 6});

  /// Downloads the freely redistributable Japanese-English dictionary and
  /// imports it into the app-support cache. No playback content is uploaded.
  Future<void> installJapaneseEnglishDictionary();

  /// Removes only the rebuildable local dictionary cache.
  Future<void> removeJapaneseEnglishDictionary();

  Future<void> dispose();
}
