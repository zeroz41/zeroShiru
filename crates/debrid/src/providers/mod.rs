//! Provider implementations. Each is a thin HTTP mapping over the shared client;
//! the JS originals under common/modules/debrid/ are the behavioural reference,
//! pinned by the tests ported from test/unit/debrid/.

pub mod torbox;
pub mod realdebrid;
pub mod alldebrid;
pub mod premiumize;





