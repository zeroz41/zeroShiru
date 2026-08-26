import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/settings.dart';
import '../../domain/ports/ports.dart';
import '../library/providers.dart';

final debridClientsProvider = Provider<Map<DebridService, DebridClient>>((ref) {
  throw StateError('Debrid clients were not installed at bootstrap');
});

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, Settings>(SettingsController.new);

class SettingsController extends AsyncNotifier<Settings> {
  @override
  Future<Settings> build() async {
    final repository = ref.watch(settingsRepositoryProvider);
    final credentials = ref.watch(credentialStoreProvider);
    final keys = <DebridService, String>{};
    for (final service in DebridService.values) {
      final key = await credentials.read(debridCredentialKey(service));
      if (key != null && key.isNotEmpty) keys[service] = key;
    }
    return repository.readSettings().copyWith(debridApiKeys: keys);
  }

  Future<void> persist(Settings Function(Settings current) change) async {
    final current = state.value;
    if (current == null) return;
    final next = change(current);
    state = AsyncData(next);
    try {
      await ref.read(settingsRepositoryProvider).writeSettings(next);
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }
  }

  Future<void> selectDebrid(DebridService? service) =>
      persist((settings) => settings.copyWith(debridService: service));

  Future<void> saveDebridKey(DebridService service, String value) async {
    final key = value.trim();
    final credentials = ref.read(credentialStoreProvider);
    if (key.isEmpty) {
      await credentials.delete(debridCredentialKey(service));
    } else {
      await credentials.write(debridCredentialKey(service), key);
    }
    await persist((settings) {
      final keys = Map<DebridService, String>.of(settings.debridApiKeys);
      if (key.isEmpty) {
        keys.remove(service);
      } else {
        keys[service] = key;
      }
      return settings.copyWith(debridApiKeys: keys);
    });
  }

  Future<DebridAccount> validateDebrid(DebridService service, String key) {
    final client = ref.read(debridClientsProvider)[service];
    if (client == null) {
      return Future.error(
        DebridException(
          DebridErrorKind.service,
          '${service.name} is not available in this build',
        ),
      );
    }
    return client.validate(key.trim());
  }
}
