import 'dart:async';

import 'package:media_kit/media_kit.dart' as kit;

import '../../domain/models/torrent.dart';
import '../../domain/ports/media_engine.dart';

const _automaticTrackIds = {'auto', 'no'};
const _bitmapSubtitleCodecs = {
  'dvb_subtitle',
  'dvd_subtitle',
  'hdmv_pgs_subtitle',
  'pgs',
  'xsub',
};
const _sidecarSubtitleExtensions = {
  'ass',
  'idx',
  'srt',
  'ssa',
  'sub',
  'sup',
  'txt',
  'vtt',
};

/// The libmpv/media_kit implementation of the app's media capability port.
class MediaKitEngine implements MediaEngine {
  MediaKitEngine(
    this._player, {
    PlaybackPreferences Function()? defaultPreferences,
  }) : _defaultPreferences =
           defaultPreferences ?? (() => const PlaybackPreferences()) {
    final stream = _player.stream;
    _subscriptions.addAll([
      stream.playing.listen(_onPlaying),
      stream.completed.listen(_onCompleted),
      stream.position.listen((_) => _emit()),
      stream.duration.listen((_) => _emit()),
      stream.volume.listen((_) => _emit()),
      stream.rate.listen((_) => _emit()),
      stream.buffering.listen((_) => _emit()),
      stream.buffer.listen((_) => _emit()),
      stream.tracks.listen(_onTracks),
      stream.track.listen((_) => _emit()),
      stream.width.listen((_) => _emit()),
      stream.height.listen((_) => _emit()),
      stream.subtitle.listen(_onSubtitle),
      stream.error.listen(_onBackendError),
    ]);
  }

  final kit.Player _player;
  final PlaybackPreferences Function() _defaultPreferences;
  final _states = StreamController<PlaybackSnapshot>.broadcast(sync: true);
  final _primaryCues = StreamController<SubtitleCue>.broadcast(sync: true);
  final _secondaryCues = StreamController<SubtitleCue>.broadcast(sync: true);
  final _metrics = StreamController<PlayerMetrics>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription<Object?>>[];

  PlaybackPhase _phase = PlaybackPhase.idle;
  SubtitleRendering _subtitleRendering = SubtitleRendering.standard;
  PlaybackFailure? _failure;
  String? _selectedSecondary;
  Duration _primarySubtitleDelay = Duration.zero;
  Duration _secondarySubtitleDelay = Duration.zero;
  Timer? _metricTimer;
  var _generation = 0;
  var _primaryCueRequest = 0;
  var _secondaryCueRequest = 0;
  var _disposed = false;
  var _pollingMetrics = false;

  @override
  Stream<PlaybackSnapshot> get state => _states.stream;

  @override
  Stream<SubtitleCue> get primaryCues => _primaryCues.stream;

  @override
  Stream<SubtitleCue> get secondaryCues => _secondaryCues.stream;

  @override
  Stream<PlayerMetrics> get metrics => _metrics.stream;

  @override
  Future<void> open(
    PlayerFile source, {
    ResumePoint? resume,
    PlaybackPreferences? preferences,
  }) async {
    _ensureAlive();
    if (!isAllowedPlaybackSource(source.url)) {
      final failure = PlaybackFailure(
        PlaybackFailureKind.unsafeSource,
        'This media source uses an unsupported or insecure address.',
      );
      _generation++;
      _phase = PlaybackPhase.failed;
      _failure = failure;
      _emit();
      throw failure;
    }

    final generation = ++_generation;
    _phase = PlaybackPhase.opening;
    _failure = null;
    _selectedSecondary = null;
    _primarySubtitleDelay = Duration.zero;
    _secondarySubtitleDelay = Duration.zero;
    _emit();

    try {
      await _player.open(
        kit.Media(
          source.url,
          start: resume?.position,
          extras: {'title': source.name},
        ),
        play: false,
      );
      if (_disposed || generation != _generation) return;
      await _applyTrackPreferences(preferences ?? _defaultPreferences());
      await _applySubtitleState();
      if (_disposed || generation != _generation) return;
      _phase = PlaybackPhase.ready;
      _emit();
      _startMetrics();
    } catch (_) {
      if (_disposed || generation != _generation) return;
      final failure = PlaybackFailure(
        PlaybackFailureKind.opening,
        'The media could not be opened.',
      );
      _phase = PlaybackPhase.failed;
      _failure = failure;
      _emit();
      throw failure;
    }
  }

  @override
  Future<void> play() async {
    _ensureAlive();
    await _command(_player.play, 'Playback could not be started.');
    _phase = PlaybackPhase.playing;
    _failure = null;
    _emit();
  }

  @override
  Future<void> pause() async {
    _ensureAlive();
    await _command(_player.pause, 'Playback could not be paused.');
    _phase = PlaybackPhase.paused;
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureAlive();
    final duration = _player.state.duration;
    final upper = duration > Duration.zero ? duration : position;
    final target = position < Duration.zero
        ? Duration.zero
        : (position > upper ? upper : position);
    await _command(
      () => _player.seek(target),
      'The player could not seek to that position.',
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    _ensureAlive();
    await _command(
      () => _player.setVolume(volume.clamp(0, 3) * 100),
      'The player could not change volume.',
    );
  }

  @override
  Future<void> setSpeed(double speed) async {
    _ensureAlive();
    await _command(
      () => _player.setRate(speed.clamp(0.1, 16)),
      'The player could not change playback speed.',
    );
  }

  @override
  Future<void> selectAudio(String? trackId) async {
    _ensureAlive();
    if (trackId == null) {
      await _command(
        () => _player.setAudioTrack(kit.AudioTrack.auto()),
        'The player could not change audio tracks.',
      );
      return;
    }
    final track = _player.state.tracks.audio.where((e) => e.id == trackId);
    if (track.isEmpty) {
      throw const PlaybackFailure(
        PlaybackFailureKind.unsupported,
        'That audio track is no longer available.',
      );
    }
    await _command(
      () => _player.setAudioTrack(track.first),
      'The player could not change audio tracks.',
    );
  }

  @override
  Future<void> selectSubtitle(String? trackId, {bool secondary = false}) async {
    _ensureAlive();
    if (secondary) {
      if (trackId != null &&
          !_player.state.tracks.subtitle.any((e) => e.id == trackId)) {
        throw const PlaybackFailure(
          PlaybackFailureKind.unsupported,
          'That subtitle track is no longer available.',
        );
      }
      final changed = await _setNativeProperty(
        'secondary-sid',
        trackId ?? 'no',
      );
      if (!changed) {
        throw const PlaybackFailure(
          PlaybackFailureKind.unsupported,
          'Secondary subtitles are unavailable on this player.',
        );
      }
      _selectedSecondary = trackId;
      _emit();
      return;
    }

    if (trackId == null) {
      await _command(
        () => _player.setSubtitleTrack(kit.SubtitleTrack.no()),
        'The player could not change subtitle tracks.',
      );
      return;
    }
    final track = _player.state.tracks.subtitle.where((e) => e.id == trackId);
    if (track.isEmpty) {
      throw const PlaybackFailure(
        PlaybackFailureKind.unsupported,
        'That subtitle track is no longer available.',
      );
    }
    await _command(
      () => _player.setSubtitleTrack(track.first),
      'The player could not change subtitle tracks.',
    );
  }

  @override
  Future<void> setSubtitleRendering(SubtitleRendering mode) async {
    _ensureAlive();
    _subtitleRendering = mode;
    await _applySubtitleVisibility();
    _emit();
  }

  Future<void> _applySubtitleVisibility() async {
    final visible = _subtitleRendering == SubtitleRendering.standard
        ? 'yes'
        : 'no';
    await Future.wait([
      _setNativeProperty('sub-visibility', visible),
      _setNativeProperty('secondary-sub-visibility', visible),
    ]);
  }

  Future<void> _applySubtitleState() async {
    await Future.wait([
      _applySubtitleVisibility(),
      _setNativeProperty('sub-delay', '0'),
      _setNativeProperty('secondary-sub-delay', '0'),
    ]);
  }

  @override
  Future<void> setSubtitleDelay(
    Duration delay, {
    bool secondary = false,
  }) async {
    _ensureAlive();
    final seconds = delay.inMicroseconds / Duration.microsecondsPerSecond;
    final changed = await _setNativeProperty(
      secondary ? 'secondary-sub-delay' : 'sub-delay',
      seconds.toStringAsFixed(3),
    );
    if (!changed) {
      throw const PlaybackFailure(
        PlaybackFailureKind.unsupported,
        'Subtitle timing is unavailable on this player.',
      );
    }
    if (secondary) {
      _secondarySubtitleDelay = delay;
    } else {
      _primarySubtitleDelay = delay;
    }
    _emit();
  }

  @override
  Future<void> addSubtitle(
    String source, {
    String? title,
    String? language,
  }) async {
    _ensureAlive();
    if (!isAllowedSubtitleSource(source)) {
      throw const PlaybackFailure(
        PlaybackFailureKind.unsafeSource,
        'That subtitle source is unsupported or insecure.',
      );
    }
    await _command(
      () => _player.setSubtitleTrack(
        kit.SubtitleTrack.uri(
          source,
          title: title,
          language: normalizeTrackLanguage(language),
        ),
      ),
      'The subtitle file could not be loaded.',
    );
    // Loading a track must not re-enable libass behind the native Learning
    // overlay. Some libmpv builds adjust visibility while selecting a URI.
    await _applySubtitleVisibility();
    _emit();
  }

  Future<void> _applyTrackPreferences(PlaybackPreferences preferences) async {
    final audio = preferredKitTrack(
      _player.state.tracks.audio,
      preferences.audioLanguage,
      (track) => track.language,
    );
    final subtitle = preferredKitTrack(
      _player.state.tracks.subtitle,
      preferences.subtitleLanguage,
      (track) => track.language,
    );
    // Preference failure should never make an otherwise playable file fail to
    // open. libmpv's own default remains the safe fallback.
    try {
      if (audio != null) await _player.setAudioTrack(audio);
    } catch (_) {}
    try {
      if (subtitle != null) await _player.setSubtitleTrack(subtitle);
    } catch (_) {}
  }

  void _onPlaying(bool playing) {
    if (playing) {
      _phase = PlaybackPhase.playing;
    } else if (_phase == PlaybackPhase.playing && !_player.state.completed) {
      _phase = PlaybackPhase.paused;
    }
    _emit();
  }

  void _onCompleted(bool completed) {
    if (completed) _phase = PlaybackPhase.ended;
    _emit();
  }

  void _onTracks(kit.Tracks tracks) {
    if (_selectedSecondary != null &&
        !tracks.subtitle.any((track) => track.id == _selectedSecondary)) {
      _selectedSecondary = null;
    }
    _emit();
  }

  void _onBackendError(String _) {
    if (_phase == PlaybackPhase.idle || _phase == PlaybackPhase.failed) return;
    _failure = const PlaybackFailure(
      PlaybackFailureKind.backend,
      'Playback stopped because the media backend reported an error.',
    );
    _phase = PlaybackPhase.failed;
    _emit();
  }

  void _onSubtitle(List<String> text) {
    if (_disposed) return;
    final primaryRequest = ++_primaryCueRequest;
    final secondaryRequest = ++_secondaryCueRequest;
    if (text.isNotEmpty) {
      unawaited(
        _emitCue(text.first, secondary: false, request: primaryRequest),
      );
    }
    if (text.length > 1) {
      unawaited(_emitCue(text[1], secondary: true, request: secondaryRequest));
    }
  }

  Future<void> _emitCue(
    String raw, {
    required bool secondary,
    required int request,
  }) async {
    final plain = plainSubtitleText(raw);
    final trackId = secondary
        ? _selectedSecondary
        : selectedKitTrackId(_player.state.track.subtitle.id);
    if (plain.isEmpty || trackId == null) return;
    final generation = _generation;
    final prefix = secondary ? 'secondary-sub' : 'sub';
    final startSeconds = _toDouble(await _nativeProperty('$prefix-start'));
    final endSeconds = _toDouble(await _nativeProperty('$prefix-end'));
    final currentRequest = secondary
        ? _secondaryCueRequest
        : _primaryCueRequest;
    if (_disposed || generation != _generation || request != currentRequest) {
      return;
    }
    final cue = SubtitleCue(
      generation: generation,
      trackId: trackId,
      start: startSeconds == null
          ? _player.state.position
          : _seconds(startSeconds),
      end: endSeconds == null ? null : _seconds(endSeconds),
      plainText: plain,
    );
    if (secondary) {
      _secondaryCues.add(cue);
    } else {
      _primaryCues.add(cue);
    }
  }

  void _emit() {
    if (_disposed || _states.isClosed) return;
    _states.add(
      mapMediaKitState(
        _player.state,
        generation: _generation,
        phase: _phase,
        selectedSecondary: _selectedSecondary,
        subtitleRendering: _subtitleRendering,
        primarySubtitleDelay: _primarySubtitleDelay,
        secondarySubtitleDelay: _secondarySubtitleDelay,
        error: _failure,
      ),
    );
  }

  void _startMetrics() {
    _metricTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollMetrics()),
    );
    unawaited(_pollMetrics());
  }

  Future<void> _pollMetrics() async {
    if (_pollingMetrics || _disposed) return;
    _pollingMetrics = true;
    try {
      final values = await Future.wait([
        _nativeProperty('hwdec-current'),
        _nativeProperty('avsync'),
        _nativeProperty('decoder-frame-drop-count'),
        _nativeProperty('frame-drop-count'),
        _nativeProperty('mistimed-frame-count'),
        _nativeProperty('vsync-ratio'),
        _nativeProperty('demuxer-cache-duration'),
        _nativeProperty('display-fps'),
        _nativeProperty('container-fps'),
      ]);
      if (_disposed || values.every((value) => value == null)) return;
      _metrics.add(
        PlayerMetrics(
          hwdecCurrent: _present(values[0]),
          avsync: _toDouble(values[1]),
          decoderFrameDropCount: _toInt(values[2]),
          frameDropCount: _toInt(values[3]),
          mistimedFrameCount: _toInt(values[4]),
          vsyncRatio: _toDouble(values[5]),
          cacheDuration: _secondsOrNull(_toDouble(values[6])),
          displayFps: _toDouble(values[7]),
          mediaFps: _toDouble(values[8]),
        ),
      );
    } finally {
      _pollingMetrics = false;
    }
  }

  Future<bool> _setNativeProperty(String name, String value) async {
    try {
      final dynamic platform = _player.platform;
      await platform.setProperty(name, value);
      return true;
    } on NoSuchMethodError {
      return false;
    } on UnsupportedError {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _nativeProperty(String name) async {
    try {
      final dynamic platform = _player.platform;
      final value = await platform.getProperty(name);
      return _present(value?.toString());
    } on NoSuchMethodError {
      return null;
    } on UnsupportedError {
      return null;
    } catch (_) {
      return null;
    }
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('MediaKitEngine is disposed');
  }

  Future<void> _command(
    Future<void> Function() command,
    String failureMessage,
  ) async {
    try {
      await command();
    } on PlaybackFailure {
      rethrow;
    } catch (_) {
      throw PlaybackFailure(PlaybackFailureKind.backend, failureMessage);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _metricTimer?.cancel();
    PlaybackFailure? failure;
    try {
      await Future.wait([
        for (final subscription in _subscriptions) subscription.cancel(),
      ]);
      await _player.dispose();
    } catch (_) {
      failure = const PlaybackFailure(
        PlaybackFailureKind.backend,
        'The media backend did not shut down cleanly.',
      );
    } finally {
      await Future.wait([
        _states.close(),
        _primaryCues.close(),
        _secondaryCues.close(),
        _metrics.close(),
      ]);
    }
    if (failure != null) throw failure;
  }
}

PlaybackSnapshot mapMediaKitState(
  kit.PlayerState state, {
  required int generation,
  required PlaybackPhase phase,
  String? selectedSecondary,
  SubtitleRendering subtitleRendering = SubtitleRendering.standard,
  Duration primarySubtitleDelay = Duration.zero,
  Duration secondarySubtitleDelay = Duration.zero,
  Object? error,
}) {
  final effectivePhase = switch ((
    phase,
    state.completed,
    state.buffering,
    state.playing,
  )) {
    (PlaybackPhase.failed, _, _, _) => PlaybackPhase.failed,
    (PlaybackPhase.opening, _, _, _) => PlaybackPhase.opening,
    (_, true, _, _) => PlaybackPhase.ended,
    (_, _, true, _) => PlaybackPhase.buffering,
    (_, _, _, true) => PlaybackPhase.playing,
    _ => phase,
  };
  return PlaybackSnapshot(
    generation: generation,
    phase: effectivePhase,
    position: state.position,
    duration: state.duration > Duration.zero ? state.duration : null,
    buffered: state.buffer,
    volume: state.volume / 100,
    muted: state.volume <= 0,
    speed: state.rate,
    videoWidth: state.width,
    videoHeight: state.height,
    audioTracks: [
      for (final track in state.tracks.audio)
        if (!_automaticTrackIds.contains(track.id)) mapAudioTrack(track),
    ],
    subtitleTracks: [
      for (final track in state.tracks.subtitle)
        if (!_automaticTrackIds.contains(track.id)) mapSubtitleTrack(track),
    ],
    selectedAudio: selectedKitTrackId(state.track.audio.id),
    selectedPrimarySubtitle: selectedKitSubtitleTrackId(
      state.track.subtitle.id,
      state.tracks.subtitle,
    ),
    selectedSecondarySubtitle: selectedSecondary,
    subtitleRendering: subtitleRendering,
    primarySubtitleDelay: primarySubtitleDelay,
    secondarySubtitleDelay: secondarySubtitleDelay,
    error: error,
  );
}

MediaTrack mapAudioTrack(kit.AudioTrack track) => MediaTrack(
  id: track.id,
  kind: TrackKind.audio,
  language: normalizeTrackLanguage(track.language),
  languageOriginal: _originalLanguage(track.language),
  title: track.title,
  codec: track.codec,
  isDefault: track.isDefault ?? false,
  isExternal: track.uri,
);

MediaTrack mapSubtitleTrack(kit.SubtitleTrack track) => MediaTrack(
  id: track.id,
  kind: TrackKind.subtitle,
  language: normalizeTrackLanguage(track.language),
  languageOriginal: _originalLanguage(track.language),
  title: track.title,
  codec: track.codec,
  isDefault: track.isDefault ?? false,
  isExternal: track.uri || track.data,
  isBitmapSubtitle: _bitmapSubtitleCodecs.contains(track.codec?.toLowerCase()),
);

String? selectedKitTrackId(String id) =>
    _automaticTrackIds.contains(id) ? null : id;

/// libmpv may report `auto` while visibly rendering the container's default
/// subtitle. Surface that effective choice instead of presenting it as Off.
String? selectedKitSubtitleTrackId(
  String id,
  Iterable<kit.SubtitleTrack> tracks,
) {
  if (id == 'no') return null;
  if (id != 'auto') return id;
  kit.SubtitleTrack? fallback;
  for (final track in tracks) {
    if (_automaticTrackIds.contains(track.id)) continue;
    fallback ??= track;
    if (track.isDefault == true) return track.id;
  }
  return fallback?.id;
}

String? normalizeTrackLanguage(String? raw) {
  final source = raw?.trim();
  if (source == null || source.isEmpty || source.toLowerCase() == 'und') {
    return null;
  }
  final normalized = source.replaceAll('_', '-').toLowerCase();
  const iso639 = {
    'ara': 'ar',
    'arm': 'hy',
    'hye': 'hy',
    'baq': 'eu',
    'eus': 'eu',
    'ben': 'bn',
    'bul': 'bg',
    'cat': 'ca',
    'chi': 'zh',
    'zho': 'zh',
    'cze': 'cs',
    'ces': 'cs',
    'dan': 'da',
    'dut': 'nl',
    'nld': 'nl',
    'eng': 'en',
    'fin': 'fi',
    'fre': 'fr',
    'fra': 'fr',
    'ger': 'de',
    'deu': 'de',
    'gre': 'el',
    'ell': 'el',
    'heb': 'he',
    'hin': 'hi',
    'hun': 'hu',
    'ice': 'is',
    'isl': 'is',
    'ind': 'id',
    'ita': 'it',
    'jpn': 'ja',
    'kor': 'ko',
    'may': 'ms',
    'msa': 'ms',
    'nor': 'no',
    'pol': 'pl',
    'por': 'pt',
    'rum': 'ro',
    'ron': 'ro',
    'rus': 'ru',
    'spa': 'es',
    'swe': 'sv',
    'tha': 'th',
    'tur': 'tr',
    'ukr': 'uk',
    'vie': 'vi',
  };
  final parts = normalized.split('-');
  parts[0] = iso639[parts[0]] ?? parts[0];
  if (parts.length > 1 && parts[1].length == 2) {
    parts[1] = parts[1].toUpperCase();
  }
  return parts.join('-');
}

T? preferredKitTrack<T>(
  Iterable<T> tracks,
  String? preferredLanguage,
  String? Function(T track) languageOf,
) {
  final preferred = normalizeTrackLanguage(preferredLanguage);
  if (preferred == null) return null;
  final base = preferred.split('-').first;
  T? baseMatch;
  for (final track in tracks) {
    final language = normalizeTrackLanguage(languageOf(track));
    if (language == preferred) return track;
    if (baseMatch == null && language?.split('-').first == base) {
      baseMatch = track;
    }
  }
  return baseMatch;
}

String plainSubtitleText(String raw) => raw
    .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll(r'\N', '\n')
    .replaceAll(r'\n', '\n')
    .trim();

bool isAllowedPlaybackSource(String source) {
  final uri = Uri.tryParse(source);
  if (uri == null || !uri.hasScheme) return false;
  switch (uri.scheme.toLowerCase()) {
    case 'file':
      return uri.path.isNotEmpty;
    case 'https':
      return uri.host.isNotEmpty;
    case 'http':
      return const {'127.0.0.1', '::1', 'localhost'}.contains(uri.host);
    default:
      return false;
  }
}

bool isAllowedSubtitleSource(String source) {
  if (!isAllowedPlaybackSource(source)) return false;
  final uri = Uri.tryParse(source);
  if (uri == null) return false;
  final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return _sidecarSubtitleExtensions.contains(
    name.substring(dot + 1).toLowerCase(),
  );
}

String? _originalLanguage(String? raw) {
  final value = raw?.trim();
  return value == null || value.isEmpty || value.toLowerCase() == 'und'
      ? null
      : value;
}

String? _present(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty || text == 'N/A' || text == 'no') {
    return null;
  }
  return text;
}

double? _toDouble(String? value) => double.tryParse(value ?? '');

int? _toInt(String? value) => int.tryParse(value ?? '');

Duration _seconds(double value) =>
    Duration(microseconds: (value * Duration.microsecondsPerSecond).round());

Duration? _secondsOrNull(double? value) =>
    value == null ? null : _seconds(value);
