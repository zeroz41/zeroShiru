import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/media/info_hash.dart';

const hash = '0123456789abcdef0123456789abcdef01234567';

void main() {
  test('parses bare hashes case insensitively', () {
    expect(parseHash(hash), hash);
    expect(parseHash(hash.toUpperCase()), hash);
  });

  test('parses magnets', () {
    final magnet = 'magnet:?xt=urn:btih:${hash.toUpperCase()}&dn=Some+Release';
    expect(parseHash(magnet), hash);
  });

  test('rejects junk', () {
    expect(parseHash(''), isNull);
    expect(parseHash('not a hash'), isNull);
    expect(parseHash(hash.substring(0, 39)), isNull);
    expect(parseHash('magnet:?xt=urn:btih:zzz'), isNull);
  });

  test('source identity rejects missing and contradictory hashes', () {
    const other = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    expect(
      validatedTorrentHash(declaredHash: hash, link: 'https://tracker/file'),
      hash,
    );
    expect(
      validatedTorrentHash(
        declaredHash: null,
        link: 'magnet:?xt=urn:btih:$hash',
      ),
      hash,
    );
    expect(
      validatedTorrentHash(declaredHash: null, link: 'https://tracker/file'),
      isNull,
    );
    expect(
      validatedTorrentHash(
        declaredHash: hash,
        link: 'magnet:?xt=urn:btih:$other',
      ),
      isNull,
    );
  });

  test('toMagnet passes magnets through and wraps hashes', () {
    final magnet = 'magnet:?xt=urn:btih:$hash';
    expect(toMagnet(magnet), magnet);
    expect(toMagnet(hash.toUpperCase()), magnet);
    expect(toMagnet('junk'), isNull);
  });

  test('watchKey is the sha1 of infoHash:name:size', () {
    // identity contract: must be byte-identical between torrent and debrid
    // lanes. sha1("abc:file.mkv:123") computed independently.
    expect(
      watchKey('abc', 'file.mkv', 123),
      'f334968145e1d2e19fd6de37b59a5e37164fafc9',
    );
    expect(watchKey('abc', 'file.mkv', 123).length, 40);
    expect(
      watchKey('abc', 'file.mkv', 124),
      isNot(watchKey('abc', 'file.mkv', 123)),
    );
  });
}
