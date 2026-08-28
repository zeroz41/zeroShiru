import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/theme.dart';
import '../../app/theme/tokens.dart';
import '../../application/learning/providers.dart';
import '../../application/learning/subtitle_providers.dart';
import '../../application/settings/providers.dart';
import '../../application/sources/providers.dart';
import '../../domain/models/debrid_route.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/source_extension.dart';
import '../../domain/ports/debrid_client.dart';
import '../../domain/ports/language_learning.dart';
import '../../domain/ports/learning_subtitles.dart';
import '../../domain/ports/vocabulary.dart';

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

enum _SettingsSection {
  interface,
  player,
  learning,
  sources,
  extensions,
  downloads,
  debrid,
}

const _audioLanguageOptions = {
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
};

const _subtitleLanguageOptions = {
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
};

extension on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.interface => 'Interface',
    _SettingsSection.player => 'Player',
    _SettingsSection.learning => 'Learning',
    _SettingsSection.sources => 'Sources',
    _SettingsSection.extensions => 'Extensions',
    _SettingsSection.downloads => 'Downloads',
    _SettingsSection.debrid => 'Debrid',
  };

  String get description => switch (this) {
    _SettingsSection.interface => 'Titles, posters, and language',
    _SettingsSection.player => 'Playback behavior and tracks',
    _SettingsSection.learning => 'Interactive Japanese subtitles',
    _SettingsSection.sources => 'Quality and release ranking',
    _SettingsSection.extensions => 'Installed source catalogs',
    _SettingsSection.downloads => 'Transfers and local retention',
    _SettingsSection.debrid => 'Direct-link streaming',
  };

  IconData get icon => switch (this) {
    _SettingsSection.interface => Icons.palette_outlined,
    _SettingsSection.player => Icons.play_circle_outline_rounded,
    _SettingsSection.learning => Icons.school_outlined,
    _SettingsSection.sources => Icons.travel_explore_rounded,
    _SettingsSection.extensions => Icons.extension_outlined,
    _SettingsSection.downloads => Icons.download_for_offline_outlined,
    _SettingsSection.debrid => Icons.cloud_outlined,
  };
}

class _SettingsBody extends ConsumerStatefulWidget {
  const _SettingsBody({required this.settings});

  final Settings settings;

  @override
  ConsumerState<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<_SettingsBody> {
  _SettingsSection _selected = _SettingsSection.interface;

  Settings get settings => widget.settings;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(settingsControllerProvider.notifier);
    final pages = <Widget>[
      _SettingsCard(
        title: 'Interface',
        icon: Icons.palette_outlined,
        children: [
          _ThemePicker(
            selected: settings.themePreset,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(themePreset: value),
              ),
            ),
          ),
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
                (current) => current.copyWith(titleLanguage: value),
              ),
            ),
          ),
          _DropdownRow<String>(
            label: 'Poster size',
            description: 'Controls how many titles fit in library rails.',
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
        ],
      ),
      _SettingsCard(
        title: 'Player',
        icon: Icons.play_circle_outline_rounded,
        children: [
          _SwitchRow(
            label: 'Autoplay',
            description: 'Begin playback after a source is ready.',
            value: settings.playerAutoplay,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(playerAutoplay: value),
              ),
            ),
          ),
          _SwitchRow(
            label: 'Pause when focus is lost',
            description: 'Pause when Zero is no longer the active window.',
            value: settings.playerPauseOnLostFocus,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(playerPauseOnLostFocus: value),
              ),
            ),
          ),
          _DropdownRow<double>(
            label: 'Subtitle text size',
            description:
                'Applies immediately to Styled and Learning text subtitles.',
            value: settings.subtitleTextScale,
            items: {
              0.85: 'Compact',
              1.0: 'Comfortable',
              1.2: 'Large',
              1.4: 'Extra large',
            },
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(subtitleTextScale: value),
              ),
            ),
          ),
        ],
      ),
      _LearningSettingsCard(settings: settings),
      _SettingsCard(
        title: 'Sources',
        icon: Icons.travel_explore_rounded,
        children: [
          _DropdownRow<String>(
            label: 'Preferred audio language',
            description: 'Ranks releases with this audio first and selects the matching embedded track for playback.',
            value: settings.audioLanguage,
            items: _audioLanguageOptions,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(audioLanguage: value),
              ),
            ),
          ),
          _DropdownRow<String>(
            label: 'Preferred subtitle language',
            description: 'Ranks releases with these subtitles first and selects the matching embedded track.',
            value: settings.subtitleLanguage,
            items: _subtitleLanguageOptions,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(subtitleLanguage: value),
              ),
            ),
          ),
          _DropdownRow<String>(
            label: 'Preferred quality',
            description:
                'Ranks matching releases first when resolving an episode.',
            value: settings.rssQuality,
            items: const {
              '480': '480p',
              '720': '720p',
              '1080': '1080p',
              '1440': '1440p',
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
            description:
                'Checks candidate health before showing source choices.',
            value: settings.torrentAutoScrape,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(torrentAutoScrape: value),
              ),
            ),
          ),
          _SwitchRow(
            label: 'Autoplay the best release',
            description:
                'Starts the highest-ranked source without an extra prompt.',
            value: settings.rssAutoplay,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(rssAutoplay: value),
              ),
            ),
          ),
        ],
      ),
      const _ExtensionsCard(),
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
                (current) => current.copyWith(torrentSpeedBytes: value),
              ),
            ),
          ),
          _DropdownRow<int>(
            label: 'Peer connections',
            description: 'Upper bound for concurrent torrent peers.',
            value: settings.maxConnections,
            items: _numberOptions(settings.maxConnections, const [
              25,
              50,
              100,
              200,
            ]),
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(maxConnections: value),
              ),
            ),
          ),
          _DropdownRow<int>(
            label: 'Retained sessions',
            description: 'Maximum number of transfers kept for seeding.',
            value: settings.seedingLimit,
            items: _numberOptions(settings.seedingLimit, const [1, 3, 5, 10]),
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(seedingLimit: value),
              ),
            ),
          ),
          _SwitchRow(
            label: 'Download while streaming',
            description:
                'Retains pieces fetched ahead of the player during a session.',
            value: settings.torrentStreamedDownload,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(torrentStreamedDownload: value),
              ),
            ),
          ),
          _SwitchRow(
            label: 'Keep downloaded files',
            description: 'Preserves completed local files after playback ends.',
            value: settings.torrentPersist,
            onChanged: (value) => unawaited(
              controller.persist(
                (current) => current.copyWith(torrentPersist: value),
              ),
            ),
          ),
        ],
      ),
      _DebridCard(settings: settings),
    ];

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SettingsHeader(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 760;
                final content = _SettingsPages(
                  selected: _selected,
                  pages: pages,
                );
                if (compact) {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          ZeroTokens.space5,
                          0,
                          ZeroTokens.space5,
                          ZeroTokens.space3,
                        ),
                        child: _CompactSettingsMenu(
                          selected: _selected,
                          onSelected: _select,
                        ),
                      ),
                      Expanded(child: content),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingsMenu(selected: _selected, onSelected: _select),
                    const VerticalDivider(width: 1),
                    Expanded(child: content),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _select(_SettingsSection section) {
    if (section == _selected) return;
    setState(() => _selected = section);
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ZeroTokens.space6,
        ZeroTokens.space6,
        ZeroTokens.space6,
        ZeroTokens.space5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.displayMedium),
          const SizedBox(height: ZeroTokens.space2),
          Text(
            'Playback, library, and account preferences for this device.',
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: context.zeroPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({required this.selected, required this.onSelected});

  final _SettingsSection selected;
  final ValueChanged<_SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      color: context.zeroPalette.shell.withValues(alpha: 0.27),
      padding: const EdgeInsets.fromLTRB(
        ZeroTokens.space4,
        ZeroTokens.space5,
        ZeroTokens.space4,
        ZeroTokens.space5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: ZeroTokens.space3),
            child: Text(
              'PREFERENCES',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: context.zeroPalette.textMuted,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: ZeroTokens.space3),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final section in _SettingsSection.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: ZeroTokens.space1),
                    child: _SettingsMenuItem(
                      section: section,
                      selected: section == selected,
                      onTap: () => onSelected(section),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(ZeroTokens.space3),
            child: Text(
              'Changes save automatically on this device.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: context.zeroPalette.textMuted, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsMenuItem extends StatelessWidget {
  const _SettingsMenuItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('settings-section-${section.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : ZeroTokens.motionQuick,
            curve: ZeroTokens.easeSettle,
            padding: const EdgeInsets.symmetric(
              horizontal: ZeroTokens.space3,
              vertical: ZeroTokens.space3,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
              color: selected
                  ? context.zeroPalette.navSelected
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? context.zeroPalette.navSelectedBorder
                    : Colors.transparent,
              ),
              boxShadow: selected ? context.zeroPalette.navigationGlow : null,
            ),
            child: Row(
              children: [
                Icon(
                  section.icon,
                  size: 20,
                  color: selected
                      ? context.zeroPalette.accentSoft
                      : context.zeroPalette.textMuted,
                ),
                const SizedBox(width: ZeroTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.label,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: selected
                              ? context.zeroPalette.text
                              : context.zeroPalette.textSecondary,
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        section.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSettingsMenu extends StatelessWidget {
  const _CompactSettingsMenu({
    required this.selected,
    required this.onSelected,
  });

  final _SettingsSection selected;
  final ValueChanged<_SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.zeroPalette.panelStrong,
        border: Border.all(color: context.zeroPalette.border),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZeroTokens.space3),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<_SettingsSection>(
            key: const ValueKey('settings-section-picker'),
            value: selected,
            isExpanded: true,
            borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
            dropdownColor: context.zeroPalette.surface,
            icon: const Icon(Icons.expand_more_rounded),
            items: [
              for (final section in _SettingsSection.values)
                DropdownMenuItem(
                  value: section,
                  child: Row(
                    children: [
                      Icon(section.icon, size: 19),
                      const SizedBox(width: ZeroTokens.space3),
                      Text(section.label),
                    ],
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) onSelected(value);
            },
          ),
        ),
      ),
    );
  }
}

class _SettingsPages extends StatelessWidget {
  const _SettingsPages({required this.selected, required this.pages});

  final _SettingsSection selected;
  final List<Widget> pages;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: selected.index,
      children: [
        for (var i = 0; i < pages.length; i++)
          SingleChildScrollView(
            key: PageStorageKey('settings-${_SettingsSection.values[i].name}'),
            padding: const EdgeInsets.fromLTRB(
              ZeroTokens.space5,
              ZeroTokens.space3,
              ZeroTokens.space5,
              ZeroTokens.space7,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: pages[i],
              ),
            ),
          ),
      ],
    );
  }
}

class _LearningSettingsCard extends ConsumerStatefulWidget {
  const _LearningSettingsCard({required this.settings});

  final Settings settings;

  @override
  ConsumerState<_LearningSettingsCard> createState() =>
      _LearningSettingsCardState();
}

class _LearningSettingsCardState extends ConsumerState<_LearningSettingsCard> {
  bool _working = false;
  String? _message;

  Future<void> _install() async {
    if (_working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await ref.read(languageLearningToolsProvider).installDictionary();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'JMdict could not be installed. Check your connection and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _remove() async {
    if (_working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await ref.read(languageLearningToolsProvider).removeDictionary();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message =
              'JMdict could not be removed. Close playback and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final controller = ref.read(settingsControllerProvider.notifier);
    final status =
        ref.watch(learningDictionaryStatusProvider).value ??
        ref.read(languageLearningToolsProvider).dictionaryStatus;
    return _SettingsCard(
      title: 'Language learning',
      icon: Icons.school_outlined,
      subtitle: 'An opt-in subtitle workspace. Standard playback and authored ASS styling remain unchanged.',
      children: [
        _DropdownRow<String>(
          label: 'Translation language',
          description: 'The second text subtitle track paired with the original Japanese line.',
          value: settings.learningTranslationLanguage,
          items: const {
            'eng': 'English',
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
          },
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningTranslationLanguage: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Pair Japanese tracks automatically',
          description: 'When Learning is selected, pair Japanese text with the chosen translation without changing your audio language.',
          value: settings.learningAutoSelectTracks,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningAutoSelectTracks: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Fetch missing Japanese text automatically',
          description: 'When Learning is selected, use the episode identity to download and cache a Japanese text track if the release has none.',
          value: settings.learningAutoFetchJapaneseSubtitles,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) =>
                  current.copyWith(learningAutoFetchJapaneseSubtitles: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Show Japanese text',
          description: 'Keep the original kanji and kana line visible.',
          value: settings.learningShowJapanese,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningShowJapanese: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Show kana readings',
          description:
              'Show kana alone or above kanji when both layers are on.',
          value: settings.learningShowFurigana,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningShowFurigana: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Show romaji',
          description: 'Add a compact romanized reading below each word.',
          value: settings.learningShowRomaji,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningShowRomaji: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Show translation',
          description: 'Display the aligned secondary subtitle line.',
          value: settings.learningShowTranslation,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningShowTranslation: value),
            ),
          ),
        ),
        _SwitchRow(
          label: 'Pause on word lookup',
          description: 'Freeze playback the first time a word is highlighted, focused, or tapped in each line.',
          value: settings.learningPauseOnLookup,
          onChanged: (value) => unawaited(
            controller.persist(
              (current) => current.copyWith(learningPauseOnLookup: value),
            ),
          ),
        ),
        const SizedBox(height: ZeroTokens.space3),
        const _JimakuPanel(),
        const SizedBox(height: ZeroTokens.space3),
        _DictionaryPanel(
          status: status,
          working: _working,
          message: _message,
          onInstall: _install,
          onRemove: _remove,
        ),
        const SizedBox(height: ZeroTokens.space3),
        const _SavedWordsPanel(),
      ],
    );
  }
}

/// Words bookmarked from the player's definition popover: review, remove,
/// export for Anki, or clear. Hidden entirely when no vocabulary store is
/// installed.
class _SavedWordsPanel extends ConsumerStatefulWidget {
  const _SavedWordsPanel();

  @override
  ConsumerState<_SavedWordsPanel> createState() => _SavedWordsPanelState();
}

class _SavedWordsPanelState extends ConsumerState<_SavedWordsPanel> {
  String? _message;

  Future<void> _copyForAnki(List<SavedWord> words) async {
    await Clipboard.setData(ClipboardData(text: savedWordsToAnkiTsv(words)));
    if (mounted) {
      setState(() {
        _message =
            '${words.length} word${words.length == 1 ? '' : 's'} copied as '
            'tab-separated text. In Anki choose Import and paste it into a '
            'text file.';
      });
    }
  }

  Future<void> _clear(VocabularyRepository vocabulary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear saved words?'),
        content: const Text('Every bookmarked word is removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await vocabulary.clear();
  }

  @override
  Widget build(BuildContext context) {
    final vocabulary = ref.watch(vocabularyProvider);
    if (vocabulary == null) return const SizedBox.shrink();
    final words = ref.watch(savedWordsProvider).value ?? const <SavedWord>[];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.zeroPalette.surfaceRaised,
        border: Border.all(color: context.zeroPalette.border),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bookmarks_outlined,
                  color: context.zeroPalette.accentSoft,
                ),
                const SizedBox(width: ZeroTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Saved words',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        words.isEmpty
                            ? 'Bookmark words from the Learning definition popover to collect them here.'
                            : '${words.length} word${words.length == 1 ? '' : 's'} saved on this device.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (words.isNotEmpty) ...[
                  TextButton.icon(
                    key: const ValueKey('saved-words-copy'),
                    onPressed: () => unawaited(_copyForAnki(words)),
                    icon: const Icon(Icons.copy_all_rounded, size: 17),
                    label: const Text('Copy for Anki'),
                  ),
                  IconButton(
                    tooltip: 'Clear saved words',
                    onPressed: () => unawaited(_clear(vocabulary)),
                    icon: const Icon(Icons.delete_outline_rounded, size: 19),
                  ),
                ],
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: ZeroTokens.space2),
              Text(_message!, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (words.isNotEmpty) ...[
              const SizedBox(height: ZeroTokens.space2),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const ValueKey('saved-words-list'),
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Review words',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  children: [
                    for (final word in words.take(200))
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: ZeroTokens.space2,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    word.reading.isEmpty ||
                                            word.reading == word.baseForm
                                        ? word.baseForm
                                        : '${word.baseForm} · ${word.reading}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                  if (word.glosses.isNotEmpty)
                                    Text(
                                      word.glosses.join('; '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => unawaited(
                                vocabulary.remove(word.baseForm, word.reading),
                              ),
                              icon: const Icon(Icons.close_rounded, size: 16),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _JimakuPanel extends ConsumerStatefulWidget {
  const _JimakuPanel();

  @override
  ConsumerState<_JimakuPanel> createState() => _JimakuPanelState();
}

class _JimakuPanelState extends ConsumerState<_JimakuPanel> {
  late final TextEditingController _key;
  bool _obscure = true;
  bool _working = false;
  bool _edited = false;
  String? _message;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController();
    unawaited(() async {
      final configured = await ref.read(jimakuConnectionProvider.future);
      if (!mounted || _edited || configured == null) return;
      _key.text = configured;
    }());
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await ref.read(jimakuConnectionProvider.notifier).connect(_key.text);
      if (!mounted) return;
      setState(() {
        _message = _key.text.trim().isEmpty
            ? 'Jimaku disconnected; cached subtitles remain available.'
            : 'Connected. Missing Japanese episode tracks will be fetched automatically.';
        _error = false;
      });
    } on LearningSubtitleFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _message = failure.message;
        _error = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message =
            'Jimaku could not be connected. Check the key and connection.';
        _error = true;
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _disconnect() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await ref.read(jimakuConnectionProvider.notifier).disconnect();
      _key.clear();
      if (!mounted) return;
      setState(() {
        _message = 'Jimaku disconnected; cached subtitles remain available.';
        _error = false;
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(jimakuConnectionProvider);
    final connected = connection.value?.isNotEmpty ?? false;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.zeroPalette.surfaceRaised,
        border: Border.all(color: context.zeroPalette.border),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.cloud_done_outlined : Icons.cloud_outlined,
                  color: connected
                      ? context.zeroPalette.success
                      : context.zeroPalette.accentSoft,
                ),
                const SizedBox(width: ZeroTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Automatic Japanese subtitles · Jimaku',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        connected ? 'Connected securely' : 'Not connected',
                        key: const ValueKey('jimaku-connection-status'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: connected
                              ? context.zeroPalette.success
                              : context.zeroPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: ZeroTokens.space3),
            TextField(
              key: const ValueKey('jimaku-api-key'),
              controller: _key,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (_) => _edited = true,
              onSubmitted: (_) => unawaited(_connect()),
              decoration: InputDecoration(
                labelText: 'Personal Jimaku API key',
                helperText: 'A free Jimaku account is required. Stored only in the OS keyring.',
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
            ),
            const SizedBox(height: ZeroTokens.space3),
            Wrap(
              spacing: ZeroTokens.space2,
              runSpacing: ZeroTokens.space2,
              children: [
                FilledButton.icon(
                  key: const ValueKey('save-test-jimaku'),
                  onPressed: _working ? null : _connect,
                  icon: _working
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  label: const Text('Save & test'),
                ),
                if (connected)
                  OutlinedButton(
                    key: const ValueKey('disconnect-jimaku'),
                    onPressed: _working ? null : _disconnect,
                    child: const Text('Disconnect'),
                  ),
              ],
            ),
            const SizedBox(height: ZeroTokens.space2),
            Text(
              'Get a personal key at jimaku.cc/account. Only the AniList ID and episode number are queried; downloaded text stays in the app cache and lookup text is never uploaded.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_message != null) ...[
              const SizedBox(height: ZeroTokens.space2),
              Text(
                _message!,
                key: const ValueKey('jimaku-connection-message'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _error
                      ? context.zeroPalette.error
                      : context.zeroPalette.success,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DictionaryPanel extends StatelessWidget {
  const _DictionaryPanel({
    required this.status,
    required this.working,
    required this.message,
    required this.onInstall,
    required this.onRemove,
  });

  final LearningDictionaryStatus status;
  final bool working;
  final String? message;
  final VoidCallback onInstall;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final busy =
        working ||
        status.phase == LearningDictionaryPhase.downloading ||
        status.phase == LearningDictionaryPhase.importing;
    final installed = status.installed;
    final statusText = switch (status.phase) {
      LearningDictionaryPhase.missing => 'Not installed',
      LearningDictionaryPhase.downloading => 'Downloading…',
      LearningDictionaryPhase.importing => 'Building local index…',
      LearningDictionaryPhase.ready =>
        '${status.entryCount} local entries${status.version == null ? '' : ' · ${status.version}'}',
      LearningDictionaryPhase.failed => status.message ?? 'Install failed',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.zeroPalette.surfaceRaised,
        border: Border.all(color: context.zeroPalette.border),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  installed
                      ? Icons.offline_pin_outlined
                      : Icons.menu_book_outlined,
                  color: installed
                      ? context.zeroPalette.success
                      : context.zeroPalette.accentSoft,
                ),
                const SizedBox(width: ZeroTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'JMdict Japanese–English',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        statusText,
                        key: const ValueKey('learning-dictionary-status'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: status.phase == LearningDictionaryPhase.failed
                              ? context.zeroPalette.error
                              : context.zeroPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (installed) ...[
                  IconButton(
                    key: const ValueKey('update-learning-dictionary'),
                    tooltip: 'Update dictionary',
                    onPressed: onInstall,
                    icon: const Icon(Icons.sync_rounded),
                  ),
                  OutlinedButton(
                    key: const ValueKey('remove-learning-dictionary'),
                    onPressed: onRemove,
                    child: const Text('Remove'),
                  ),
                ] else
                  FilledButton.icon(
                    key: const ValueKey('install-learning-dictionary'),
                    onPressed: onInstall,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Install'),
                  ),
              ],
            ),
            const SizedBox(height: ZeroTokens.space2),
            Text(
              'Downloaded once, searched entirely offline, and stored in the app cache. Definitions come from EDRDG JMdict; no subtitle text is sent to a server.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (message != null) ...[
              const SizedBox(height: ZeroTokens.space2),
              Text(
                message!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.zeroPalette.error),
              ),
            ],
          ],
        ),
      ),
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
      subtitle: 'Install Zero JSON catalogs. Known source IDs run through native Dart adapters; extension scripts are never executed.',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: ZeroTokens.space3),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                key: const ValueKey('extension-source'),
                controller: _source,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Catalog source',
                  hintText: 'gh:Spithskia/Zero-Extensions',
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
                    const SizedBox(height: ZeroTokens.space2),
                    button,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: ZeroTokens.space3),
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
              padding: const EdgeInsets.only(bottom: ZeroTokens.space2),
              child: Text(
                _message!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _error
                      ? context.zeroPalette.error
                      : context.zeroPalette.success,
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
                        padding: const EdgeInsets.only(top: ZeroTokens.space3),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: ZeroTokens.space2,
                            runSpacing: ZeroTokens.space2,
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
          ?.copyWith(color: context.zeroPalette.textSecondary),
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
      margin: const EdgeInsets.only(top: ZeroTokens.space2),
      decoration: BoxDecoration(
        color: context.zeroPalette.surfaceRaised,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        border: Border.all(color: context.zeroPalette.border),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: ZeroTokens.space3),
        childrenPadding: const EdgeInsets.fromLTRB(
          ZeroTokens.space3,
          0,
          ZeroTokens.space3,
          ZeroTokens.space3,
        ),
        leading: Icon(
          extension.supported ? Icons.hub_outlined : Icons.code_off_rounded,
          color: extension.supported
              ? context.zeroPalette.accentSoft
              : context.zeroPalette.warning,
        ),
        title: Row(
          children: [
            Flexible(child: Text(extension.name)),
            const SizedBox(width: ZeroTokens.space2),
            _SmallBadge(label: 'v${extension.version}'),
            if (extension.deprecated) ...[
              const SizedBox(width: ZeroTokens.space1),
              const _SmallBadge(label: 'Deprecated', warning: true),
            ],
            if (!extension.supported) ...[
              const SizedBox(width: ZeroTokens.space1),
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
                    ?.copyWith(color: context.zeroPalette.textSecondary),
              ),
            ),
          for (final field in extension.fields)
            _ExtensionField(extension: extension, field: field),
          const SizedBox(height: ZeroTokens.space2),
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
      color: warning
          ? context.zeroPalette.warning.withValues(alpha: 0.14)
          : context.zeroPalette.surfaceHighlight,
      borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      border: Border.all(
        color: warning
            ? context.zeroPalette.warning
            : context.zeroPalette.border,
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
            padding: const EdgeInsets.symmetric(vertical: ZeroTokens.space3),
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
                      const SizedBox(height: ZeroTokens.space3),
                      button,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: ZeroTokens.space3),
                    Padding(
                      padding: const EdgeInsets.only(top: ZeroTokens.space2),
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
                      ? context.zeroPalette.error
                      : context.zeroPalette.success,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.selected, required this.onChanged});

  final AppThemePreset selected;
  final ValueChanged<AppThemePreset> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: ZeroTokens.space2,
        bottom: ZeroTokens.space4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Theme', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: ZeroTokens.space1),
          Text(
            'Choose a palette. Changes apply immediately across the app.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.zeroPalette.textSecondary),
          ),
          const SizedBox(height: ZeroTokens.space3),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720
                  ? 3
                  : constraints.maxWidth >= 430
                  ? 2
                  : 1;
              final gap = ZeroTokens.space2 * (columns - 1);
              final width = (constraints.maxWidth - gap) / columns;
              return Wrap(
                spacing: ZeroTokens.space2,
                runSpacing: ZeroTokens.space2,
                children: [
                  for (final theme in ZeroThemeCatalog.values)
                    SizedBox(
                      width: width,
                      child: _ThemeChoice(
                        theme: theme,
                        selected: theme.id == selected,
                        onTap: () => onChanged(theme.id),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ZeroThemeDefinition theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final current = context.zeroPalette;
    final preview = theme.palette;
    return Semantics(
      selected: selected,
      button: true,
      label: '${theme.label} theme',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('theme-preset-${theme.id.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
          child: AnimatedContainer(
            duration: ZeroTokens.motionQuick,
            padding: const EdgeInsets.all(ZeroTokens.space3),
            decoration: BoxDecoration(
              color: selected ? current.navSelected : current.surfaceRaised,
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
              border: Border.all(
                color: selected ? current.accent : current.border,
                width: selected ? 1.5 : 1,
              ),
              boxShadow: selected ? current.navigationGlow : null,
            ),
            child: Row(
              children: [
                _ThemeSwatch(palette: preview),
                const SizedBox(width: ZeroTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        theme.label,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        theme.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: ZeroTokens.space1),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: current.accentSoft,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.palette});

  final ZeroPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: palette.background,
        shape: BoxShape.circle,
        border: Border.all(color: palette.border),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 21,
        height: 21,
        decoration: BoxDecoration(
          color: palette.surfaceRaised,
          shape: BoxShape.circle,
          border: Border.all(color: palette.border),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: palette.accent,
            shape: BoxShape.circle,
          ),
        ),
      ),
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
        color: context.zeroPalette.panel,
        border: Border.all(color: context.zeroPalette.border),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: context.zeroPalette.accentSoft),
                const SizedBox(width: ZeroTokens.space2),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: ZeroTokens.space2),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.zeroPalette.textSecondary),
              ),
            ],
            const SizedBox(height: ZeroTokens.space3),
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
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        dropdownColor: context.zeroPalette.surface,
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
      padding: const EdgeInsets.symmetric(vertical: ZeroTokens.space2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.zeroPalette.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: ZeroTokens.space1),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.zeroPalette.textSecondary),
              ),
            ],
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                copy,
                const SizedBox(height: ZeroTokens.space2),
                Align(alignment: Alignment.centerRight, child: control),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: ZeroTokens.space4),
              Flexible(child: control),
            ],
          );
        },
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
        padding: const EdgeInsets.all(ZeroTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: ZeroTokens.space3),
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
