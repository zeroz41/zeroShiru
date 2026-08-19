//! Discord Rich Presence, replacing the Electron host's @xhayper/discord-rpc
//! integration. Same client id, same modes: disabled / limited (connected, no
//! activity details) / full (cached presence shown). Connection failures are
//! silent — Discord not running is normal.

#[cfg(desktop)]
use discord_rich_presence::{activity, DiscordIpc, DiscordIpcClient};
use serde::Deserialize;
use std::sync::Mutex;

const CLIENT_ID: &str = "1301772260780019742";

#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum RpcMode {
    #[default]
    Disabled,
    Limited,
    Full,
}

/// The activity shape the frontend sends, matching the JS presence objects.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Presence {
    pub details: Option<String>,
    pub state: Option<String>,
    pub large_image: Option<String>,
    pub large_text: Option<String>,
    pub small_image: Option<String>,
    pub small_text: Option<String>,
    pub start: Option<i64>,
}

#[derive(Default)]
pub struct DiscordState {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    #[cfg(desktop)]
    client: Option<DiscordIpcClient>,
    mode: RpcMode,
    cached: Option<Presence>,
}

impl DiscordState {
    #[cfg(mobile)]
    fn apply(_inner: &mut Inner) {} // no Discord client on phones/TV boxes

    #[cfg(desktop)]
    fn apply(inner: &mut Inner) {
        if inner.mode == RpcMode::Disabled {
            if let Some(client) = inner.client.as_mut() {
                let _ = client.clear_activity();
                let _ = client.close();
            }
            inner.client = None;
            return;
        }
        if inner.client.is_none() {
            let mut client = DiscordIpcClient::new(CLIENT_ID);
            if client.connect().is_err() {
                return; // Discord not running; presence quietly does nothing
            }
            inner.client = Some(client);
        }
        let Some(client) = inner.client.as_mut() else { return };
        match (&inner.mode, &inner.cached) {
            (RpcMode::Full, Some(presence)) => {
                let mut act = activity::Activity::new().activity_type(activity::ActivityType::Watching);
                if let Some(details) = &presence.details {
                    act = act.details(details);
                }
                if let Some(state) = &presence.state {
                    act = act.state(state);
                }
                let mut assets = activity::Assets::new();
                if let Some(image) = &presence.large_image {
                    assets = assets.large_image(image);
                }
                if let Some(text) = &presence.large_text {
                    assets = assets.large_text(text);
                }
                if let Some(image) = &presence.small_image {
                    assets = assets.small_image(image);
                }
                if let Some(text) = &presence.small_text {
                    assets = assets.small_text(text);
                }
                act = act.assets(assets);
                if let Some(start) = presence.start {
                    act = act.timestamps(activity::Timestamps::new().start(start));
                }
                let _ = client.set_activity(act);
            }
            _ => {
                let _ = client.clear_activity();
            }
        }
    }
}

#[tauri::command]
pub fn set_discord_rpc(state: tauri::State<'_, DiscordState>, mode: RpcMode) {
    let mut inner = state.inner.lock().unwrap();
    if inner.mode != mode {
        inner.mode = mode;
        DiscordState::apply(&mut inner);
    }
}

#[tauri::command]
pub fn set_presence(state: tauri::State<'_, DiscordState>, presence: Presence) {
    let mut inner = state.inner.lock().unwrap();
    inner.cached = Some(presence);
    DiscordState::apply(&mut inner);
}

#[tauri::command]
pub fn clear_presence(state: tauri::State<'_, DiscordState>) {
    let mut inner = state.inner.lock().unwrap();
    inner.cached = None;
    DiscordState::apply(&mut inner);
}
