/// Pure debrid routing policy, ported from
/// frontend/common/modules/debrid/route.js on the redo branch.
library;

enum DebridMode { off, prefer, only }

enum RouteAction { torrent, block, resolve }

enum BlockReason { key, offline, source }

class DebridRoute {
  const DebridRoute._(this.action, {this.reason, this.id, this.only = false});

  final RouteAction action;
  final BlockReason? reason;

  /// The torrent id/magnet the resolver should use.
  final String? id;

  /// True when debrid-only mode owns the outcome (no torrent fallback).
  final bool only;

  static const torrent = DebridRoute._(RouteAction.torrent);
}

/// Decide which lane a play request takes. Mirrors routeDebrid():
/// - no service selected → torrent lane
/// - missing key / offline / unresolvable id → torrent lane in prefer mode,
///   explicit block in only mode
/// - otherwise resolve via debrid.
DebridRoute routeDebrid({
  required String? torrentId,
  required String? hash,
  required bool serviceSelected,
  required bool serviceReady,
  required bool offline,
  required DebridMode mode,
}) {
  if (!serviceSelected || mode == DebridMode.off) return DebridRoute.torrent;
  final only = mode == DebridMode.only;

  DebridRoute deny(BlockReason reason) => only
      ? DebridRoute._(RouteAction.block, reason: reason, only: true)
      : DebridRoute.torrent;

  if (!serviceReady) return deny(BlockReason.key);
  if (offline) return deny(BlockReason.offline);
  final id = torrentId ?? hash;
  if (id == null || id.isEmpty) return deny(BlockReason.source);
  return DebridRoute._(RouteAction.resolve, id: id, only: only);
}
