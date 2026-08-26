import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/settings.dart';
import '../../domain/models/torrent.dart';
import '../../domain/ports/ports.dart';
import '../library/providers.dart';

final playbackTuningStoreProvider = Provider<PlaybackTuningStore>((ref) {
  return PlaybackTuningStore(ref.watch(settingsRepositoryProvider));
});

/// Release-scoped controls whose correct value depends on a particular encode.
/// Language and subtitle mode remain ordinary global settings; timing offsets
/// must not carry from one unrelated release into another.
class PlaybackTuning {
  const PlaybackTuning({
    this.primarySubtitleDelay = Duration.zero,
    this.secondarySubtitleDelay = Duration.zero,
  });

  final Duration primarySubtitleDelay;
  final Duration secondarySubtitleDelay;

  PlaybackTuning copyWith({
    Duration? primarySubtitleDelay,
    Duration? secondarySubtitleDelay,
  }) => PlaybackTuning(
    primarySubtitleDelay: primarySubtitleDelay ?? this.primarySubtitleDelay,
    secondarySubtitleDelay:
        secondarySubtitleDelay ?? this.secondarySubtitleDelay,
  );

  Map<String, dynamic> toJson() => {
    'primarySubtitleDelayMs': primarySubtitleDelay.inMilliseconds,
    'secondarySubtitleDelayMs': secondarySubtitleDelay.inMilliseconds,
  };

  factory PlaybackTuning.fromJson(Map<String, dynamic> value) {
    int milliseconds(String key) {
      final raw = value[key];
      return raw is num ? raw.toInt().clamp(-600000, 600000) : 0;
    }

    return PlaybackTuning(
      primarySubtitleDelay: Duration(
        milliseconds: milliseconds('primarySubtitleDelayMs'),
      ),
      secondarySubtitleDelay: Duration(
        milliseconds: milliseconds('secondarySubtitleDelayMs'),
      ),
    );
  }
}

/// Builds the same language and subtitle-mode preferences for every playback
/// entry point. [subtitleMode] lets an already-open player use its live mode
/// while the bootstrap path uses the persisted one.
PlaybackPreferences playbackPreferencesFor(
  Settings settings, {
  String? subtitleMode,
}) {
  final mode = subtitleMode ?? settings.playerSubtitleMode;
  return PlaybackPreferences(
    audioLanguage: settings.audioLanguage,
    subtitleLanguage: mode == 'learning' ? 'jpn' : settings.subtitleLanguage,
    subtitlesEnabled: mode != 'off',
  );
}

class PlaybackTuningStore {
  const PlaybackTuningStore(this._settings);

  static const _prefix = 'playback_tuning_v1_';
  final SettingsRepository _settings;

  PlaybackTuning read(String identity) {
    final raw = _settings.read<Map<String, dynamic>>(_key(identity), const {});
    return PlaybackTuning.fromJson(raw);
  }

  Future<void> write(String identity, PlaybackTuning tuning) =>
      _settings.write(_key(identity), tuning.toJson());

  static String _key(String identity) =>
      '$_prefix${sha256.convert(utf8.encode(identity)).toString().substring(0, 24)}';
}

/// Never derives persistence identity from a signed playback URL. Debrid's
/// info hash and local torrent/file hashes are stable and non-secret; a named
/// release is the last safe fallback.
String? playbackTuningIdentity(PlayerFile source) {
  for (final value in [source.infoHash, source.fileHash, source.torrentName]) {
    final normalized = value?.trim().toLowerCase();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  return null;
}
