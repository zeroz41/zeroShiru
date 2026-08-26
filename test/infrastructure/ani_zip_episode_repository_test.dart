import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/infrastructure/tracking/ani_zip_episode_repository.dart';

import 'test_support.dart';

void main() {
  test(
    'AniZip episode rows retain artwork, copy, duration, and fallbacks',
    () async {
      final transport = ScriptTransport([
        answer(200, '''
        {
          "episodeCount": 3,
          "episodes": {
            "1": {
              "episodeNumber": 1,
              "title": {"en": "The First Step", "jp": "Hajimari"},
              "summary": "A clean episode summary.",
              "image": "https://images.example/episode-1.jpg",
              "length": 24,
              "airdate": "2025-01-02"
            },
            "2": {
              "episodeNumber": 2,
              "title": {"en": "A Second Step"}
            }
          }
        }
      '''),
      ]);
      final repository = AniZipEpisodeRepository(transport);
      const media = Media(
        id: 42,
        title: MediaTitle(userPreferred: 'Test Show'),
        episodes: 3,
        duration: 25,
        bannerImage: 'https://images.example/banner.jpg',
      );

      final episodes = await repository.episodes(media);

      expect(transport.asked.single.url.host, 'api.ani.zip');
      expect(transport.asked.single.url.queryParameters['anilist_id'], '42');
      expect(episodes, hasLength(3));
      expect(episodes.first.title, 'The First Step');
      expect(episodes.first.summary, 'A clean episode summary.');
      expect(episodes.first.durationMinutes, 24);
      expect(episodes.first.airDate, DateTime(2025, 1, 2));
      expect(episodes[1].title, 'A Second Step');
      expect(episodes[1].imageUrl, media.bannerImage);
      expect(episodes[2].durationMinutes, 25);
    },
  );
}
