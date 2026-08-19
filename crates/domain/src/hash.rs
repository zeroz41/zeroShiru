//! Info-hash parsing shared by every layer that touches a magnet.
//! Port of DebridService.parseHash / toMagnet in common/modules/debrid/service.js.

/// The lowercase info hash of a magnet URI or bare hash, `None` when there is none.
pub fn parse_hash(magnet_or_hash: &str) -> Option<String> {
    if let Some(found) = find_btih(magnet_or_hash) {
        return Some(found.to_ascii_lowercase());
    }
    if is_hex40(magnet_or_hash) {
        return Some(magnet_or_hash.to_ascii_lowercase());
    }
    None
}

/// A magnet URI to hand to an API, from a magnet URI or bare info hash.
/// `None` when the input holds no usable hash.
pub fn to_magnet(magnet_or_hash: &str) -> Option<String> {
    if magnet_or_hash.starts_with("magnet:") {
        return Some(magnet_or_hash.to_string());
    }
    parse_hash(magnet_or_hash).map(|hash| format!("magnet:?xt=urn:btih:{hash}"))
}

/// First `urn:btih:<40 hex>` in the string, case-insensitive like the JS regex.
fn find_btih(input: &str) -> Option<&str> {
    let lower = input.as_bytes();
    let needle = b"urn:btih:";
    let mut start = 0;
    while start + needle.len() <= lower.len() {
        let window = &lower[start..start + needle.len()];
        if window.eq_ignore_ascii_case(needle) {
            let rest = &input[start + needle.len()..];
            if rest.len() >= 40 && is_hex40(&rest[..40]) {
                return Some(&rest[..40]);
            }
        }
        start += 1;
    }
    None
}

fn is_hex40(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn parses_bare_hashes_case_insensitively() {
        assert_eq!(parse_hash(HASH).as_deref(), Some(HASH));
        assert_eq!(parse_hash(&HASH.to_uppercase()).as_deref(), Some(HASH));
    }

    #[test]
    fn parses_magnets() {
        let magnet = format!("magnet:?xt=urn:btih:{}&dn=Some+Release", HASH.to_uppercase());
        assert_eq!(parse_hash(&magnet).as_deref(), Some(HASH));
    }

    #[test]
    fn rejects_junk() {
        assert_eq!(parse_hash(""), None);
        assert_eq!(parse_hash("not a hash"), None);
        assert_eq!(parse_hash(&HASH[..39]), None);
        assert_eq!(parse_hash("magnet:?xt=urn:btih:zzz"), None);
    }

    #[test]
    fn to_magnet_passes_magnets_through_and_wraps_hashes() {
        let magnet = format!("magnet:?xt=urn:btih:{HASH}");
        assert_eq!(to_magnet(&magnet).as_deref(), Some(magnet.as_str()));
        assert_eq!(to_magnet(&HASH.to_uppercase()).as_deref(), Some(magnet.as_str()));
        assert_eq!(to_magnet("junk"), None);
    }
}
