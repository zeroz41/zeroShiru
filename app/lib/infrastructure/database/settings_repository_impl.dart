/// SettingsRepository over the kv table of the per-profile database.
///
/// Values are stored JSON-encoded per key. The whole Settings model rides on
/// one well-known key via [readSettings]/[writeSettings] (the shape the redo
/// branch kept in GENERAL:settings), while individual keys stay available
/// for lightweight flags.
///
/// Standing contract: API keys and tokens NEVER land in this table — they
/// belong to the CredentialStore. Credential-shaped keys are refused loudly
/// rather than stored quietly.
library;

import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/settings.dart';
import '../../domain/ports/ports.dart';
import 'database.dart';
import 'settings_codec.dart';

class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(AppDatabase database) : _db = database.db;

  static const settingsKey = 'settings';

  /// Key shapes that smell like a credential. Storing one here is a bug in
  /// the caller, not a request to be honored.
  static final _credentialish = RegExp(
    'api[_-]?key|token|secret|password|bearer',
    caseSensitive: false,
  );

  final Database _db;
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  T read<T>(String key, T fallback) {
    final rows = _db.select('SELECT value FROM kv WHERE key = ?', [key]);
    if (rows.isEmpty) return fallback;
    final dynamic decoded;
    try {
      decoded = jsonDecode(rows.first['value'] as String);
    } on FormatException {
      return fallback;
    }
    if (decoded is T) return decoded;
    // JSON has one number type; hand back what was asked for.
    if (fallback is double && decoded is num) return decoded.toDouble() as T;
    if (fallback is int && decoded is num) return decoded.toInt() as T;
    return fallback;
  }

  @override
  Future<void> write<T>(String key, T value) async {
    if (_credentialish.hasMatch(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'credential-shaped settings keys are refused: API keys and tokens '
            'belong in the CredentialStore (OS keyring), never the kv table',
      );
    }
    _db.execute(
      'INSERT INTO kv (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [key, jsonEncode(value)],
    );
    _changes.add(null);
  }

  /// The typed Settings model, decoded from [settingsKey]. Note that the
  /// result never carries API keys — the application layer joins those back
  /// in from the CredentialStore with `copyWith(debridApiKeys: ...)`.
  Settings readSettings() {
    final json = read<Map<String, dynamic>>(settingsKey, const {});
    return settingsFromJson(json);
  }

  /// Persists the typed model. toJson has no debridApiKeys field, so keys in
  /// the in-memory Settings can never reach the database through this path.
  Future<void> writeSettings(Settings settings) =>
      write(settingsKey, settings.toJson());

  void dispose() {
    _changes.close();
  }
}
