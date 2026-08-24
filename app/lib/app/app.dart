import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme/theme.dart';

class ZeroShiruApp extends ConsumerWidget {
  const ZeroShiruApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'zeroShiru',
      debugShowCheckedModeBanner: false,
      theme: buildShiruTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
