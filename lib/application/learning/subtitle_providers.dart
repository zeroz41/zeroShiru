import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/learning_subtitles.dart';
import '../library/providers.dart';

const jimakuCredentialKey = 'learning.jimaku.api_key';

/// Installed by the production composition root. A nullable fallback keeps
/// platforms without the downloader and isolated widget tests calm.
final learningSubtitleRepositoryProvider =
    Provider<LearningSubtitleRepository?>((ref) => null);

final jimakuConnectionProvider =
    AsyncNotifierProvider<JimakuConnectionController, String?>(
      JimakuConnectionController.new,
    );

class JimakuConnectionController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final value = await ref
        .watch(credentialStoreProvider)
        .read(jimakuCredentialKey);
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> connect(String value) async {
    final credential = value.trim();
    if (credential.isEmpty) return disconnect();
    final repository = ref.read(learningSubtitleRepositoryProvider);
    if (repository == null) {
      throw StateError('Automatic Japanese subtitles are unavailable.');
    }
    final previous = state;
    state = const AsyncLoading();
    try {
      await repository.validateCredential(credential);
      await ref
          .read(credentialStoreProvider)
          .write(jimakuCredentialKey, credential);
      state = AsyncData(credential);
    } catch (error, stack) {
      state = previous.hasValue
          ? AsyncData(previous.value)
          : AsyncError(error, stack);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await ref.read(credentialStoreProvider).delete(jimakuCredentialKey);
    state = const AsyncData(null);
  }
}
