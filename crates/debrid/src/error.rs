//! Typed debrid errors. Port of the error hierarchy in common/modules/debrid/service.js;
//! callers read the proven availability off the error rather than matching on types.

use shiru_domain::Availability;

#[derive(Debug, thiserror::Error)]
pub enum DebridError {
    /// The API key is missing, invalid, or the account lacks the required plan.
    #[error("{message}")]
    Auth { message: String, status: Option<u16>, code: Option<String> },

    /// The service could not be reached at all, usually because the client is offline.
    #[error("{message}")]
    Network { message: String },

    /// The service kept us waiting past the budget. It says nothing about the release, so
    /// whoever asked decides what to make of it: playback cannot wait, a badge check can
    /// come back later.
    #[error("{message}")]
    Timeout { message: String },

    /// The service would have to download the torrent before it could stream it.
    /// Proves the release is `Available`.
    #[error("{message}")]
    NotCached { message: String },

    /// The service cannot serve this release at all: a dead magnet, a rejected or failed
    /// torrent. Proves the release is `Unavailable`.
    #[error("{message}")]
    Unavailable { message: String },

    /// The caller's file chooser refused this release — the episode asked for is
    /// provably not in it. Nothing is wrong with the service or the account, so
    /// this must not be retried or read as an availability answer.
    #[error("{message}")]
    Rejected { message: String },

    /// Any other API failure, with whatever the service said about it.
    #[error("{message}")]
    Service { message: String, status: Option<u16>, code: Option<String> },
}

impl DebridError {
    pub fn not_cached() -> DebridError {
        DebridError::NotCached { message: "Torrent is not cached on the debrid service".into() }
    }

    pub fn unavailable() -> DebridError {
        DebridError::Unavailable { message: "The debrid service cannot serve this torrent".into() }
    }

    /// What this error proves about a release, or `None` when it proves nothing.
    /// A timeout or a rate limit describes the moment, not the release, so it leaves it
    /// unknown and re-checkable. Port of availabilityFromError.
    pub fn proven_availability(&self) -> Option<Availability> {
        match self {
            DebridError::NotCached { .. } => Some(Availability::Available),
            DebridError::Unavailable { .. } => Some(Availability::Unavailable),
            _ => None,
        }
    }

    pub fn status(&self) -> Option<u16> {
        match self {
            DebridError::Auth { status, .. } | DebridError::Service { status, .. } => *status,
            _ => None,
        }
    }

    /// Whether this error means the service wants fewer requests rather than that this
    /// release is a problem. A sweep stops on one.
    pub fn throttled(&self) -> bool {
        self.status() == Some(429)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // mirrors test/unit/debrid/errors.test.js: what each error proves about a release
    #[test]
    fn only_unstreamable_errors_prove_availability() {
        assert_eq!(DebridError::not_cached().proven_availability(), Some(Availability::Available));
        assert_eq!(DebridError::unavailable().proven_availability(), Some(Availability::Unavailable));
        assert_eq!(DebridError::Timeout { message: "slow".into() }.proven_availability(), None);
        assert_eq!(DebridError::Network { message: "offline".into() }.proven_availability(), None);
        assert_eq!(
            DebridError::Service { message: "500".into(), status: Some(500), code: None }.proven_availability(),
            None
        );
        assert_eq!(
            DebridError::Auth { message: "bad key".into(), status: Some(401), code: None }.proven_availability(),
            None
        );
    }

    #[test]
    fn throttling_is_a_429() {
        let limited = DebridError::Service { message: "rate limited".into(), status: Some(429), code: None };
        assert!(limited.throttled());
        assert!(!DebridError::not_cached().throttled());
    }
}
