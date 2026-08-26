import 'torrent.dart';

enum ExtensionSettingType { select, multiselect, toggle, text }

class ExtensionOption {
  const ExtensionOption({required this.label, required this.value});

  final String label;
  final String value;
}

class ExtensionSettingField {
  const ExtensionSettingField({
    required this.key,
    required this.label,
    required this.type,
    this.description,
    this.options = const [],
  });

  final String key;
  final String label;
  final ExtensionSettingType type;
  final String? description;
  final List<ExtensionOption> options;
}

/// A declarative extension record. [id] selects an audited native adapter;
/// the manifest itself is data and is never executed by the app.
class SourceExtension {
  const SourceExtension({
    required this.id,
    required this.name,
    required this.version,
    required this.origin,
    required this.supported,
    required this.enabled,
    this.description,
    this.speed,
    this.accuracy,
    this.deprecated = false,
    this.nsfw = false,
    this.fields = const [],
    this.settings = const {},
  });

  final String id;
  final String name;
  final String version;
  final String origin;
  final bool supported;
  final bool enabled;
  final String? description;
  final String? speed;
  final String? accuracy;
  final bool deprecated;
  final bool nsfw;
  final List<ExtensionSettingField> fields;
  final Map<String, Object?> settings;

  SourceExtension copyWith({bool? enabled, Map<String, Object?>? settings}) =>
      SourceExtension(
        id: id,
        name: name,
        version: version,
        origin: origin,
        supported: supported,
        enabled: enabled ?? this.enabled,
        description: description,
        speed: speed,
        accuracy: accuracy,
        deprecated: deprecated,
        nsfw: nsfw,
        fields: fields,
        settings: settings ?? this.settings,
      );
}

class SourceCatalog {
  const SourceCatalog({this.roots = const [], this.extensions = const []});

  final List<String> roots;
  final List<SourceExtension> extensions;

  int get enabledCount => extensions.where((item) => item.enabled).length;
}

/// One progressive result from one native source. A source failure is kept
/// local so fast/healthy sources remain immediately usable.
class SourceSearchBatch {
  const SourceSearchBatch({
    required this.source,
    this.results = const [],
    this.error,
  });

  final SourceExtension source;
  final List<TorrentResult> results;
  final String? error;
}
