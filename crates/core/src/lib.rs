//! Application/business logic shared by every host. No Tauri, no Android, no
//! Samsung, no LG — this crate must compile for wasm32-unknown-unknown unchanged.

pub mod pick;
pub mod route;

pub use pick::{pick_episode_file, pick_pack_file, EpisodeNotInPack, ParsedName};
pub use route::{route_debrid, DebridMode, RouteDecision, RouteInput, BlockReason};
