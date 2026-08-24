/// CredentialStore over flutter_secure_storage (the OS keyring: libsecret on
/// Linux, Keychain on macOS, Keystore on Android).
///
/// Standing contract: API keys are NEVER written to the settings kv table.
/// This store is the only place a debrid key or tracker token is persisted;
/// the settings codec has no field for them, so the two paths cannot cross.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/ports/ports.dart';

class SecureCredentialStore implements CredentialStore {
  /// [storage] is injectable so tests can hand in a fake.
  const SecureCredentialStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  /// One key per debrid service — switching services never loses a key, and
  /// no key is ever sent to another service's API.
  static String debridKeyFor(DebridService service) =>
      'debrid_api_key_${service.name}';

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
