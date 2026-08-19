//! Pure data types shared by every host: desktop, Android, and the TV WASM builds.
//! No platform dependencies, no IO — everything here must compile for
//! wasm32-unknown-unknown unchanged.

pub mod availability;
pub mod candidate;
pub mod file;
pub mod hash;

pub use availability::{Availability, AVAILABILITY_ORDER};
pub use candidate::{PlaybackSource, ProviderId, StreamCandidate};
pub use file::{sha1_hex, to_player_file, watch_key, DebridFile, DebridResolved, PlayerFile};
pub use hash::{parse_hash, to_magnet};
