//! How a playable source is described before and after resolution.

use serde::{Deserialize, Serialize};

/// Identifies a debrid provider implementation, e.g. "realdebrid" or "torbox".
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProviderId(pub String);

impl std::fmt::Display for ProviderId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// A source discovered by search/extensions, normalized so the rest of the
/// application never cares how it was found.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum StreamCandidate {
    /// A plain HTTP(S) URL that already streams.
    Direct { url: String },
    /// A torrent, by info hash; the magnet carries trackers when the source had them.
    Torrent {
        info_hash: String,
        magnet: Option<String>,
        file_index: Option<u32>,
    },
    /// Something a debrid provider already knows by its own id.
    Debrid { provider: ProviderId, id: String },
}

/// What the resolver hands the player: a URL plus how it came to be.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "transport", rename_all = "lowercase")]
pub enum PlaybackSource {
    /// Streamed directly from the network.
    Direct { url: String },
    /// Streamed from a debrid service over HTTPS.
    Debrid { provider: ProviderId, url: String },
    /// Streamed from the local torrent engine.
    Torrent { info_hash: String, url: String },
}
