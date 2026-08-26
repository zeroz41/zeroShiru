import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/ports/ports.dart';
import 'package:zero/features/downloads/downloads_page.dart';

void main() {
  testWidgets('downloads is a complete empty state with live defaults', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/downloads',
      routes: [
        GoRoute(
          path: '/downloads',
          builder: (_, _) => const Scaffold(body: DownloadsPage()),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings-target')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(
              const Settings(
                torrentSpeedBytes: 10 * 1024 * 1024,
                maxConnections: 100,
                torrentPersist: true,
              ),
            ),
          ),
          credentialStoreProvider.overrideWithValue(_Credentials()),
        ],
        child: MaterialApp.router(
          theme: buildZeroTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No local transfers'), findsOneWidget);
    expect(find.text('10 MiB/s limit'), findsOneWidget);
    expect(find.text('100 peers'), findsOneWidget);
    expect(find.text('Keep completed files'), findsOneWidget);

    await tester.tap(find.text('Transfer settings'));
    await tester.pumpAndSettle();
    expect(find.text('settings-target'), findsOneWidget);
  });
}

class _SettingsRepository implements SettingsRepository {
  const _SettingsRepository(this.settings);

  final Settings settings;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Settings readSettings() => settings;

  @override
  T read<T>(String key, T fallback) => fallback;

  @override
  Future<void> write<T>(String key, T value) async {}

  @override
  Future<void> writeSettings(Settings settings) async {}
}

class _Credentials implements CredentialStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}
