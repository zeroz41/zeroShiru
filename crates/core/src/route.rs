//! How a play request is routed between the local torrent engine and a debrid
//! service. Port of common/modules/debrid/route.js; test/unit/debrid/route.test.js
//! is the behavioural reference.

use serde::{Deserialize, Serialize};
use shiru_domain::parse_hash;

/// The debridMode setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DebridMode {
    /// Debrid First: cached releases stream from the service, anything uncached
    /// falls back to torrents.
    Prefer,
    /// Debrid Only: playback always uses the service, torrents never start.
    Only,
}

/// Why playback was blocked instead of routed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BlockReason {
    /// Debrid only mode is on but no API key is set.
    Key,
    /// The client is offline, so the service cannot be reached.
    Offline,
    /// The source only provides something debrid cannot resolve (no usable hash).
    Source,
}

#[derive(Debug, Clone, Default)]
pub struct RouteInput<'a> {
    /// Magnet URI, info hash, .torrent link — whatever the source handed over.
    pub torrent_id: Option<&'a str>,
    /// Info hash when known, used when the link itself is not resolvable.
    pub hash: Option<&'a str>,
    /// A debrid service is selected in settings.
    pub service_selected: bool,
    /// The service has an API key configured.
    pub service_ready: bool,
    /// The client has no network connection.
    pub offline: bool,
    pub mode: Option<DebridMode>,
}

/// The routing decision. `only` reports whether debrid only mode governs it,
/// so callers need not re-derive it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase")]
pub enum RouteDecision {
    Torrent { only: bool },
    Block { reason: BlockReason, only: bool },
    Resolve { id: String, only: bool },
}

/// A torrent id debrid can resolve: a magnet with a full btih hash, or a bare hex hash.
fn usable(torrent_id: Option<&str>) -> Option<&str> {
    let id = torrent_id?;
    let is_magnet = id.len() >= 7 && id[..7].eq_ignore_ascii_case("magnet:");
    if (is_magnet && parse_hash(id).is_some()) || (id.len() == 40 && parse_hash(id).is_some()) {
        Some(id)
    } else {
        None
    }
}

/// Decides how a play request should be handled.
pub fn route_debrid(input: &RouteInput) -> RouteDecision {
    // with no service selected debrid is entirely out of the picture, only mode included
    if !input.service_selected {
        return RouteDecision::Torrent { only: false };
    }
    let only = input.mode == Some(DebridMode::Only);
    if !input.service_ready {
        return if only {
            RouteDecision::Block { reason: BlockReason::Key, only }
        } else {
            RouteDecision::Torrent { only }
        };
    }
    if input.offline {
        return if only {
            RouteDecision::Block { reason: BlockReason::Offline, only }
        } else {
            RouteDecision::Torrent { only }
        };
    }
    match usable(input.torrent_id).or_else(|| usable(input.hash)) {
        Some(id) => RouteDecision::Resolve { id: id.to_string(), only },
        None => {
            if only {
                RouteDecision::Block { reason: BlockReason::Source, only }
            } else {
                RouteDecision::Torrent { only }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef01234567";

    fn base<'a>() -> RouteInput<'a> {
        RouteInput {
            torrent_id: Some(HASH),
            hash: None,
            service_selected: true,
            service_ready: true,
            offline: false,
            mode: Some(DebridMode::Prefer),
        }
    }

    #[test]
    fn no_service_selected_always_torrents() {
        let mut input = base();
        input.service_selected = false;
        input.mode = Some(DebridMode::Only);
        assert_eq!(route_debrid(&input), RouteDecision::Torrent { only: false });
    }

    #[test]
    fn missing_key_blocks_only_mode_and_torrents_prefer_mode() {
        let mut input = base();
        input.service_ready = false;
        assert_eq!(route_debrid(&input), RouteDecision::Torrent { only: false });
        input.mode = Some(DebridMode::Only);
        assert_eq!(route_debrid(&input), RouteDecision::Block { reason: BlockReason::Key, only: true });
    }

    #[test]
    fn offline_blocks_only_mode_and_torrents_prefer_mode() {
        let mut input = base();
        input.offline = true;
        assert_eq!(route_debrid(&input), RouteDecision::Torrent { only: false });
        input.mode = Some(DebridMode::Only);
        assert_eq!(route_debrid(&input), RouteDecision::Block { reason: BlockReason::Offline, only: true });
    }

    #[test]
    fn unusable_source_blocks_only_mode_and_torrents_prefer_mode() {
        let mut input = base();
        input.torrent_id = Some("https://example.com/file.torrent");
        assert_eq!(route_debrid(&input), RouteDecision::Torrent { only: false });
        input.mode = Some(DebridMode::Only);
        assert_eq!(route_debrid(&input), RouteDecision::Block { reason: BlockReason::Source, only: true });
    }

    #[test]
    fn resolvable_ids_resolve() {
        let input = base();
        assert_eq!(route_debrid(&input), RouteDecision::Resolve { id: HASH.into(), only: false });

        let magnet = format!("magnet:?xt=urn:btih:{HASH}");
        let mut input = base();
        input.torrent_id = Some(&magnet);
        input.mode = Some(DebridMode::Only);
        assert_eq!(route_debrid(&input), RouteDecision::Resolve { id: magnet.clone(), only: true });
    }

    #[test]
    fn falls_back_to_the_separate_hash_when_the_link_is_not_resolvable() {
        let mut input = base();
        input.torrent_id = Some("https://example.com/file.torrent");
        input.hash = Some(HASH);
        assert_eq!(route_debrid(&input), RouteDecision::Resolve { id: HASH.into(), only: false });
    }
}
