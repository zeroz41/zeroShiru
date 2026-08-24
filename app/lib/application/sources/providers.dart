import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/source_extension.dart';
import '../../domain/ports/ports.dart';

final sourceResolverProvider = Provider<SourceResolver?>((ref) => null);

final sourceCatalogProvider =
    AsyncNotifierProvider<SourceCatalogController, SourceCatalog>(
      SourceCatalogController.new,
    );

class SourceCatalogController extends AsyncNotifier<SourceCatalog> {
  SourceResolver? get _resolver => ref.read(sourceResolverProvider);

  @override
  Future<SourceCatalog> build() async {
    return await _resolver?.catalog() ?? const SourceCatalog();
  }

  Future<void> install(String source) =>
      _update((resolver) => resolver.install(source), loading: true);

  Future<void> remove(String source) =>
      _update((resolver) => resolver.remove(source));

  Future<void> setEnabled(String id, bool enabled) =>
      _update((resolver) => resolver.setEnabled(id, enabled));

  Future<void> updateSettings(String id, Map<String, Object?> values) =>
      _update((resolver) => resolver.updateSettings(id, values));

  Future<bool> validate(String id) async =>
      await _resolver?.validate(id) ?? false;

  Future<void> _update(
    Future<SourceCatalog> Function(SourceResolver resolver) run, {
    bool loading = false,
  }) async {
    final resolver = _resolver;
    if (resolver == null) throw StateError('Source resolver is unavailable.');
    final previous = state;
    if (loading) state = const AsyncLoading();
    try {
      state = AsyncData(await run(resolver));
    } catch (error, stack) {
      state = AsyncError(error, stack);
      if (!loading && previous.hasValue) state = previous;
      rethrow;
    }
  }
}
