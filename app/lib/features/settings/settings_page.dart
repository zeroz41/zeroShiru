import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../application/settings/providers.dart';
import '../../application/sources/providers.dart';
import '../../domain/models/debrid_route.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/source_extension.dart';
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
                            'es': 'Spanish',
                            'pt': 'Portuguese',
                            'de': 'German',
                            'fr': 'French',
                            'it': 'Italian',
                            'ko': 'Korean',
                            'zh': 'Chinese',
                            'ru': 'Russian',
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
                            'es': 'Spanish',
                            'pt': 'Portuguese',
                            'de': 'German',
                            'fr': 'French',
                            'it': 'Italian',
                            'ko': 'Korean',
                            'zh': 'Chinese',
                            'ru': 'Russian',
                            'ar': 'Arabic',
                            'hi': 'Hindi',
                            'id': 'Indonesian',
                            'pl': 'Polish',
                            'th': 'Thai',
                            'tr': 'Turkish',
                            'uk': 'Ukrainian',
                            'vi': 'Vietnamese',
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
                    _SettingsCard(
                      title: 'Sources',
                      icon: Icons.travel_explore_rounded,
                      children: [
                        _DropdownRow<String>(
                          label: 'Preferred quality',
                          description: 'Ranks matching releases first when resolving an episode.',
                          value: settings.rssQuality,
                          items: const {
                            '720': '720p',
                            '1080': '1080p',
                            '2160': '2160p',
                          },
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(rssQuality: value),
                            ),
                          ),
                        ),
                        _DropdownRow<String>(
                          label: 'Release order',
                          description: 'How equally suitable torrent releases are ranked.',
                          value: settings.torrentSort,
                          items: const {
                            'seeders': 'Seeders',
                            'quality': 'Quality',
                            'size': 'File size',
                          },
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(torrentSort: value),
                            ),
                          ),
                        ),
                        _SwitchRow(
                          label: 'Automatically inspect availability',
                          description: 'Checks candidate health before showing source choices.',
                          value: settings.torrentAutoScrape,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(torrentAutoScrape: value),
                            ),
                          ),
                        ),
                        _SwitchRow(
                          label: 'Autoplay the best release',
                          description: 'Starts the highest-ranked source without an extra prompt.',
                          value: settings.rssAutoplay,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(rssAutoplay: value),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ShiruTokens.space4),
                    const _ExtensionsCard(),
                    const SizedBox(height: ShiruTokens.space4),
                    _SettingsCard(
                      title: 'Downloads',
                      icon: Icons.download_for_offline_outlined,
                      subtitle: 'Local torrent transfers only. Direct debrid streams do not write media files here.',
                      children: [
                        _DropdownRow<int>(
                          label: 'Download rate limit',
                          description: 'Maximum local torrent download speed per session.',
                          value: settings.torrentSpeedBytes,
                          items: _rateOptions(settings.torrentSpeedBytes),
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(torrentSpeedBytes: value),
                            ),
                          ),
                        ),
                        _DropdownRow<int>(
                          label: 'Peer connections',
                          description:
                              'Upper bound for concurrent torrent peers.',
                          value: settings.maxConnections,
                          items: _numberOptions(settings.maxConnections, const [
                            25,
                            50,
                            100,
                            200,
                          ]),
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(maxConnections: value),
                            ),
                          ),
                        ),
                        _DropdownRow<int>(
                          label: 'Retained sessions',
                          description:
                              'Maximum number of transfers kept for seeding.',
                          value: settings.seedingLimit,
                          items: _numberOptions(settings.seedingLimit, const [
                            1,
                            3,
                            5,
                            10,
                          ]),
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(seedingLimit: value),
                            ),
                          ),
                        ),
                        _SwitchRow(
                          label: 'Download while streaming',
                          description: 'Retains pieces fetched ahead of the player during a session.',
                          value: settings.torrentStreamedDownload,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) => current.copyWith(
                                torrentStreamedDownload: value,
                              ),
                            ),
                          ),
                        ),
                        _SwitchRow(
                          label: 'Keep downloaded files',
                          description: 'Preserves completed local files after playback ends.',
                          value: settings.torrentPersist,
                          onChanged: (value) => unawaited(
                            controller.persist(
                              (current) =>
                                  current.copyWith(torrentPersist: value),
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

class _ExtensionsCard extends ConsumerStatefulWidget {
  const _ExtensionsCard();

  @override
  ConsumerState<_ExtensionsCard> createState() => _ExtensionsCardState();
}

class _ExtensionsCardState extends ConsumerState<_ExtensionsCard> {
  final _source = TextEditingController();
  bool _installing = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    if (_installing || _source.text.trim().isEmpty) return;
    setState(() {
      _installing = true;
      _message = null;
    });
    try {
      await ref.read(sourceCatalogProvider.notifier).install(_source.text);
      if (!mounted) return;
      _source.clear();
      setState(() {
        _message = 'Extension catalog installed. Supported sources are ready.';
        _error = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = '$error'.replaceFirst('Bad state: ', '');
        _error = true;
      });
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(sourceCatalogProvider);
    return _SettingsCard(
      title: 'Extensions',
      icon: Icons.extension_outlined,
      subtitle: 'Install Shiru JSON catalogs. Known source IDs run through native Dart adapters; extension scripts are never executed.',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: ShiruTokens.space3),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                key: const ValueKey('extension-source'),
                controller: _source,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Catalog source',
                  hintText: 'gh:Spithskia/Shiru-Extensions',
                  prefixIcon: Icon(Icons.add_link_rounded),
                ),
                onSubmitted: (_) => unawaited(_install()),
              );
              final button = FilledButton.icon(
                key: const ValueKey('install-extension'),
                onPressed: _installing ? null : _install,
                icon: _installing
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded),
                label: const Text('Install'),
              );
              if (constraints.maxWidth < 580) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    const SizedBox(height: ShiruTokens.space2),
                    button,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: ShiruTokens.space3),
                  button,
                ],
              );
            },
          ),
        ),
        if (_message != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: ShiruTokens.space2),
              child: Text(
                _message!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _error
                      ? ShiruTokens.errorVeryLight
                      : ShiruTokens.completed,
                ),
              ),
            ),
          ),
        catalog.when(
          loading: () => const LinearProgressIndicator(minHeight: 2),
          error: (error, _) => Align(
            alignment: Alignment.centerLeft,
            child: Text('Extensions could not be loaded: $error'),
          ),
          data: (value) => value.extensions.isEmpty
              ? const _EmptyExtensions()
              : Column(
                  children: [
                    for (final extension in value.extensions)
                      _ExtensionTile(extension: extension),
                    if (value.roots.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: ShiruTokens.space3),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: ShiruTokens.space2,
                            runSpacing: ShiruTokens.space2,
                            children: [
                              for (final root in value.roots)
                                InputChip(
                                  label: Text(root),
                                  avatar: const Icon(
                                    Icons.account_tree_outlined,
                                    size: 16,
                                  ),
                                  onDeleted: () => unawaited(
                                    ref
                                        .read(sourceCatalogProvider.notifier)
                                        .remove(root),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _EmptyExtensions extends StatelessWidget {
  const _EmptyExtensions();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      'No catalogs installed. Add a gh: source to restore release search.',
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: ShiruTokens.textLight),
    ),
  );
}

class _ExtensionTile extends ConsumerStatefulWidget {
  const _ExtensionTile({required this.extension});

  final SourceExtension extension;

  @override
  ConsumerState<_ExtensionTile> createState() => _ExtensionTileState();
}

class _ExtensionTileState extends ConsumerState<_ExtensionTile> {
  bool _checking = false;
  bool? _healthy;

  Future<void> _validate() async {
    setState(() => _checking = true);
    final result = await ref
        .read(sourceCatalogProvider.notifier)
        .validate(widget.extension.id);
    if (mounted) {
      setState(() {
        _checking = false;
        _healthy = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final extension = widget.extension;
    return Container(
      margin: const EdgeInsets.only(top: ShiruTokens.space2),
      decoration: BoxDecoration(
        color: ShiruTokens.darkVeryLight,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        border: Border.all(color: ShiruTokens.surfaceBorder),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: ShiruTokens.space3),
        childrenPadding: const EdgeInsets.fromLTRB(
          ShiruTokens.space3,
          0,
          ShiruTokens.space3,
          ShiruTokens.space3,
        ),
        leading: Icon(
          extension.supported ? Icons.hub_outlined : Icons.code_off_rounded,
          color: extension.supported
              ? ShiruTokens.accentVeryLight
              : ShiruTokens.warning,
        ),
        title: Row(
          children: [
            Flexible(child: Text(extension.name)),
            const SizedBox(width: ShiruTokens.space2),
            _SmallBadge(label: 'v${extension.version}'),
            if (extension.deprecated) ...[
              const SizedBox(width: ShiruTokens.space1),
              const _SmallBadge(label: 'Deprecated', warning: true),
            ],
            if (!extension.supported) ...[
              const SizedBox(width: ShiruTokens.space1),
              const _SmallBadge(
                label: 'Native adapter required',
                warning: true,
              ),
            ],
          ],
        ),
        subtitle: Text(
          [extension.speed, extension.accuracy].whereType<String>().join(' · '),
        ),
        trailing: Switch(
          value: extension.enabled,
          onChanged: extension.supported
              ? (value) => unawaited(
                  ref
                      .read(sourceCatalogProvider.notifier)
                      .setEnabled(extension.id, value),
                )
              : null,
        ),
        children: [
          if (extension.description case final description?)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                description.replaceAll(RegExp(r'<[^>]+>'), ''),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: ShiruTokens.textLight),
              ),
            ),
          for (final field in extension.fields)
            _ExtensionField(extension: extension, field: field),
          const SizedBox(height: ShiruTokens.space2),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: extension.supported && !_checking ? _validate : null,
              icon: _checking
                  ? const SizedBox.square(
                      dimension: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _healthy == null
                          ? Icons.monitor_heart_outlined
                          : _healthy!
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                    ),
              label: Text(
                _healthy == null
                    ? 'Test source'
                    : _healthy!
                    ? 'Source online'
                    : 'Source unavailable',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExtensionField extends ConsumerWidget {
  const _ExtensionField({required this.extension, required this.field});

  final SourceExtension extension;
  final ExtensionSettingField field;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = Map<String, Object?>.of(extension.settings);
    Future<void> save(Object? value) {
      values[field.key] = value;
      return ref
          .read(sourceCatalogProvider.notifier)
          .updateSettings(extension.id, values);
    }

    if (field.type == ExtensionSettingType.multiselect) {
      final selected = _selectedStrings(values[field.key]);
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: Text(
          selected.isEmpty
              ? field.description ?? 'Any language'
              : '${selected.length} selected',
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Configure ${field.label}',
          onSelected: (value) {
            selected.contains(value)
                ? selected.remove(value)
                : selected.add(value);
            unawaited(save(selected.toList()));
          },
          itemBuilder: (context) => [
            for (final option in field.options)
              CheckedPopupMenuItem(
                value: option.value,
                checked: selected.contains(option.value),
                child: Text(option.label),
              ),
          ],
        ),
      );
    }
    if (field.type == ExtensionSettingType.toggle) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: field.description == null ? null : Text(field.description!),
        value: values[field.key] == true,
        onChanged: (value) => unawaited(save(value)),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(field.label),
      subtitle: field.description == null ? null : Text(field.description!),
      trailing: DropdownButton<String>(
        value: values[field.key] as String?,
        hint: const Text('Any'),
        items: [
          for (final option in field.options)
            DropdownMenuItem(value: option.value, child: Text(option.label)),
        ],
        onChanged: (value) => unawaited(save(value)),
      ),
    );
  }
}

Set<String> _selectedStrings(Object? raw) =>
    raw is List ? raw.whereType<String>().toSet() : <String>{};

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label, this.warning = false});

  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: warning ? const Color(0x2233AE17) : ShiruTokens.surfaceHighlight,
      borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
      border: Border.all(
        color: warning ? ShiruTokens.warning : ShiruTokens.surfaceBorder,
      ),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
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

Map<int, String> _rateOptions(int current) {
  const mib = 1024 * 1024;
  final values = {current, 2 * mib, 5 * mib, 10 * mib, 25 * mib}.toList()
    ..sort();
  return {for (final value in values) value: '${value ~/ mib} MiB/s'};
}

Map<int, String> _numberOptions(int current, List<int> defaults) {
  final values = {current, ...defaults}.toList()..sort();
  return {for (final value in values) value: '$value'};
}
