//! Which destinations page content may ask a host to fetch on its behalf.
//!
//! A host with a native HTTP client can fetch anything the machine can reach, including the
//! machine itself — the router's admin page, a metadata service on a link-local address, a
//! service listening only on loopback. A browser's same-origin rules are what normally stand
//! between page content and all of that, and handing the page a native client removes them.
//! So the host puts this in their place: only public http(s) destinations, checked again on
//! every redirect hop, because a redirect is a destination the caller never named.
//!
//! Pure: URLs and addresses in, verdict out. The DNS half belongs to the host, which resolves
//! the name and asks [`is_public_addr`] about what came back.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Blocked {
    #[error("only http and https URLs may be fetched")]
    Scheme,
    #[error("the URL has no host")]
    NoHost,
    #[error("private, local and link-local addresses may not be fetched")]
    Private,
    #[error("only publicly resolvable names may be fetched")]
    NotPublicName,
}

/// Suffixes that never name something on the public internet.
const LOCAL_SUFFIXES: &[&str] = &[".local", ".localhost", ".internal", ".home.arpa", ".onion"];

/// Checks a URL's scheme and host. A host given as an IP literal is checked directly; a name is
/// checked for shape only, since what it resolves to is the host's business — see
/// [`is_public_addr`].
pub fn check_url(url: &str) -> Result<(), Blocked> {
    let (scheme, rest) = url.split_once("://").ok_or(Blocked::Scheme)?;
    if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
        return Err(Blocked::Scheme);
    }
    check_host(host_of(rest).ok_or(Blocked::NoHost)?)
}

/// The host part of everything after `scheme://`, without userinfo, port or path.
fn host_of(rest: &str) -> Option<&str> {
    let authority = rest.split(['/', '?', '#']).next()?;
    // user:password@host — the last '@' wins, so a userinfo containing one cannot smuggle a host
    let authority = authority.rsplit('@').next()?;
    if let Some(end) = authority.strip_prefix('[').and_then(|rest| rest.find(']').map(|at| at + 1)) {
        return Some(&authority[1..end]); // [::1]:8080 -> ::1
    }
    let host = authority.split(':').next()?;
    (!host.is_empty()).then_some(host)
}

fn check_host(host: &str) -> Result<(), Blocked> {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty() {
        return Err(Blocked::NoHost);
    }
    if let Ok(address) = host.parse::<IpAddr>() {
        return if is_public_addr(address) { Ok(()) } else { Err(Blocked::Private) };
    }
    if host == "localhost" || LOCAL_SUFFIXES.iter().any(|suffix| host.ends_with(suffix)) {
        return Err(Blocked::Private);
    }
    // a name with no dot is a machine on this network, not a site
    if !host.contains('.') {
        return Err(Blocked::NotPublicName);
    }
    Ok(())
}

/// Whether an address is out on the public internet, as opposed to this machine, this network,
/// or somewhere the IP stack treats specially.
pub fn is_public_addr(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(address: Ipv4Addr) -> bool {
    let [a, b, ..] = address.octets();
    !(address.is_loopback()
        || address.is_private()
        || address.is_link_local()
        || address.is_broadcast()
        || address.is_documentation()
        || address.is_unspecified()
        || address.is_multicast()
        || a == 0
        || a == 100 && (64..128).contains(&b) // carrier-grade NAT
        || a == 192 && b == 0                 // IETF protocol assignments
        || a == 198 && (18..20).contains(&b)  // benchmarking
        || a >= 240)                          // reserved, includes 255.255.255.255
}

fn is_public_v6(address: Ipv6Addr) -> bool {
    if let Some(v4) = address.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let first = address.segments()[0];
    !(address.is_loopback()
        || address.is_unspecified()
        || address.is_multicast()
        || first & 0xfe00 == 0xfc00  // unique local
        || first & 0xffc0 == 0xfe80  // link-local
        || first == 0x0100           // discard-only
        || first == 0x2001 && address.segments()[1] & 0xff00 == 0x0d00) // documentation
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blocked(url: &str) -> Blocked {
        check_url(url).expect_err(&format!("{url} should not be reachable from page content"))
    }

    #[test]
    fn ordinary_sites_are_reachable() {
        for url in [
            "https://nyaa.si/?page=rss&q=one+piece",
            "http://feed.animetosho.org/json?q=frieren",
            "https://torrentio.strem.fun/manifest.json",
            "https://sub.domain.example.co.uk/path",
            "https://1.1.1.1/dns-query",
            "HTTPS://Example.COM/",
        ] {
            assert_eq!(check_url(url), Ok(()), "{url}");
        }
    }

    #[test]
    fn only_http_urls_are_fetched() {
        assert_eq!(blocked("file:///etc/passwd"), Blocked::Scheme);
        assert_eq!(blocked("shiru://localhost/app.html"), Blocked::Scheme);
        assert_eq!(blocked("ftp://example.com/x"), Blocked::Scheme);
        assert_eq!(blocked("javascript:alert(1)"), Blocked::Scheme);
        assert_eq!(blocked("/just/a/path"), Blocked::Scheme);
    }

    #[test]
    fn this_machine_is_not_a_website() {
        for url in [
            "http://localhost:8080/admin",
            "http://127.0.0.1/",
            "http://127.1.2.3/",
            "http://[::1]:9000/",
            "http://0.0.0.0/",
        ] {
            assert_eq!(blocked(url), Blocked::Private, "{url}");
        }
    }

    #[test]
    fn the_local_network_is_not_the_internet() {
        for url in [
            "http://192.168.1.1/",       // the router's admin page
            "http://10.0.0.5/",
            "http://172.16.4.4/",
            "http://[fd00::1]/",         // unique local
            "http://100.64.0.1/",        // carrier-grade NAT
        ] {
            assert_eq!(blocked(url), Blocked::Private, "{url}");
        }
    }

    #[test]
    fn link_local_metadata_services_are_not_reachable() {
        // where a cloud instance keeps its credentials
        assert_eq!(blocked("http://169.254.169.254/latest/meta-data/"), Blocked::Private);
        assert_eq!(blocked("http://[fe80::1]/"), Blocked::Private);
    }

    #[test]
    fn names_that_cannot_be_public_are_refused() {
        assert_eq!(blocked("http://printer.local/"), Blocked::Private);
        assert_eq!(blocked("http://db.internal/"), Blocked::Private);
        assert_eq!(blocked("http://something.onion/"), Blocked::Private);
        assert_eq!(blocked("http://intranet/"), Blocked::NotPublicName);
        assert_eq!(blocked("http://LOCALHOST./"), Blocked::Private, "a trailing dot is the same name");
    }

    #[test]
    fn userinfo_cannot_smuggle_a_host_past_the_check() {
        assert_eq!(blocked("http://example.com@127.0.0.1/"), Blocked::Private);
        assert_eq!(blocked("http://user:pass@[::1]/"), Blocked::Private);
        assert_eq!(check_url("http://user:pass@example.com/"), Ok(()));
    }

    #[test]
    fn a_port_is_not_part_of_the_host() {
        assert_eq!(check_url("https://example.com:8443/x"), Ok(()));
        assert_eq!(blocked("https://127.0.0.1:8443/x"), Blocked::Private);
    }

    #[test]
    fn an_ipv4_written_as_ipv6_is_still_that_address() {
        assert_eq!(blocked("http://[::ffff:127.0.0.1]/"), Blocked::Private);
        assert_eq!(blocked("http://[::ffff:192.168.0.1]/"), Blocked::Private);
    }

    #[test]
    fn resolved_addresses_are_judged_the_same_way() {
        // what the host asks after resolving a name, which is how a public name pointed at
        // something local gets caught
        assert!(!is_public_addr("127.0.0.1".parse().unwrap()));
        assert!(!is_public_addr("192.168.0.1".parse().unwrap()));
        assert!(!is_public_addr("::1".parse().unwrap()));
        assert!(is_public_addr("1.1.1.1".parse().unwrap()));
        assert!(is_public_addr("2606:4700::1111".parse().unwrap()));
    }

    #[test]
    fn a_url_with_no_host_is_refused() {
        assert_eq!(blocked("http:///path"), Blocked::NoHost);
        assert_eq!(blocked("http://:8080/"), Blocked::NoHost);
    }
}
