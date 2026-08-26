import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/http_transport.dart';
import 'backend.dart';

final playbackBackendProvider = Provider<PlaybackBackend>((ref) {
  throw StateError('playbackBackendProvider must be overridden at bootstrap');
});

final playbackProbeTransportProvider = Provider<StreamingTransport?>((ref) {
  return null;
});
