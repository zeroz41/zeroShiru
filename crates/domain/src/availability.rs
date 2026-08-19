//! The vocabulary the whole debrid layer uses to describe a release.
//! Port of common/modules/debrid/availability.js — the JS module remains the
//! reference until the frontend consumes this crate.

use serde::{Deserialize, Serialize};
use std::time::Duration;

/// What a debrid service can do with a release right now. Services differ wildly in how well
/// they can answer, but all speak these four values, so the rest of the app never has to care
/// which kind it is talking to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Availability {
    /// The service holds it and streams it immediately.
    Cached,
    /// The service does not hold it but can fetch it, which takes longer than playback will wait.
    Available,
    /// The service cannot serve it at all: a dead magnet, a rejected release, a failed download.
    Unavailable,
    /// Nobody asked, or nothing came back. Never report this as "not cached",
    /// it is an absence of an answer.
    Unknown,
}

/// Every state, best first. The order badges and counters are shown in.
pub const AVAILABILITY_ORDER: [Availability; 4] = [
    Availability::Cached,
    Availability::Available,
    Availability::Unknown,
    Availability::Unavailable,
];

impl Availability {
    /// Anything unrecognised reads as unknown, so a service answering something unexpected
    /// degrades to "no answer" rather than poisoning the badges.
    pub fn normalize(value: &str) -> Availability {
        match value {
            "cached" => Availability::Cached,
            "available" => Availability::Available,
            "unavailable" => Availability::Unavailable,
            _ => Availability::Unknown,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Availability::Cached => "cached",
            Availability::Available => "available",
            Availability::Unavailable => "unavailable",
            Availability::Unknown => "unknown",
        }
    }

    /// Whether playback can start on this release now. The one question the player asks.
    pub fn streams_instantly(&self) -> bool {
        matches!(self, Availability::Cached)
    }

    /// How long an answer stays trusted. A hit lasts far longer than a miss: anyone can pull a
    /// release into a cache at any moment, but one already held rarely disappears.
    pub fn ttl(&self) -> Duration {
        match self {
            Availability::Cached => Duration::from_secs(6 * 60 * 60),
            Availability::Available => Duration::from_secs(20 * 60),
            Availability::Unavailable => Duration::from_secs(30 * 60),
            Availability::Unknown => Duration::ZERO,
        }
    }

    /// How a state is worded for the user, kept here so it reads the same wherever it appears.
    pub fn describe(&self, title: &str) -> (String, String) {
        match self {
            Availability::Cached => (
                "Cached".into(),
                format!("Cached on {title}, streams instantly with no torrent peers involved."),
            ),
            Availability::Available => (
                "Available".into(),
                format!("{title} can fetch this release but does not hold it yet, so it cannot stream right now."),
            ),
            Availability::Unavailable => (
                "Unavailable".into(),
                format!("{title} cannot serve this release at all."),
            ),
            Availability::Unknown => (
                "Unchecked".into(),
                format!("{title} has not been asked about this release. It may still stream."),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_degrades_junk_to_unknown() {
        assert_eq!(Availability::normalize("cached"), Availability::Cached);
        assert_eq!(Availability::normalize("available"), Availability::Available);
        assert_eq!(Availability::normalize("unavailable"), Availability::Unavailable);
        assert_eq!(Availability::normalize("unknown"), Availability::Unknown);
        assert_eq!(Availability::normalize("CACHED"), Availability::Unknown);
        assert_eq!(Availability::normalize(""), Availability::Unknown);
        assert_eq!(Availability::normalize("weird"), Availability::Unknown);
    }

    #[test]
    fn only_cached_streams_instantly() {
        assert!(Availability::Cached.streams_instantly());
        assert!(!Availability::Available.streams_instantly());
        assert!(!Availability::Unavailable.streams_instantly());
        assert!(!Availability::Unknown.streams_instantly());
    }

    #[test]
    fn ttls_match_the_js_reference() {
        assert_eq!(Availability::Cached.ttl(), Duration::from_millis(6 * 60 * 60_000));
        assert_eq!(Availability::Available.ttl(), Duration::from_millis(20 * 60_000));
        assert_eq!(Availability::Unavailable.ttl(), Duration::from_millis(30 * 60_000));
        assert_eq!(Availability::Unknown.ttl(), Duration::ZERO);
    }

    #[test]
    fn serde_round_trips_lowercase() {
        assert_eq!(serde_json::to_string(&Availability::Cached).unwrap(), "\"cached\"");
        let state: Availability = serde_json::from_str("\"unavailable\"").unwrap();
        assert_eq!(state, Availability::Unavailable);
    }
}
