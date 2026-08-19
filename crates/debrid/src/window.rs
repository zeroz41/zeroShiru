//! Caps a pack's file list around the file playback wants rather than taking the
//! first N. Port of DebridService.windowFiles; test/unit/debrid/window.test.js is
//! the behavioural reference.

/// Returns the window of `files` that keeps `target` (by index) reachable, preserving
/// torrent order so in-player next/previous still works.
pub fn window_files<T>(files: &[T], target: Option<usize>, max_files: usize) -> &[T] {
    if files.len() <= max_files {
        return files;
    }
    let start = match target {
        None => 0,
        Some(index) if index >= files.len() => 0,
        Some(index) => index
            .saturating_sub(max_files >> 1)
            .min(files.len() - max_files),
    };
    &files[start..start + max_files]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pack(length: usize) -> Vec<String> {
        (1..=length).map(|index| format!("/Episode {index:03}.mkv")).collect()
    }

    fn position(files: &[String], episode: usize) -> Option<usize> {
        let path = format!("/Episode {episode:03}.mkv");
        files.iter().position(|file| file == &path)
    }

    #[test]
    fn a_pack_within_the_cap_is_passed_through_untouched() {
        let files = pack(60);
        let windowed = window_files(&files, position(&files, 30), 60);
        assert_eq!(windowed.len(), files.len());
        assert!(std::ptr::eq(windowed.as_ptr(), files.as_ptr()));
    }

    #[test]
    fn the_requested_episode_always_survives_the_cap() {
        let files = pack(200);
        for wanted in [1, 2, 30, 100, 170, 199, 200] {
            let windowed = window_files(&files, position(&files, wanted), 60);
            assert_eq!(windowed.len(), 60, "episode {wanted}: the cap holds");
            let path = format!("/Episode {wanted:03}.mkv");
            assert!(windowed.contains(&path), "episode {wanted} must survive its own window");
        }
    }

    #[test]
    fn the_window_centers_on_the_episode() {
        let files = pack(200);
        let windowed = window_files(&files, position(&files, 100), 60);
        assert!(windowed.contains(&"/Episode 099.mkv".to_string()), "previous episode");
        assert!(windowed.contains(&"/Episode 101.mkv".to_string()), "next episode");
        let index = windowed.iter().position(|file| file == "/Episode 100.mkv").unwrap();
        assert!((25..=35).contains(&index), "episode should sit near the middle, sat at {index}");
    }

    #[test]
    fn a_window_near_the_start_clamps_without_shrinking() {
        let files = pack(200);
        let windowed = window_files(&files, position(&files, 3), 60);
        assert_eq!(windowed[0], files[0], "clamped to the start");
        assert_eq!(windowed.len(), 60, "and still full size");
    }

    #[test]
    fn a_window_near_the_end_clamps_without_running_past_the_pack() {
        let files = pack(200);
        let windowed = window_files(&files, position(&files, 198), 60);
        assert_eq!(windowed[59], files[199], "clamped to the end");
        assert_eq!(windowed.len(), 60);
    }

    #[test]
    fn torrent_order_is_preserved() {
        let files = pack(200);
        let windowed = window_files(&files, position(&files, 100), 60);
        let mut sorted = windowed.to_vec();
        sorted.sort();
        assert_eq!(windowed, &sorted[..], "files must stay in torrent order");
    }

    #[test]
    fn no_target_takes_the_head_of_the_list_rather_than_guessing() {
        let files = pack(200);
        assert_eq!(window_files(&files, None, 60), &files[..60]);
    }

    #[test]
    fn a_target_missing_from_the_list_degrades_to_the_head_never_to_an_empty_window() {
        let files = pack(200);
        assert_eq!(window_files(&files, Some(usize::MAX), 60), &files[..60]);
    }
}
