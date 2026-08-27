import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/application/learning/subtitle_providers.dart';
import 'package:zero/application/settings/providers.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/ports/ports.dart';
import 'package:zero/features/settings/settings_page.dart';

void main() {
  testWidgets(
    'settings persist preferences and validate a key from the keyring',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final repository = _SettingsRepository(
        const Settings(debridService: DebridService.torbox),
      );
      final credentials = _Credentials();
      final debrid = _DebridClient(DebridService.torbox);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(credentials),
            debridClientsProvider.overrideWithValue({
              DebridService.torbox: debrid,
            }),
          ],
          child: MaterialApp(
            theme: buildZeroTheme(),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Interface'), findsWidgets);
      expect(find.text('Player'), findsOneWidget);
      expect(find.text('Learning'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Extensions'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Debrid'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Crimson'), findsOneWidget);
      expect(find.text('OLED'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Midnight Blue'), findsOneWidget);
      expect(find.text('Catppuccin Mocha'), findsOneWidget);
      expect(find.text('Gruvbox Dark'), findsOneWidget);
      expect(find.text('Solarized Dark'), findsOneWidget);
      expect(find.text('Everforest Dark'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-preset-midnight')));
      await tester.pumpAndSettle();
      expect(repository.current.themePreset, AppThemePreset.midnight);
      await tester.tap(find.byKey(const ValueKey('settings-section-player')));
      await tester.pumpAndSettle();
      expect(find.text('Subtitle text size'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-section-debrid')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('debrid-api-key')));
      await tester.enterText(
        find.byKey(const ValueKey('debrid-api-key')),
        '  secret-key  ',
      );
      await tester.tap(find.byKey(const ValueKey('save-test-debrid')));
      await tester.pumpAndSettle();

      expect(
        credentials.values[debridCredentialKey(DebridService.torbox)],
        'secret-key',
      );
      expect(debrid.validatedKeys, ['secret-key']);
      expect(find.text('Connected as test-user.'), findsOneWidget);
      expect(repository.writes, isNotEmpty);
      expect(
        repository.writes.last.debridApiKeys[DebridService.torbox],
        'secret-key',
      );
    },
  );

  testWidgets('a stored service key is joined into settings from credentials', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repository = _SettingsRepository(
      const Settings(debridService: DebridService.premiumize),
    );
    final credentials = _Credentials()
      ..values[debridCredentialKey(DebridService.premiumize)] = 'from-keyring';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          credentialStoreProvider.overrideWithValue(credentials),
          debridClientsProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-section-debrid')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('debrid-api-key')),
    );
    expect(field.controller?.text, 'from-keyring');
    expect(field.obscureText, isTrue);
  });

  testWidgets('compact settings use a category picker', (tester) async {
    tester.view.physicalSize = const Size(500, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(const Settings()),
          ),
          credentialStoreProvider.overrideWithValue(_Credentials()),
          debridClientsProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-section-picker')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-section-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Debrid').last);
    await tester.pumpAndSettle();

    expect(find.text('Service'), findsOneWidget);
  });

  testWidgets('Jimaku key is validated and stored only in the keyring', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final credentials = _Credentials();
    final subtitles = _LearningSubtitles();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(const Settings()),
          ),
          credentialStoreProvider.overrideWithValue(credentials),
          debridClientsProvider.overrideWithValue(const {}),
          learningSubtitleRepositoryProvider.overrideWithValue(subtitles),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-learning')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('jimaku-api-key')));
    await tester.enterText(
      find.byKey(const ValueKey('jimaku-api-key')),
      '  personal-jimaku-key  ',
    );
    await tester.tap(find.byKey(const ValueKey('save-test-jimaku')));
    await tester.pumpAndSettle();

    expect(subtitles.validated, ['personal-jimaku-key']);
    expect(credentials.values[jimakuCredentialKey], 'personal-jimaku-key');
    expect(
      find.textContaining('Missing Japanese episode tracks'),
      findsOneWidget,
    );
  });
}

class _SettingsRepository implements SettingsRepository {
  _SettingsRepository(this.current);

  Settings current;
  final writes = <Settings>[];
  final changesController = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => changesController.stream;

  @override
  Settings readSettings() => current;

  @override
  Future<void> writeSettings(Settings settings) async {
    current = settings;
    writes.add(settings);
    changesController.add(null);
  }

  @override
  T read<T>(String key, T fallback) => fallback;

  @override
  Future<void> write<T>(String key, T value) async {}
}

class _Credentials implements CredentialStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _DebridClient implements DebridClient {
  _DebridClient(this.service);

  @override
  final DebridService service;
  final validatedKeys = <String>[];

  @override
  bool get checkAddsMagnets => false;

  @override
  Future<DebridAccount> validate(String apiKey) async {
    validatedKeys.add(apiKey);
    return const DebridAccount(username: 'test-user');
  }

  @override
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  ) async => const {};

  @override
  Future<Map<String, DebridAvailabilityDetail>> inspectAvailability(
    String apiKey,
    List<String> hashes,
  ) async => const {};

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) => Future.error(UnimplementedError());

  @override
  Future<void> forgetResolved(String apiKey, String hash) async {}
}

class _LearningSubtitles implements LearningSubtitleRepository {
  final validated = <String>[];

  @override
  Future<void> validateCredential(String credential) async {
    validated.add(credential);
  }

  @override
  Future<LearningSubtitleMatch?> findJapanese(
    LearningSubtitleQuery query, {
    required String credential,
  }) async => null;
}
