import 'dart:async';
import 'dart:io' show Platform;
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

  if (_supportsDesktopWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

  runApp(
    _ServiceHost(
      services: services,
      managesDesktopWindow: _supportsDesktopWindows,
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

  if (_supportsDesktopWindows) {
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(320, 390),
      title: 'Zero',
      backgroundColor: Colors.transparent,
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
}

bool get _supportsDesktopWindows =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

class _ServiceHost extends StatefulWidget {
  const _ServiceHost({
    required this.services,
    required this.managesDesktopWindow,
    required this.child,
  });

  final AppServices services;
  final bool managesDesktopWindow;
  final Widget child;

  @override
  State<_ServiceHost> createState() => _ServiceHostState();
}

class _ServiceHostState extends State<_ServiceHost>
    with WindowListener, WidgetsBindingObserver {
  bool _closing = false;
  bool _shutdownStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.managesDesktopWindow) windowManager.addListener(this);
  }

  @override
  void onWindowClose() {
    if (widget.managesDesktopWindow) unawaited(_closeWindow());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) unawaited(_closeServices());
  }

  Future<void> _closeWindow() async {
    if (_closing) return;
    _closing = true;
    try {
      await windowManager.hide();
      await _closeServices();
    } catch (error, stack) {
      debugPrint('Zero shutdown failed: $error\n$stack');
    } finally {
      await windowManager.destroy();
    }
  }

  Future<void> _closeServices() async {
    if (!_shutdownStarted) {
      _shutdownStarted = true;
      widget.services.log.log('info', 'app', 'Zero stopping');
    }
    await widget.services.close();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.managesDesktopWindow) windowManager.removeListener(this);
    unawaited(_closeServices());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
