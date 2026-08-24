import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../application/settings/providers.dart';
import '../../domain/models/debrid_route.dart';
import '../../domain/models/settings.dart';
import '../../domain/ports/debrid_client.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _SettingsError(
        message: 'Settings could not be loaded: $error',
        retry: () => ref.invalidate(settingsControllerProvider),
      ),
      data: (value) => _SettingsBody(settings: value),
    );
  }
}

class _SettingsBody extends ConsumerWidget {
  const _SettingsBody({required this.settings});

  final Settings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(settingsControllerProvider.notifier);
    return CustomScrollView(
      key: const PageStorageKey('settings-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            ShiruTokens.space6,
            ShiruTokens.space7,
            ShiruTokens.space6,
            ShiruTokens.space3,
          ),
          sliver: SliverToBoxAdapter(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                  const SizedBox(height: ShiruTokens.space2),
                  Text(
                    'Playback, library, and account preferences for this device.',
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: ShiruTokens.textLight),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            ShiruTokens.space6,
            ShiruTokens.space3,
            ShiruTokens.space6,
            ShiruTokens.space7,
          ),
          sliver: SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  children: [
                    _SettingsCard(
                      title: 'Interface',
                      icon: Icons.palette_outlined,
                      children: [
                        _DropdownRow<String>(
                          label: 'Title language',
                          description: 'Which AniList title is preferred throughout the app.',
                          value: settings.titleLanguage,
                          items: const {
                            'romaji': 'Romaji',
                            'english': 'English',
                            'native': 'Native',
                          },
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(titleLanguage: value),
                            ),
                          ),
                        ),
                        _DropdownRow<String>(
                          label: 'Poster size',
                          description:
                              'Controls how many titles fit in library rails.',
                          value: settings.cardSize,
                          items: const {
                            'small': 'Small',
                            'medium': 'Medium',
                            'large': 'Large',
                          },
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(cardSize: value),
                            ),
                          ),
                        ),
                        _SwitchRow(
                          label: 'Prefer dubbed releases',
                          description: 'Ranks dubbed source results ahead when available.',
                          value: settings.preferDubs,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(preferDubs: value),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ShiruTokens.space4),
                    _SettingsCard(
                      title: 'Player',
                      icon: Icons.play_circle_outline_rounded,
                      children: [
                        _SwitchRow(
                          label: 'Autoplay',
                          description:
                              'Begin playback after a source is ready.',
                          value: settings.playerAutoplay,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(playerAutoplay: value),
                            ),
                          ),
                        ),
                        _SwitchRow(
                          label: 'Pause when focus is lost',
                          description: 'Pause when zeroShiru is no longer the active window.',
                          value: settings.playerPauseOnLostFocus,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(
                                playerPauseOnLostFocus: value,
                              ),
                            ),
                          ),
                        ),
                        _DropdownRow<String>(
                          label: 'Audio language',
                          description:
                              'Preferred embedded audio track language.',
                          value: settings.audioLanguage,
                          items: const {
                            'jpn': 'Japanese',
                            'eng': 'English',
                            'und': 'Container default',
                          },
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(audioLanguage: value),
                            ),
                          ),
                        ),
                        _DropdownRow<String>(
                          label: 'Subtitle language',
                          description:
                              'Preferred embedded subtitle track language.',
                          value: settings.subtitleLanguage,
                          items: const {
                            'eng': 'English',
                            'jpn': 'Japanese',
                            'und': 'Container default',
                          },
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(subtitleLanguage: value),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ShiruTokens.space4),
                    _DebridCard(settings: settings),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DebridCard extends ConsumerStatefulWidget {
  const _DebridCard({required this.settings});

  final Settings settings;

  @override
  ConsumerState<_DebridCard> createState() => _DebridCardState();
}

class _DebridCardState extends ConsumerState<_DebridCard> {
  late final TextEditingController _key;
  bool _obscure = true;
  bool _working = false;
  String? _result;
  bool _resultIsError = false;

  DebridService? get _service => widget.settings.debridService;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: _configuredKey());
  }

  @override
  void didUpdateWidget(_DebridCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.debridService != widget.settings.debridService) {
      _key.text = _configuredKey();
      _result = null;
    }
  }

  String _configuredKey() =>
      _service == null ? '' : widget.settings.debridApiKeys[_service] ?? '';

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    final service = _service;
    if (service == null || _working) return;
    setState(() {
      _working = true;
      _result = null;
    });
    final controller = ref.read(settingsControllerProvider.notifier);
    try {
      await controller.saveDebridKey(service, _key.text);
      if (_key.text.trim().isEmpty) {
        if (!mounted) return;
        setState(() {
          _result = 'Credential removed from the OS keyring.';
          _resultIsError = false;
        });
      } else {
        final account = await controller.validateDebrid(service, _key.text);
        if (!mounted) return;
        setState(() {
          _result = 'Connected as ${account.username}.';
          _resultIsError = false;
        });
      }
    } on DebridException catch (error) {
      if (!mounted) return;
      setState(() {
        _result = error.message;
        _resultIsError = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _result = 'The credential could not be saved or validated.';
        _resultIsError = true;
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(settingsControllerProvider.notifier);
    final service = _service;
    return _SettingsCard(
      title: 'Debrid',
      icon: Icons.cloud_outlined,
      subtitle: 'Direct-link playback is isolated from the torrent engine. Credentials are stored in your OS keyring.',
      children: [
        _DropdownRow<DebridService?>(
          label: 'Service',
          description: 'Choose the account used to resolve cached releases.',
          value: service,
          items: {
            null: 'Disabled',
            for (final value in DebridService.values)
              value: _serviceTitle(value),
          },
          onChanged: (value) => unawaited(controller.selectDebrid(value)),
        ),
        if (service != null) ...[
          _DropdownRow<DebridMode>(
            label: 'Playback mode',
            description:
                'Prefer debrid with torrent fallback, or require debrid.',
            value: widget.settings.debridMode,
            items: const {
              DebridMode.prefer: 'Prefer debrid',
              DebridMode.only: 'Debrid only',
              DebridMode.off: 'Temporarily off',
            },
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(debridMode: value),
              ),
            ),
          ),
          _SwitchRow(
            label: 'Check cached availability',
            description:
                (ref.read(debridClientsProvider)[service]?.checkAddsMagnets ??
                    false)
                ? 'Checks may briefly add and remove magnets on this account.'
                : 'Badge releases the service can stream immediately.',
            value: widget.settings.debridCacheCheck,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(debridCacheCheck: value),
              ),
            ),
          ),
          _SwitchRow(
            label: 'Show cached releases only',
            description: 'Hide results that are not ready for immediate debrid playback.',
            value: widget.settings.debridCachedOnly,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(debridCachedOnly: value),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: ShiruTokens.space3),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final field = TextField(
                  key: const ValueKey('debrid-api-key'),
                  controller: _key,
                  obscureText: _obscure,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '${_serviceTitle(service)} API key',
                    helperText: 'Stored securely for this service only.',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show key' : 'Hide key',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => unawaited(_saveAndTest()),
                );
                final button = FilledButton.icon(
                  key: const ValueKey('save-test-debrid'),
                  onPressed: _working ? null : _saveAndTest,
                  icon: _working
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  label: const Text('Save & test'),
                );
                if (constraints.maxWidth < 580) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      field,
                      const SizedBox(height: ShiruTokens.space3),
                      button,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: ShiruTokens.space3),
                    Padding(
                      padding: const EdgeInsets.only(top: ShiruTokens.space2),
                      child: button,
                    ),
                  ],
                );
              },
            ),
          ),
          if (_result != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _result!,
                key: const ValueKey('debrid-validation-result'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _resultIsError
                      ? ShiruTokens.errorVeryLight
                      : ShiruTokens.completed,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShiruTokens.surfacePanel,
        border: Border.all(color: ShiruTokens.surfaceBorder),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: ShiruTokens.accentVeryLight),
                const SizedBox(width: ShiruTokens.space2),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: ShiruTokens.space2),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: ShiruTokens.textLight),
              ),
            ],
            const SizedBox(height: ShiruTokens.space3),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      label: label,
      description: description,
      control: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.description,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String description;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      label: label,
      description: description,
      control: DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        dropdownColor: ShiruTokens.darkLight,
        items: [
          for (final MapEntry(:key, :value) in items.entries)
            DropdownMenuItem(value: key, child: Text(value)),
        ],
        onChanged: (next) {
          if (next is T) onChanged(next);
        },
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.description,
    required this.control,
  });

  final String label;
  final String description;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: ShiruTokens.space2),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: ShiruTokens.surfaceBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: ShiruTokens.space1),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: ShiruTokens.textLight),
                ),
              ],
            ),
          ),
          const SizedBox(width: ShiruTokens.space4),
          Flexible(child: control),
        ],
      ),
    );
  }
}

class _SettingsError extends StatelessWidget {
  const _SettingsError({required this.message, required this.retry});

  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: ShiruTokens.space3),
            FilledButton(onPressed: retry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _serviceTitle(DebridService service) => switch (service) {
  DebridService.alldebrid => 'AllDebrid',
  DebridService.premiumize => 'Premiumize',
  DebridService.realdebrid => 'Real-Debrid',
  DebridService.torbox => 'TorBox',
};
