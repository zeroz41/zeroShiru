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
    /// When playback started, as a unix timestamp in milliseconds. Read leniently: the
    /// page computes it from a playback position measured in fractional seconds, and a
    /// presence that is a millisecond out is worth more than one that is rejected.
    #[serde(default, deserialize_with = "lenient_millis")]
    pub start: Option<i64>,
}

/// Accepts a whole or fractional number of milliseconds, or nothing at all.
fn lenient_millis<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(match value {
        Some(serde_json::Value::Number(number)) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|millis| millis.round() as i64)),
        _ => None,
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The presence the page sends while something is playing: its start is computed from a
    /// playback position in fractional seconds, so it arrives as a fraction of a millisecond.
    #[test]
    fn a_start_time_with_a_fraction_of_a_millisecond_is_still_a_start_time() {
        let presence: Presence = serde_json::from_str(r#"{"start": 1787260099123.456}"#).unwrap();
        assert_eq!(presence.start, Some(1_787_260_099_123));
        // this is what used to be refused outright, once per playback update
        let whole: Presence = serde_json::from_str(r#"{"start": 1787260099123}"#).unwrap();
        assert_eq!(whole.start, Some(1_787_260_099_123));
    }

    #[test]
    fn a_presence_without_a_start_time_is_not_a_failure() {
        for body in [r#"{}"#, r#"{"start": null}"#, r#"{"details": "Watching"}"#] {
            let presence: Presence = serde_json::from_str(body).expect(body);
            assert_eq!(presence.start, None);
        }
    }
}
