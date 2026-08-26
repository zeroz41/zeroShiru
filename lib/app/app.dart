import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme/theme.dart';

class ZeroApp extends ConsumerWidget {
  const ZeroApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Zero',
      debugShowCheckedModeBanner: false,
      theme: buildZeroTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
