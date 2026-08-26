/// Debrid cached-availability vocabulary, ported from the proven
/// frontend/common/modules/debrid/availability.js on the redo branch.
enum Availability {
  cached,
  available,
  unavailable,
  unknown;

  /// Sort order: cached first, unknown last.
  int get order => switch (this) {
    cached => 0,
    available => 1,
    unavailable => 2,
    unknown => 3,
  };

  /// How long a proven answer stays trustworthy.
  Duration get ttl => switch (this) {
    cached => const Duration(hours: 6),
    available => const Duration(minutes: 20),
    unavailable => const Duration(minutes: 30),
    unknown => Duration.zero,
  };

  bool get streamsInstantly => this == cached;

  static Availability normalize(String? value) =>
      switch (value?.toLowerCase()) {
        'cached' => cached,
        'available' => available,
        'unavailable' => unavailable,
        _ => unknown,
      };
}

Availability availabilityOf(Map<String, Availability> map, String? hash) =>
    hash == null
    ? Availability.unknown
    : map[hash.toLowerCase()] ?? Availability.unknown;

/// Reorder [results] so releases the debrid service already holds come first,
/// preserving relative order within each tier. A most-seeded release the
/// service does not hold is a guaranteed resolve failure.
List<T> preferCached<T>(
  List<T> results,
  Map<String, Availability> availability,
  String? Function(T) hashOf,
) {
  final held = <T>[];
  final rest = <T>[];
  for (final r in results) {
    (availabilityOf(availability, hashOf(r)).streamsInstantly ? held : rest)
        .add(r);
  }
  return [...held, ...rest];
}
