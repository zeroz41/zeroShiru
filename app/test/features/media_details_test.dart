import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/application/library/providers.dart';
import 'package:zeroshiru/application/settings/providers.dart';
import 'package:zeroshiru/application/sources/providers.dart';
import 'package:zeroshiru/domain/models/availability.dart';
import 'package:zeroshiru/domain/models/media.dart';
import 'package:zeroshiru/domain/models/settings.dart';
import 'package:zeroshiru/domain/models/source_extension.dart';
import 'package:zeroshiru/domain/models/torrent.dart';
import 'package:zeroshiru/domain/ports/ports.dart';
import 'package:zeroshiru/features/library/media_details.dart';

void main() {
  testWidgets('details uses a full split layout and opens TorBox in place', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const media = Media(
      id: 7,
      title: MediaTitle(userPreferred: 'Modern Details Show'),
      format: MediaFormat.tv,
      status: MediaStatus.finished,
      episodes: 12,
      duration: 24,
      averageScore: 88,
      genres: ['Adventure', 'Fantasy'],
      description: 'A real synopsis that remains readable beside the list.',
      listEntry: ListEntry(status: ListStatus.current, progress: 3),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(debridService: DebridService.torbox),
            ),
          ),
          credentialStoreProvider.overrideWithValue(
            const _Credentials('torbox-key'),
          ),
          sourceResolverProvider.overrideWithValue(const _Sources()),
          debridClientsProvider.overrideWithValue({
            DebridService.torbox: const _Debrid(),
          }),
        ],
        child: MaterialApp(
          theme: buildShiruTheme(),
          home: const MediaDetails(media: media),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Modern Details Show'), findsOneWidget);
    expect(find.text('Synopsis'), findsOneWidget);
    expect(find.text('4 of 12'), findsOneWidget);
    expect(find.text('TorBox · Episode 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('release-magnet')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('episode-4')));
    await tester.pumpAndSettle();

    expect(find.text('Test cached release 04 1080p'), findsOneWidget);
    expect(find.text('Cached'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('cached-source-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-sort')), findsOneWidget);
    expect(find.byKey(const ValueKey('release-magnet')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('source-sort')));
    await tester.pumpAndSettle();
    expect(find.text('Highest quality'), findsOneWidget);
    await tester.tap(find.text('Highest quality'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('manual-release-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('release-magnet')), findsOneWidget);
    expect(find.text('1 playable releases'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-source-results')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-results')), findsNothing);
    expect(find.byKey(const ValueKey('episode-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Sources implements SourceResolver {
  const _Sources();

  static const extension = SourceExtension(
    id: 'test',
    name: 'Test source',
    version: '1',
    origin: 'test',
    supported: true,
    enabled: true,
  );

  @override
  Future<SourceCatalog> catalog() async =>
      const SourceCatalog(extensions: [extension]);

  @override
  Stream<SourceSearchBatch> search(
    TorrentQuery query, {
    bool movie = false,
  }) => Stream.value(
    const SourceSearchBatch(
      source: extension,
      results: [
        TorrentResult(
          title: 'Test cached release 04 1080p',
          link: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          hash: '0123456789abcdef0123456789abcdef01234567',
          seeders: 42,
          size: 800000000,
        ),
      ],
    ),
  );

  @override
  Future<SourceCatalog> install(String source) => catalog();

  @override
  Future<SourceCatalog> remove(String source) => catalog();

  @override
  Future<SourceCatalog> setEnabled(String id, bool enabled) => catalog();

  @override
  Future<SourceCatalog> updateSettings(
    String id,
    Map<String, Object?> settings,
  ) => catalog();

  @override
  Future<bool> validate(String id) async => true;
}

class _Debrid implements DebridClient {
  const _Debrid();

  @override
  DebridService get service => DebridService.torbox;

  @override
  bool get checkAddsMagnets => false;

  @override
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  ) async => {for (final hash in hashes) hash: Availability.cached};

  @override
  Future<void> forgetResolved(String apiKey, String hash) async {}

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) => throw UnimplementedError();

  @override
  Future<DebridAccount> validate(String apiKey) => throw UnimplementedError();
}

class _SettingsRepository implements SettingsRepository {
  _SettingsRepository(this.settings);

  Settings settings;
  final controller = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => controller.stream;

  @override
  Settings readSettings() => settings;

  @override
  Future<void> writeSettings(Settings settings) async {
    this.settings = settings;
  }

  @override
  T read<T>(String key, T fallback) => fallback;

  @override
  Future<void> write<T>(String key, T value) async {}
}

class _Credentials implements CredentialStore {
  const _Credentials(this.value);

  final String value;

  @override
  Future<String?> read(String key) async =>
      key == debridCredentialKey(DebridService.torbox) ? value : null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
