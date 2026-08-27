import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/sources/best_source.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/models/torrent.dart';

void main() {
  test('a proven cached release wins before softer torrent signals', () {
    const cached = TorrentResult(
      title: 'Show 01 720p',
      link: 'cached',
      seeders: 3,
    );
    const swarm = TorrentResult(
      title: 'Show 01 1080p',
      link: 'swarm',
      seeders: 500,
    );

    final ranked = rankBestSources(
      [swarm, cached],
      preferences: const Settings(rssQuality: '1080'),
      availability: (release) =>
          release == cached ? Availability.cached : Availability.unknown,
    );

    expect(ranked.first, same(cached));
  });

  test('language and configured resolution beat raw seeder count', () {
    const popularDub = TorrentResult(
      title: 'Show 01 English Dub 720p',
      link: 'popular-dub',
      seeders: 800,
      audioLanguages: ['eng'],
      subtitleLanguages: ['eng'],
    );
    const preferred = TorrentResult(
      title: 'Show 01 1080p',
      link: 'preferred',
      seeders: 12,
      audioLanguages: ['jpn'],
      subtitleLanguages: ['eng'],
    );

    final ranked = rankBestSources(
      [popularDub, preferred],
      preferences: const Settings(
        rssQuality: '1080',
        audioLanguage: 'jpn',
        subtitleLanguage: 'eng',
      ),
      availability: (_) => Availability.unknown,
    );

    expect(ranked.first, same(preferred));
  });

  test('healthy swarm wins when higher-priority signals tie', () {
    const quiet = TorrentResult(
      title: 'Show 01 1080p',
      link: 'quiet',
      seeders: 4,
    );
    const healthy = TorrentResult(
      title: 'Show 01 1080p',
      link: 'healthy',
      seeders: 40,
    );

    final ranked = rankBestSources(
      [quiet, healthy],
      preferences: const Settings(torrentSort: 'seeders'),
      availability: (_) => Availability.unknown,
    );

    expect(ranked.first, same(healthy));
  });

  test('new quality tiers are recognized and exact preference wins', () {
    const exact = TorrentResult(
      title: 'Show 01 1440p',
      link: 'exact',
      seeders: 2,
    );
    const popular = TorrentResult(
      title: 'Show 01 2160p',
      link: 'popular',
      seeders: 200,
    );

    final ranked = rankBestSources(
      [popular, exact],
      preferences: const Settings(rssQuality: '1440'),
      availability: (_) => Availability.unknown,
    );

    expect(sourceQuality('Show 01 480p'), 480);
    expect(sourceQuality('Show 01 1440p'), 1440);
    expect(ranked.first, same(exact));
  });

  test('peer ratio and recency break otherwise equal release ties', () {
    final congested = TorrentResult(
      title: 'Show 01 1080p',
      link: 'congested',
      seeders: 10,
      leechers: 100,
      date: DateTime(2026),
    );
    final healthy = TorrentResult(
      title: 'Show 01 1080p',
      link: 'healthy',
      seeders: 10,
      leechers: 2,
      date: DateTime(2025),
    );

    final ranked = rankBestSources(
      [congested, healthy],
      preferences: const Settings(),
      availability: (_) => Availability.unknown,
    );

    expect(ranked.first, same(healthy));
  });
}
