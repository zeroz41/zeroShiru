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
  var _seekRequest = 0;
  var _primaryCueRequest = 0;
  var _secondaryCueRequest = 0;
  String? _blockedPrimarySubtitleText;
  String? _blockedSecondarySubtitleText;
  var _disposed = false;
  var _pollingMetrics = false;
  DateTime? _recoverableBackendErrorsThrough;

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
    _seekRequest++;
    _recoverableBackendErrorsThrough = null;
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
    _blockedPrimarySubtitleText = null;
    _blockedSecondarySubtitleText = null;
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
    final origin = _player.state.position;
    final request = ++_seekRequest;
    final generation = _generation;
    // media_kit deliberately de-duplicates equal subtitle text. Clear the app
    // cues before a discontinuous seek so an open-ended line or an in-flight
    // timing lookup cannot survive at an unrelated playback position.
    _blockedPrimarySubtitleText = _subtitleTextAt(0);
    _blockedSecondarySubtitleText = _subtitleTextAt(1);
    _clearCue(secondary: false);
    _clearCue(secondary: true);
    try {
      await _command(
        () => _player.seek(target),
        'The player could not seek to that position.',
      );
    } catch (_) {
      if (!_disposed && request == _seekRequest && generation == _generation) {
        _resumeCurrentCue(secondary: false);
        _resumeCurrentCue(secondary: true);
      }
      rethrow;
    }
    unawaited(
      _refreshCuesAfterSeek(
        request,
        generation,
        origin: origin,
        target: target,
      ),
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
    _allowTransientTrackErrors();
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
    _seekRequest++;
    _allowTransientTrackErrors();
    if (secondary) {
      if (trackId != null &&
          !_player.state.tracks.subtitle.any((e) => e.id == trackId)) {
        throw const PlaybackFailure(
          PlaybackFailureKind.unsupported,
          'That subtitle track is no longer available.',
        );
      }
      final previous = _selectedSecondary;
      _selectedSecondary = trackId;
      _blockedSecondarySubtitleText = _subtitleTextAt(1);
      _clearCue(secondary: true, trackId: trackId);
      _emit();
      final changed = await _setNativeProperty(
        'secondary-sid',
        trackId ?? 'no',
      );
      if (!changed) {
        _selectedSecondary = previous;
        _resumeCurrentCue(secondary: true);
        _emit();
        throw const PlaybackFailure(
          PlaybackFailureKind.unsupported,
          'Secondary subtitles are unavailable on this player.',
        );
      }
      final effective = await _nativeProperty('secondary-sid');
      if (effective != null &&
          !nativeTrackSelectionMatches(effective, trackId)) {
        await _setNativeProperty('secondary-sid', 'no');
        _selectedSecondary = null;
        _blockedSecondarySubtitleText = _subtitleTextAt(1);
        _clearCue(secondary: true);
        _emit();
        throw const PlaybackFailure(
          PlaybackFailureKind.backend,
          'The player selected a different secondary subtitle track.',
        );
      }
      _emit();
      return;
    }

    if (trackId != null &&
        !_player.state.tracks.subtitle.any((track) => track.id == trackId)) {
      throw const PlaybackFailure(
        PlaybackFailureKind.unsupported,
        'That subtitle track is no longer available.',
      );
    }
    _blockedPrimarySubtitleText = _subtitleTextAt(0);
    _clearCue(secondary: false, trackId: trackId);
    if (trackId == null) {
      try {
        await _command(
          () => _player.setSubtitleTrack(kit.SubtitleTrack.no()),
          'The player could not change subtitle tracks.',
        );
      } catch (_) {
        _resumeCurrentCue(secondary: false);
        rethrow;
      }
      return;
    }
    final track = _player.state.tracks.subtitle.where((e) => e.id == trackId);
    try {
      await _command(
        () => _player.setSubtitleTrack(track.first),
        'The player could not change subtitle tracks.',
      );
    } catch (_) {
      _resumeCurrentCue(secondary: false);
      rethrow;
    }
  }

  @override
  Future<void> setSubtitleRendering(SubtitleRendering mode) async {
    _ensureAlive();
    _allowTransientTrackErrors();
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
      _setNativeProperty('secondary-sid', 'no'),
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
  Future<String> addSubtitle(
    String source, {
    String? title,
    String? language,
  }) async {
    _ensureAlive();
    _seekRequest++;
    _allowTransientTrackErrors(const Duration(seconds: 3));
    if (!isAllowedSubtitleSource(source)) {
      throw const PlaybackFailure(
        PlaybackFailureKind.unsafeSource,
        'That subtitle source is unsupported or insecure.',
      );
    }
    final previousTrackIds = {
      for (final track in _player.state.tracks.subtitle) track.id,
    };
    _blockedPrimarySubtitleText = _subtitleTextAt(0);
    _clearCue(secondary: false, trackId: source);
    try {
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
    } catch (_) {
      _resumeCurrentCue(secondary: false);
      rethrow;
    }
    var loaded = loadedExternalKitSubtitleTrack(
      _player.state.tracks,
      previousTrackIds: previousTrackIds,
      title: title,
      language: language,
    );
    if (loaded == null) {
      try {
        loaded = await _player.stream.tracks
            .map(
              (tracks) => loadedExternalKitSubtitleTrack(
                tracks,
                previousTrackIds: previousTrackIds,
                title: title,
                language: language,
              ),
            )
            .firstWhere((track) => track != null)
            .timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // media_kit still selects the URI track even when libmpv takes longer
        // to publish its numeric track id. Keep playback usable and reconcile
        // on the next native track event.
      }
    }
    if (loaded != null && _player.state.track.subtitle.id != loaded.id) {
      await _command(
        () => _player.setSubtitleTrack(loaded!),
        'The subtitle file loaded but could not be selected.',
      );
    }
    // Loading a track must not re-enable libass behind the native Learning
    // overlay. Some libmpv builds adjust visibility while selecting a URI.
    await _applySubtitleVisibility();
    _emit();
    return loaded?.id ??
        selectedKitSubtitleTrackId(
          _player.state.track.subtitle.id,
          _player.state.tracks.subtitle,
        ) ??
        source;
  }

  Future<void> _applyTrackPreferences(PlaybackPreferences preferences) async {
    final audio = preferredKitTrack(
      _player.state.tracks.audio,
      preferences.audioLanguage,
      (track) => inferredTrackLanguage(track.language, track.title),
      scoreOf: (track) => automaticTrackScore(
        title: track.title,
        isDefault: track.isDefault ?? false,
      ),
    );
    final subtitle = preferredKitTrack(
      _player.state.tracks.subtitle,
      preferences.subtitleLanguage,
      (track) => inferredTrackLanguage(track.language, track.title),
      scoreOf: (track) => automaticTrackScore(
        title: track.title,
        isDefault: track.isDefault ?? false,
        subtitle: true,
      ),
    );
    // Preference failure should never make an otherwise playable file fail to
    // open. Audio keeps libmpv's default; an unavailable explicit subtitle
    // language resolves to Off rather than a different language.
    try {
      if (audio != null) await _player.setAudioTrack(audio);
    } catch (_) {}
    try {
      if (!preferences.subtitlesEnabled) {
        await _player.setSubtitleTrack(kit.SubtitleTrack.no());
      } else if (subtitle != null) {
        await _player.setSubtitleTrack(subtitle);
      } else if (hasExplicitTrackLanguagePreference(
        preferences.subtitleLanguage,
      )) {
        await _player.setSubtitleTrack(kit.SubtitleTrack.no());
      }
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
      _blockedSecondarySubtitleText = _subtitleTextAt(1);
      _clearCue(secondary: true);
    }
    _emit();
  }

  void _onBackendError(String _) {
    if (!shouldFailPlaybackForBackendError(
      phase: _phase,
      recoverableThrough: _recoverableBackendErrorsThrough,
      now: DateTime.now(),
    )) {
      // media_kit also forwards libmpv log errors from optional track changes.
      // A rejected subtitle or a brief decoder reconfigure must not replace a
      // healthy video with the full-screen fatal playback state.
      return;
    }
    _failure = const PlaybackFailure(
      PlaybackFailureKind.backend,
      'Playback stopped because the media backend reported an error.',
    );
    _phase = PlaybackPhase.failed;
    _emit();
  }

  void _allowTransientTrackErrors([
    Duration grace = const Duration(seconds: 2),
  ]) {
    final through = DateTime.now().add(grace);
    final current = _recoverableBackendErrorsThrough;
    if (current == null || through.isAfter(current)) {
      _recoverableBackendErrorsThrough = through;
    }
  }

  void _onSubtitle(List<String> text) {
    if (_disposed) return;
    final primary = text.isEmpty ? '' : text.first;
    final secondary = text.length < 2 ? '' : text[1];
    _handleSubtitleText(primary, secondary: false);
    _handleSubtitleText(secondary, secondary: true);
  }

  void _handleSubtitleText(String raw, {required bool secondary}) {
    final blocked = secondary
        ? _blockedSecondarySubtitleText
        : _blockedPrimarySubtitleText;
    if (blocked != null) {
      if (raw == blocked) return;
      if (secondary) {
        _blockedSecondarySubtitleText = null;
      } else {
        _blockedPrimarySubtitleText = null;
      }
    }
    final request = secondary ? ++_secondaryCueRequest : ++_primaryCueRequest;
    if (plainSubtitleText(raw).isEmpty) {
      _clearCue(secondary: secondary, cancelPending: false);
    } else {
      unawaited(_emitCue(raw, secondary: secondary, request: request));
    }
  }

  String _subtitleTextAt(int index) {
    final text = _player.state.subtitle;
    return index < text.length ? text[index] : '';
  }

  void _resumeCurrentCue({required bool secondary}) {
    if (secondary) {
      _blockedSecondarySubtitleText = null;
    } else {
      _blockedPrimarySubtitleText = null;
    }
    _handleSubtitleText(
      _subtitleTextAt(secondary ? 1 : 0),
      secondary: secondary,
    );
  }

  Future<void> _refreshCuesAfterSeek(
    int request,
    int generation, {
    required Duration origin,
    required Duration target,
  }) async {
    // Player.seek completes when MPV accepts the command, before demuxing is
    // guaranteed to reach the destination. In particular, `seeking` can still
    // report `no` from the old position at that point. Require the native
    // playhead to cross the requested target, then sample text on both sides
    // of its timing properties so a transition cannot combine an old line
    // with the destination's timestamps.
    var primaryRefreshed = false;
    var secondaryRefreshed = false;
    for (var attempt = 0; attempt < 60; attempt++) {
      if (_disposed || request != _seekRequest || generation != _generation) {
        return;
      }
      final seeking = await _nativeProperty('seeking', keepNo: true);
      final nativePosition = _secondsOrNull(
        _toDouble(await _nativeProperty('time-pos')),
      );
      final nativePropertiesAvailable =
          seeking != null || nativePosition != null;
      final currentPosition = nativePosition ?? _player.state.position;
      if (!seekTargetReached(
            origin: origin,
            target: target,
            current: currentPosition,
          ) ||
          (seeking != null && _nativeFlag(seeking))) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }

      if (!nativePropertiesAvailable) {
        // Web and simple test platforms do not expose MPV properties. Let
        // their state stream catch up and use its latest subtitle snapshot.
        await Future<void>.delayed(const Duration(milliseconds: 32));
        _blockedPrimarySubtitleText = null;
        _blockedSecondarySubtitleText = null;
        _handleSubtitleText(_subtitleTextAt(0), secondary: false);
        _handleSubtitleText(_subtitleTextAt(1), secondary: true);
        return;
      }

      if (!primaryRefreshed) {
        final sample = await _readNativeCueSample(secondary: false);
        if (_disposed || request != _seekRequest || generation != _generation) {
          return;
        }
        if (nativeSubtitleSampleIsCurrent(
          sample,
          position: currentPosition,
          delay: _primarySubtitleDelay,
        )) {
          _publishNativeCueSample(sample, secondary: false);
          primaryRefreshed = true;
        }
      }
      if (!secondaryRefreshed) {
        final sample = await _readNativeCueSample(secondary: true);
        if (_disposed || request != _seekRequest || generation != _generation) {
          return;
        }
        if (nativeSubtitleSampleIsCurrent(
          sample,
          position: currentPosition,
          delay: _secondarySubtitleDelay,
        )) {
          _publishNativeCueSample(sample, secondary: true);
          secondaryRefreshed = true;
        }
      }
      if (primaryRefreshed && secondaryRefreshed) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<NativeSubtitleSample> _readNativeCueSample({
    required bool secondary,
  }) async {
    final prefix = secondary ? 'secondary-sub' : 'sub';
    final textBefore = await _nativeProperty('$prefix-text', keepNo: true);
    final startSeconds = _toDouble(await _nativeProperty('$prefix-start'));
    final endSeconds = _toDouble(await _nativeProperty('$prefix-end'));
    final textAfter = await _nativeProperty('$prefix-text', keepNo: true);
    return NativeSubtitleSample(
      textBefore: textBefore,
      textAfter: textAfter,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
    );
  }

  void _publishNativeCueSample(
    NativeSubtitleSample sample, {
    required bool secondary,
  }) {
    if (_disposed) return;
    if (secondary) {
      _blockedSecondarySubtitleText = null;
      _secondaryCueRequest++;
    } else {
      _blockedPrimarySubtitleText = null;
      _primaryCueRequest++;
    }
    final plain = plainSubtitleText(sample.textAfter ?? '');
    final trackId = secondary
        ? _selectedSecondary
        : selectedKitTrackId(_player.state.track.subtitle.id);
    if (plain.isEmpty || sample.startSeconds == null || trackId == null) {
      _clearCue(secondary: secondary);
      return;
    }
    final cue = SubtitleCue(
      generation: _generation,
      trackId: trackId,
      start: _seconds(sample.startSeconds!),
      end: _secondsOrNull(sample.endSeconds),
      plainText: plain,
    );
    if (secondary) {
      _secondaryCues.add(cue);
    } else {
      _primaryCues.add(cue);
    }
  }

  void _clearCue({
    required bool secondary,
    String? trackId,
    bool cancelPending = true,
  }) {
    if (_disposed) return;
    if (cancelPending) {
      if (secondary) {
        _secondaryCueRequest++;
      } else {
        _primaryCueRequest++;
      }
    }
    final cue = SubtitleCue(
      generation: _generation,
      trackId:
          trackId ??
          (secondary
              ? _selectedSecondary
              : selectedKitTrackId(_player.state.track.subtitle.id)) ??
          'none',
      start: Duration.zero,
      end: Duration.zero,
      plainText: '',
    );
    if (secondary) {
      _secondaryCues.add(cue);
    } else {
      _primaryCues.add(cue);
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

  Future<String?> _nativeProperty(String name, {bool keepNo = false}) async {
    try {
      final dynamic platform = _player.platform;
      final value = await platform.getProperty(name);
      return _present(value?.toString(), keepNo: keepNo);
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
    _seekRequest++;
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

bool shouldFailPlaybackForBackendError({
  required PlaybackPhase phase,
  required DateTime? recoverableThrough,
  required DateTime now,
}) {
  if (phase == PlaybackPhase.idle || phase == PlaybackPhase.failed) {
    return false;
  }
  return recoverableThrough == null || !now.isBefore(recoverableThrough);
}

const _subtitleSampleTolerance = Duration(milliseconds: 250);

class NativeSubtitleSample {
  const NativeSubtitleSample({
    required this.textBefore,
    required this.textAfter,
    required this.startSeconds,
    required this.endSeconds,
  });

  final String? textBefore;
  final String? textAfter;
  final double? startSeconds;
  final double? endSeconds;
}

bool seekTargetReached({
  required Duration origin,
  required Duration target,
  required Duration current,
}) {
  if ((target - origin).abs() <= _subtitleSampleTolerance) {
    return (current - target).abs() <= _subtitleSampleTolerance;
  }
  if (target > origin) {
    return current >= target - _subtitleSampleTolerance;
  }
  return current <= target + _subtitleSampleTolerance;
}

bool nativeSubtitleSampleIsCurrent(
  NativeSubtitleSample sample, {
  required Duration position,
  Duration delay = Duration.zero,
}) {
  if (sample.textBefore != sample.textAfter) return false;
  final plain = plainSubtitleText(sample.textAfter ?? '');
  if (plain.isEmpty) return sample.startSeconds == null;
  final startSeconds = sample.startSeconds;
  if (startSeconds == null) return false;
  final effectivePosition = position - delay;
  final toleranceSeconds =
      _subtitleSampleTolerance.inMicroseconds / Duration.microsecondsPerSecond;
  final positionSeconds =
      effectivePosition.inMicroseconds / Duration.microsecondsPerSecond;
  if (positionSeconds + toleranceSeconds < startSeconds) return false;
  final endSeconds = sample.endSeconds;
  if (endSeconds != null && positionSeconds - toleranceSeconds > endSeconds) {
    return false;
  }
  return true;
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
  language: inferredTrackLanguage(track.language, track.title),
  languageOriginal: _originalLanguage(track.language),
  title: track.title,
  codec: track.codec,
  isDefault: track.isDefault ?? false,
  isExternal: track.uri,
);

MediaTrack mapSubtitleTrack(kit.SubtitleTrack track) => MediaTrack(
  id: track.id,
  kind: TrackKind.subtitle,
  language: inferredTrackLanguage(track.language, track.title),
  languageOriginal: _originalLanguage(track.language),
  title: track.title,
  codec: track.codec,
  isDefault: track.isDefault ?? false,
  isExternal: track.uri || track.data,
  isBitmapSubtitle: _bitmapSubtitleCodecs.contains(track.codec?.toLowerCase()),
);

String? selectedKitTrackId(String id) =>
    _automaticTrackIds.contains(id) ? null : id;

bool nativeTrackSelectionMatches(String effective, String? requested) {
  final value = effective.trim().toLowerCase();
  if (requested == null) return value == 'no' || value == 'none';
  return value == requested.trim().toLowerCase();
}

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

kit.SubtitleTrack? loadedExternalKitSubtitleTrack(
  kit.Tracks tracks, {
  required Set<String> previousTrackIds,
  String? title,
  String? language,
}) {
  final added = tracks.subtitle
      .where((track) => !previousTrackIds.contains(track.id))
      .toList();
  if (added.isEmpty) return null;
  final wantedTitle = title?.trim();
  if (wantedTitle != null && wantedTitle.isNotEmpty) {
    for (final track in added) {
      if (track.title?.trim() == wantedTitle) return track;
    }
  }
  final wantedLanguage = normalizeTrackLanguage(language);
  if (wantedLanguage != null) {
    final matching = added
        .where(
          (track) => normalizeTrackLanguage(track.language) == wantedLanguage,
        )
        .toList();
    if (matching.length == 1) return matching.single;
  }
  return added.length == 1 ? added.single : null;
}

String? normalizeTrackLanguage(String? raw) {
  final source = raw?.trim();
  if (source == null || source.isEmpty || source.toLowerCase() == 'und') {
    return null;
  }
  final normalized = source.replaceAll('_', '-').toLowerCase();
  const iso639 = {
    'ara': 'ar',
    'arabic': 'ar',
    'arm': 'hy',
    'hye': 'hy',
    'baq': 'eu',
    'eus': 'eu',
    'ben': 'bn',
    'bul': 'bg',
    'cat': 'ca',
    'chi': 'zh',
    'zho': 'zh',
    'chinese': 'zh',
    'cze': 'cs',
    'ces': 'cs',
    'dan': 'da',
    'dut': 'nl',
    'nld': 'nl',
    'dutch': 'nl',
    'eng': 'en',
    'english': 'en',
    'fin': 'fi',
    'fre': 'fr',
    'fra': 'fr',
    'french': 'fr',
    'ger': 'de',
    'deu': 'de',
    'german': 'de',
    'gre': 'el',
    'ell': 'el',
    'heb': 'he',
    'hin': 'hi',
    'hindi': 'hi',
    'hun': 'hu',
    'ice': 'is',
    'isl': 'is',
    'ind': 'id',
    'indonesian': 'id',
    'ita': 'it',
    'italian': 'it',
    'jp': 'ja',
    'jap': 'ja',
    'jpn': 'ja',
    'japanese': 'ja',
    'kor': 'ko',
    'korean': 'ko',
    'may': 'ms',
    'msa': 'ms',
    'nor': 'no',
    'pol': 'pl',
    'polish': 'pl',
    'por': 'pt',
    'portuguese': 'pt',
    'rum': 'ro',
    'ron': 'ro',
    'rus': 'ru',
    'russian': 'ru',
    'spa': 'es',
    'spanish': 'es',
    'swe': 'sv',
    'tha': 'th',
    'thai': 'th',
    'tur': 'tr',
    'turkish': 'tr',
    'ukr': 'uk',
    'ukrainian': 'uk',
    'vie': 'vi',
    'vietnamese': 'vi',
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
  String? Function(T track) languageOf, {
  int Function(T track)? scoreOf,
}) {
  final preferred = normalizeTrackLanguage(preferredLanguage);
  if (preferred == null) return null;
  final base = preferred.split('-').first;
  T? best;
  int? bestScore;
  for (final track in tracks) {
    final language = normalizeTrackLanguage(languageOf(track));
    final quality = language == preferred
        ? 2
        : language?.split('-').first == base
        ? 1
        : 0;
    if (quality == 0) continue;
    final score = quality * 10000 + (scoreOf?.call(track) ?? 0);
    if (bestScore == null || score > bestScore) {
      best = track;
      bestScore = score;
    }
  }
  return best;
}

bool hasExplicitTrackLanguagePreference(String? language) =>
    normalizeTrackLanguage(language) != null;

String? inferredTrackLanguage(String? language, String? title) {
  final tagged = normalizeTrackLanguage(language);
  if (tagged != null) return tagged;
  final words = RegExp(r'[a-z]{2,}')
      .allMatches(title?.toLowerCase() ?? '')
      .map((match) => match.group(0)!)
      .toSet();
  const aliases = <String, String>{
    'ja': 'ja',
    'jp': 'ja',
    'jap': 'ja',
    'jpn': 'ja',
    'japanese': 'ja',
    'en': 'en',
    'eng': 'en',
    'english': 'en',
    'es': 'es',
    'spa': 'es',
    'spanish': 'es',
    'pt': 'pt',
    'por': 'pt',
    'portuguese': 'pt',
    'de': 'de',
    'deu': 'de',
    'ger': 'de',
    'german': 'de',
    'fr': 'fr',
    'fra': 'fr',
    'fre': 'fr',
    'french': 'fr',
    'it': 'it',
    'ita': 'it',
    'italian': 'it',
    'ko': 'ko',
    'kor': 'ko',
    'korean': 'ko',
    'zh': 'zh',
    'zho': 'zh',
    'chi': 'zh',
    'chinese': 'zh',
    'ru': 'ru',
    'rus': 'ru',
    'russian': 'ru',
    'ar': 'ar',
    'ara': 'ar',
    'arabic': 'ar',
    'hi': 'hi',
    'hin': 'hi',
    'hindi': 'hi',
    'id': 'id',
    'ind': 'id',
    'indonesian': 'id',
    'nl': 'nl',
    'nld': 'nl',
    'dutch': 'nl',
    'pl': 'pl',
    'pol': 'pl',
    'polish': 'pl',
    'th': 'th',
    'tha': 'th',
    'thai': 'th',
    'tr': 'tr',
    'tur': 'tr',
    'turkish': 'tr',
    'uk': 'uk',
    'ukr': 'uk',
    'ukrainian': 'uk',
    'vi': 'vi',
    'vie': 'vi',
    'vietnamese': 'vi',
  };
  for (final word in words) {
    final inferred = aliases[word];
    if (inferred != null) return inferred;
  }
  return null;
}

int automaticTrackScore({
  String? title,
  bool isDefault = false,
  bool isForced = false,
  bool subtitle = false,
}) {
  final name = title?.toLowerCase() ?? '';
  var score = isDefault ? 25 : 0;
  if (subtitle) {
    if (RegExp(r'\b(full|dialogue|dialog|complete)\b').hasMatch(name)) {
      score += 60;
    }
    if (isForced || RegExp(r'\b(signs?|songs?|forced)\b').hasMatch(name)) {
      score -= 100;
    }
  } else {
    if (RegExp(r'\b(main|original)\b').hasMatch(name)) score += 20;
    if (RegExp(r'\b(commentary|descriptive|description)\b').hasMatch(name)) {
      score -= 100;
    }
  }
  return score;
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

String? _present(String? value, {bool keepNo = false}) {
  final text = value?.trim();
  if (text == null ||
      text.isEmpty ||
      text == 'N/A' ||
      (!keepNo && text == 'no')) {
    return null;
  }
  return text;
}

bool _nativeFlag(String value) =>
    const {'1', 'true', 'yes'}.contains(value.trim().toLowerCase());

double? _toDouble(String? value) => double.tryParse(value ?? '');

int? _toInt(String? value) => int.tryParse(value ?? '');

Duration _seconds(double value) =>
    Duration(microseconds: (value * Duration.microsecondsPerSecond).round());

Duration? _secondsOrNull(double? value) =>
    value == null ? null : _seconds(value);
