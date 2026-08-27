import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('first-party imports follow the documented layer boundaries', () {
    final root = Directory.current.absolute;
    final lib = Directory(p.join(root.path, 'lib'));
    final violations = <String>[];

    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = p.relative(entity.path, from: lib.path);
      final sourceLayer = _layerOf(source);
      if (sourceLayer == null) continue;

      final contents = entity.readAsStringSync();
      for (final match in _imports.allMatches(contents)) {
        final uri = match.group(1)!;
        if (sourceLayer == 'domain' &&
            (uri == 'dart:ui' || uri.startsWith('package:flutter'))) {
          violations.add('$source imports UI runtime $uri');
          continue;
        }

        final target = _firstPartyTarget(uri, source: entity, lib: lib);
        final targetLayer = target == null ? null : _layerOf(target);
        if (targetLayer != null &&
            _forbiddenTargets[sourceLayer]!.contains(targetLayer)) {
          violations.add(
            '$source ($sourceLayer) imports $target ($targetLayer)',
          );
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Move shared contracts inward instead of importing across a layer:\n'
          '${violations.join('\n')}',
    );
  });
}

final RegExp _imports = RegExp(r'''import\s+['"]([^'"]+)['"]''');

const Map<String, Set<String>> _forbiddenTargets = {
  'domain': {'app', 'application', 'features', 'infrastructure'},
  'application': {'app', 'features', 'infrastructure'},
  'features': {'infrastructure'},
  'infrastructure': {'app', 'features'},
};

String? _layerOf(String path) {
  final first = p.split(path).firstOrNull;
  return _forbiddenTargets.containsKey(first) ? first : null;
}

String? _firstPartyTarget(
  String uri, {
  required File source,
  required Directory lib,
}) {
  if (uri.startsWith('package:zero/')) {
    return p.normalize(uri.substring('package:zero/'.length));
  }
  if (uri.startsWith('dart:') || uri.startsWith('package:')) return null;

  final absolute = p.normalize(p.join(p.dirname(source.path), uri));
  if (!p.isWithin(lib.path, absolute)) return null;
  return p.relative(absolute, from: lib.path);
}
