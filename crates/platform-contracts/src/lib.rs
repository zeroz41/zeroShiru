//! What a host platform can and cannot do. The shared core consults these instead of
//! sniffing the platform, so TV/desktop/mobile differences stay data, not code paths.

use serde::{Deserialize, Serialize};

/// Capabilities that change how sources are resolved and played.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformCapabilities {
    /// The host can run the local torrent engine. False on the TV builds initially,
    /// which routes raw torrents through debrid instead.
    pub local_p2p: bool,
    /// A debrid provider may be configured.
    pub debrid: bool,
    /// Plain HTTPS streams can be played directly.
    pub direct_http: bool,
}

impl PlatformCapabilities {
    pub const DESKTOP: PlatformCapabilities = PlatformCapabilities { local_p2p: true, debrid: true, direct_http: true };
    pub const ANDROID: PlatformCapabilities = PlatformCapabilities { local_p2p: true, debrid: true, direct_http: true };
    /// Samsung Tizen and LG webOS: no local P2P initially, debrid resolves raw torrents.
    pub const TV_WEB: PlatformCapabilities = PlatformCapabilities { local_p2p: false, debrid: true, direct_http: true };
}

/// How the user drives the UI on this host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputCapabilities {
    pub touch: bool,
    pub pointer: bool,
    pub keyboard: bool,
    pub dpad: bool,
}

/// Which layout family the shared Svelte pages render.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LayoutProfile {
    Desktop,
    Mobile,
    Tv,
}
