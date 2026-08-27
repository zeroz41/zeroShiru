import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'application/library/providers.dart';
import 'application/learning/providers.dart';
import 'application/learning/subtitle_providers.dart';
import 'application/logging/providers.dart';
import 'application/playback/providers.dart';
import 'application/settings/providers.dart';
import 'application/sources/providers.dart';
import 'infrastructure/bootstrap/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final services = await AppServices.open();
  services.log.log('info', 'app', 'Zero starting');
  FlutterError.onError = (details) {
    services.log.log(
      'error',
      'flutter',
      '${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    services.log.log('error', 'platform', '$error\n$stack');
    return true;
  };

  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(320, 390),
    title: 'Zero',
    backgroundColor: Colors.transparent,
  );

  runApp(
    _ServiceHost(
      services: services,
      child: ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(services.catalog),
          episodeRepositoryProvider.overrideWithValue(services.episodes),
          trackingRepositoryProvider.overrideWithValue(services.tracking),
          settingsRepositoryProvider.overrideWithValue(services.settings),
          sourceResolverProvider.overrideWithValue(services.sources),
          credentialStoreProvider.overrideWithValue(services.credentials),
          playbackBackendProvider.overrideWithValue(services.playback),
          appLogProvider.overrideWithValue(services.log),
          languageLearningToolsProvider.overrideWithValue(services.learning),
          learningSubtitleRepositoryProvider.overrideWithValue(
            services.learningSubtitles,
          ),
          playbackProbeTransportProvider.overrideWithValue(
            services.playbackProbe,
          ),
          debridClientsProvider.overrideWithValue(services.debrid),
        ],
        child: const ZeroApp(),
      ),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      }),
    );
  });
}

class _ServiceHost extends StatefulWidget {
  const _ServiceHost({required this.services, required this.child});

  final AppServices services;
  final Widget child;

  @override
  State<_ServiceHost> createState() => _ServiceHostState();
}

class _ServiceHostState extends State<_ServiceHost> with WindowListener {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void onWindowClose() {
    unawaited(_closeWindow());
  }

  Future<void> _closeWindow() async {
    if (_closing) return;
    _closing = true;
    try {
      widget.services.log.log('info', 'app', 'Zero stopping');
      await windowManager.hide();
      await widget.services.close();
    } catch (error, stack) {
      debugPrint('Zero shutdown failed: $error\n$stack');
    } finally {
      await windowManager.destroy();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    unawaited(widget.services.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
