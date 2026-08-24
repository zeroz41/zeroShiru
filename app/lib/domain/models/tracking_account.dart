enum TrackingAccountService { aniList, myAnimeList }

enum TrackingAccountHealth { connected, attention, expired }

/// Safe account metadata for presentation. Access and refresh tokens never
/// leave the tracking infrastructure layer.
class TrackingAccount {
  const TrackingAccount({
    required this.service,
    required this.displayName,
    required this.health,
    this.avatarUrl,
  });

  final TrackingAccountService service;
  final String displayName;
  final TrackingAccountHealth health;
  final String? avatarUrl;
}
