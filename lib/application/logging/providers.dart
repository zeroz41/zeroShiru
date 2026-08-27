import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/app_log.dart';

final appLogProvider = Provider<AppLog>((ref) => const NoopAppLog());
