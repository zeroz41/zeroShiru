import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/application/sources/release_language.dart';
import 'package:zeroshiru/domain/models/settings.dart';
import 'package:zeroshiru/domain/models/torrent.dart';

void main() {
  test('explicit Japanese audio and English subtitles outrank a dub', () {
    const preferred = TorrentResult(
      title: 'Show 07',
      link: 'preferred',
      audioLanguages: ['Japanese'],
      subtitleLanguages: ['English'],
    );
    const dubbed = TorrentResult(
      title: 'Show 07 English Dub',
      link: 'dubbed',
      audioLanguages: ['eng'],
      subtitleLanguages: ['eng'],
    );

    final preferredScore = releaseLanguagePreferenceScore(
      preferred,
      audioLanguage: 'jpn',
      subtitleLanguage: 'eng',
    );
    final dubbedScore = releaseLanguagePreferenceScore(
      dubbed,
      audioLanguage: 'jpn',
      subtitleLanguage: 'eng',
    );

    expect(preferredScore, greaterThan(dubbedScore));
    expect(explicitReleaseLanguageLabel(preferred), 'JA audio · EN subs');
  });

  test('filename hints are soft and follow the chosen audio language', () {
    const normal = TorrentResult(
      title: '[Group] Show - 07 1080p',
      link: 'normal',
    );
    const dual = TorrentResult(
      title: '[Group] Show - 07 Dual Audio 1080p',
      link: 'dual',
    );

    expect(
      releaseLanguagePreferenceScore(
        normal,
        audioLanguage: 'jpn',
        subtitleLanguage: 'eng',
      ),
      greaterThan(
        releaseLanguagePreferenceScore(
          normal,
          audioLanguage: 'eng',
          subtitleLanguage: 'eng',
        ),
      ),
    );
    expect(
      releaseLanguagePreferenceScore(
        dual,
        audioLanguage: 'eng',
        subtitleLanguage: 'eng',
      ),
      greaterThan(
        releaseLanguagePreferenceScore(
          normal,
          audioLanguage: 'eng',
          subtitleLanguage: 'eng',
        ),
      ),
    );
  });

  test('release subtitle priority follows the remembered player mode', () {
    const standard = Settings(
      subtitleLanguage: 'es',
      learningTranslationLanguage: 'de',
      playerSubtitleMode: 'standard',
    );
    const learning = Settings(
      subtitleLanguage: 'es',
      learningTranslationLanguage: 'de',
      playerSubtitleMode: 'learning',
    );
    const learningWithoutTranslation = Settings(
      learningShowTranslation: false,
      playerSubtitleMode: 'learning',
    );
    const off = Settings(playerSubtitleMode: 'off');

    expect(standard.releaseSubtitleLanguage, 'es');
    expect(learning.releaseSubtitleLanguage, 'de');
    expect(learningWithoutTranslation.releaseSubtitleLanguage, isNull);
    expect(off.releaseSubtitleLanguage, isNull);
  });
}
