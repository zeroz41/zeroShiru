import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'application/library/providers.dart';
import 'infrastructure/bootstrap/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final services = await AppServices.open();
  services.log.log('info', 'app', 'zeroShiru starting');
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
  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(320, 390),
    title: 'zeroShiru',
    backgroundColor: Colors.transparent,
  );

  runApp(
    _ServiceHost(
      services: services,
      child: ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(services.catalog),
          trackingRepositoryProvider.overrideWithValue(services.tracking),
          settingsRepositoryProvider.overrideWithValue(services.settings),
          credentialStoreProvider.overrideWithValue(services.credentials),
        ],
        child: const ZeroShiruApp(),
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

class _ServiceHostState extends State<_ServiceHost> {
  @override
  void dispose() {
    widget.services.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
