/// Info-hash parsing shared by every layer that touches a magnet, plus the
/// watch-progress identity key. Port of crates/domain/src/hash.rs and the
/// PlayerFile `watchKey` contract (rust-core-map §5).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The lowercase info hash of a magnet URI or bare hash, `null` when there is
/// none. First case-insensitive `urn:btih:<40 hex>` wins, else a bare 40-hex
/// string, always lowercased.
String? parseHash(String magnetOrHash) {
  final lower = magnetOrHash.toLowerCase();
  const needle = 'urn:btih:';
  var start = 0;
  while (true) {
    final at = lower.indexOf(needle, start);
    if (at < 0) break;
    final rest = lower.substring(at + needle.length);
    if (rest.length >= 40 && _isHex40(rest.substring(0, 40))) {
      return rest.substring(0, 40);
    }
    start = at + 1;
  }
  if (_isHex40(lower)) return lower;
  return null;
}

/// A magnet URI to hand to an API, from a magnet URI or bare info hash.
/// `null` when the input holds no usable hash.
String? toMagnet(String magnetOrHash) {
  if (magnetOrHash.startsWith('magnet:')) return magnetOrHash;
  final hash = parseHash(magnetOrHash);
  return hash == null ? null : 'magnet:?xt=urn:btih:$hash';
}

/// Validates the two identity fields source adapters commonly return. A valid
/// hash in either field is enough, but two different valid hashes are rejected
/// rather than silently resolving a different torrent than the row describes.
String? validatedTorrentHash({String? declaredHash, required String link}) {
  final declared = declaredHash == null ? null : parseHash(declaredHash);
  final linked = parseHash(link);
  if (declared != null && linked != null && declared != linked) return null;
  return declared ?? linked;
}

/// A minimal canonical magnet for a validated source result. Tracker and title
/// parameters are deliberately discarded at the debrid boundary; the info hash
/// is the complete identity TorBox and the other providers require.
String? validatedTorrentMagnet({String? declaredHash, required String link}) {
  final hash = validatedTorrentHash(declaredHash: declaredHash, link: link);
  return hash == null ? null : 'magnet:?xt=urn:btih:$hash';
}

/// The watch-progress identity of one playable file:
/// `sha1Hex("$infoHash:$name:$size")`. Must be byte-identical between the
/// torrent and debrid lanes or resume silently restarts.
String watchKey(String infoHash, String name, int size) =>
    sha1.convert(utf8.encode('$infoHash:$name:$size')).toString();

bool _isHex40(String value) {
  if (value.length != 40) return false;
  for (final unit in value.codeUnits) {
    final hex =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x61 && unit <= 0x66) ||
        (unit >= 0x41 && unit <= 0x46);
    if (!hex) return false;
  }
  return true;
}
