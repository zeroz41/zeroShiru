/// Caps a pack's file list around the file playback wants rather than taking
/// the first N. Port of crates/debrid/src/window.rs.
library;

/// Returns the window of [files] that keeps [target] (by index) reachable,
/// preserving torrent order so in-player next/previous still works. Clamps at
/// both ends without shrinking; degrades to the head when there is no target.
List<T> windowFiles<T>(List<T> files, int? target, int maxFiles) {
  if (files.length <= maxFiles) return files;
  final int start;
  if (target == null || target >= files.length) {
    start = 0;
  } else {
    final centred = target - (maxFiles >> 1);
    final clamped = centred < 0 ? 0 : centred;
    final limit = files.length - maxFiles;
    start = clamped > limit ? limit : clamped;
  }
  return files.sublist(start, start + maxFiles);
}
