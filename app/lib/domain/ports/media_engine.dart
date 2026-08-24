import '../models/torrent.dart';

enum PlaybackPhase {
  idle,
  opening,
  ready,
  playing,
  paused,
  buffering,
  ended,
  failed,
}

enum SubtitleRendering { standard, learning, off }

enum TrackKind { video, audio, subtitle }

class MediaTrack {
  const MediaTrack({
    required this.id,
    required this.kind,
    this.language,
    this.languageOriginal,
    this.title,
    this.codec,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.isBitmapSubtitle = false,
  });

  /// Adapter-scoped stable id for one player generation.
  final String id;
  final TrackKind kind;

  /// Normalized BCP 47 tag, or null when unknown ('und').
  final String? language;

  /// Raw container tag, kept for debugging.
  final String? languageOriginal;
  final String? title;
  final String? codec;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;
  final bool isBitmapSubtitle;
}

class Chapter {
  const Chapter({required this.title, required this.start, this.end});

  final String title;
  final Duration start;
  final Duration? end;
}

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.generation,
    required this.phase,
    this.position = Duration.zero,
    this.duration,
    this.buffered = Duration.zero,
    this.volume = 1,
    this.muted = false,
    this.speed = 1,
    this.videoWidth,
    this.videoHeight,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.selectedAudio,
    this.selectedPrimarySubtitle,
    this.selectedSecondarySubtitle,
    this.chapters = const [],
    this.subtitleRendering = SubtitleRendering.standard,
    this.error,
  });

  final int generation;
  final PlaybackPhase phase;
  final Duration position;
  final Duration? duration;
  final Duration buffered;
  final double volume;
  final bool muted;
  final double speed;
  final int? videoWidth;
  final int? videoHeight;
  final List<MediaTrack> audioTracks;
  final List<MediaTrack> subtitleTracks;
  final String? selectedAudio;
  final String? selectedPrimarySubtitle;
  final String? selectedSecondarySubtitle;
  final List<Chapter> chapters;
  final SubtitleRendering subtitleRendering;
  final Object? error;
}

class SubtitleCue {
  const SubtitleCue({
    required this.generation,
    required this.trackId,
    required this.start,
    this.end,
    required this.plainText,
  });

  final int generation;
  final String trackId;
  final Duration start;
  final Duration? end;
  final String plainText;

  /// Stale-result identity: apply async work only while this still matches.
  String get identity =>
      '$generation:$trackId:${start.inMilliseconds}:${end?.inMilliseconds}:${plainText.hashCode}';
}

class PlayerMetrics {
  const PlayerMetrics({
    this.hwdecCurrent,
    this.avsync,
    this.decoderFrameDropCount,
    this.frameDropCount,
    this.mistimedFrameCount,
    this.vsyncRatio,
    this.cacheDuration,
    this.displayFps,
    this.mediaFps,
  });

  final String? hwdecCurrent;
  final double? avsync;
  final int? decoderFrameDropCount;
  final int? frameDropCount;
  final int? mistimedFrameCount;
  final double? vsyncRatio;
  final Duration? cacheDuration;
  final double? displayFps;
  final double? mediaFps;
}

class ResumePoint {
  const ResumePoint(this.position);

  final Duration position;
}

/// The one seam between the app and any video backend (libmpv/media_kit on
/// desktop and mobile, platform players on TVs, external mpv as fallback).
/// No screen may import a media plugin directly.
abstract interface class MediaEngine {
  Stream<PlaybackSnapshot> get state;
  Stream<SubtitleCue> get primaryCues;
  Stream<SubtitleCue> get secondaryCues;
  Stream<PlayerMetrics> get metrics;

  Future<void> open(PlayerFile source, {ResumePoint? resume});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setSpeed(double speed);
  Future<void> selectAudio(String? trackId);
  Future<void> selectSubtitle(String? trackId, {bool secondary = false});
  Future<void> setSubtitleRendering(SubtitleRendering mode);
  Future<void> dispose();
}
