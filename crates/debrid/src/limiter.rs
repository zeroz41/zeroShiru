//! Request pacing. Port of the Bottleneck limiter the JS base class wrapped every
//! request in — `common/modules/debrid/service.js` gave each service a
//! `{ maxConcurrent, minTime, reservoir… }` and never issued a request outside it.
//!
//! This existed for a measured reason: TorBox answered a 60-link burst against
//! `/torrents/requestdl` with `429` and `retry-after: 300`, five minutes of the
//! account frozen mid-play. Without pacing, the only way to avoid the burst is to
//! send everything one at a time and wait out every round trip, which is how a
//! season pack's links came to cost twelve serial requests before playback started.
//! With pacing, they can go out together and still stay inside the allowance.
//!
//! Three things hold a request back, checked in that order:
//!
//! 1. **A pause the service asked for.** A `429` carrying `retry-after` stops
//!    everything on that account, not just the request that earned it — the next one
//!    through would only collect another.
//! 2. **The allowance**, where the service publishes one: N requests per window,
//!    refilled on the window boundary.
//! 3. **Concurrency and spacing**: at most `max_concurrent` in flight, and starts
//!    never closer together than `min_time_ms`.
//!
//! No timers, no runtime: waiting is `Platform::sleep`, so the same limiter runs
//! under tokio on the desktop and under `setTimeout` on the TVs.

use crate::platform::Platform;
use std::sync::{Arc, Mutex};

/// How often a request waiting on a full pipe looks again. Nothing wakes it — the
/// alternative is a condvar or channel per provider, and this only ever spins while
/// `max_concurrent` requests are genuinely in flight, which for these services is
/// three or four.
const BUSY_POLL_MS: u64 = 20;

/// What a service will put up with. The numbers live on `ProviderConfig`.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Requests in flight at once.
    pub max_concurrent: usize,
    /// Smallest gap between two request starts.
    pub min_time_ms: u64,
    /// Requests per window, where the service publishes an allowance: `(count, window_ms)`.
    pub reservoir: Option<(u32, u64)>,
}

#[derive(Debug)]
struct State {
    in_flight: usize,
    /// Earliest a request may start, so starts stay `min_time_ms` apart.
    next_start: u64,
    /// Nothing starts before this: the service asked for a pause.
    paused_until: u64,
    /// Requests left in the current window, and when that window opened.
    tokens: u32,
    window_opened: u64,
    /// Everyone waiting, in the order they arrived. Only the front may take a slot.
    ///
    /// The queue has to be first-come-first-served, not whoever the executor happens to
    /// wake: providers put the file the user actually asked for at the head of a pack's
    /// link requests precisely so that, if the burst trips a limit, that one is the
    /// request that already went through. A limiter that reorders quietly throws that
    /// away, and the symptom is playing the wrong episode of a pack under load.
    waiting: std::collections::BTreeSet<u64>,
    next_ticket: u64,
}

pub struct Limiter {
    limits: Limits,
    state: Arc<Mutex<State>>,
}

/// A request's place in the pipe, given back when the request finishes — including
/// when it fails, which is what keeps a run of errors from wedging the limiter.
pub struct Permit {
    state: Arc<Mutex<State>>,
}

impl Drop for Permit {
    fn drop(&mut self) {
        // never unwrap in a destructor: a panic anywhere else poisons this lock, and
        // panicking again while unwinding aborts the process
        let mut state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        state.in_flight = state.in_flight.saturating_sub(1);
    }
}

/// A place in the queue, given up whether the request goes out or the caller walks away
/// mid-wait. Without the second half a dropped future — a resolve that hit its overall
/// budget, say — would leave a ticket at the front of a queue nobody is holding, and
/// every request after it would wait behind a ghost forever.
struct Ticket {
    state: Arc<Mutex<State>>,
    number: u64,
    held: bool,
}

impl Ticket {
    fn take(state: &Arc<Mutex<State>>) -> Ticket {
        let number = {
            let mut locked = state.lock().unwrap();
            let number = locked.next_ticket;
            locked.next_ticket += 1;
            locked.waiting.insert(number);
            number
        };
        Ticket { state: state.clone(), number, held: true }
    }

    /// The wait is over, so the place in the queue is no longer needed.
    fn done(&mut self) {
        if self.held {
            let mut state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            state.waiting.remove(&self.number);
            self.held = false;
        }
    }
}

impl Drop for Ticket {
    fn drop(&mut self) {
        self.done();
    }
}

impl Limiter {
    pub fn new(limits: Limits) -> Self {
        let tokens = limits.reservoir.map(|(count, _)| count).unwrap_or(0);
        Limiter {
            limits,
            state: Arc::new(Mutex::new(State {
                in_flight: 0,
                next_start: 0,
                paused_until: 0,
                tokens,
                window_opened: 0,
                waiting: Default::default(),
                next_ticket: 0,
            })),
        }
    }

    /// Waits until this request may go out, then holds a slot until the permit drops.
    pub async fn acquire(&self, platform: &dyn Platform) -> Permit {
        let mut ticket = Ticket::take(&self.state);
        loop {
            let wait = {
                let mut state = self.state.lock().unwrap();
                self.take(&mut state, platform.now_ms(), Some(ticket.number))
            };
            if wait == 0 {
                ticket.done();
                return Permit { state: self.state.clone() };
            }
            platform.sleep(wait).await;
        }
    }

    /// Takes a slot, or says how long to wait before asking again. Split out so the
    /// arithmetic is testable without a clock or a runtime.
    fn take(&self, state: &mut State, now: u64, ticket: Option<u64>) -> u64 {
        // whoever arrived first goes first, whatever order the executor wakes them in
        if let Some(ticket) = ticket {
            if state.waiting.iter().next() != Some(&ticket) {
                return BUSY_POLL_MS;
            }
        }
        if now < state.paused_until {
            return state.paused_until - now;
        }
        if let Some((count, window)) = self.limits.reservoir {
            if now.saturating_sub(state.window_opened) >= window {
                state.tokens = count;
                state.window_opened = now;
            }
            if state.tokens == 0 {
                // the window closes when it closes; asking sooner only earns a refusal
                return (state.window_opened + window).saturating_sub(now).max(1);
            }
        }
        if state.in_flight >= self.limits.max_concurrent {
            return BUSY_POLL_MS;
        }
        if now < state.next_start {
            return state.next_start - now;
        }
        state.in_flight += 1;
        state.next_start = now + self.limits.min_time_ms;
        if self.limits.reservoir.is_some() {
            state.tokens = state.tokens.saturating_sub(1);
        }
        0
    }

    /// The service asked for a pause — a `429` with a `retry-after`. It stops every
    /// request on this account, not only the one that earned it: the rest would walk
    /// into the same refusal, and one of them is usually the playback the user is
    /// waiting on. Extends an existing pause, never shortens it.
    pub fn pause_for(&self, platform: &dyn Platform, ms: u64) {
        let mut state = self.state.lock().unwrap();
        state.paused_until = state.paused_until.max(platform.now_ms() + ms);
    }

    /// Whether the service has this account paused right now.
    pub fn paused(&self, platform: &dyn Platform) -> bool {
        platform.now_ms() < self.state.lock().unwrap().paused_until
    }

    /// The pipe as it stands, for diagnostics: requests in flight, callers waiting
    /// behind them, and how much of a service-requested pause is left.
    pub fn snapshot(&self, platform: &dyn Platform) -> LimiterHealth {
        let state = self.state.lock().unwrap();
        LimiterHealth {
            in_flight: state.in_flight,
            waiting: state.waiting.len(),
            paused_for_ms: state.paused_until.saturating_sub(platform.now_ms()),
        }
    }
}

/// A diagnostic view of the limiter. Plain data, so hosts can serialize it however
/// their IPC wants.
#[derive(Debug, Clone, Copy)]
pub struct LimiterHealth {
    pub in_flight: usize,
    pub waiting: usize,
    pub paused_for_ms: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::ManualClock;

    fn limiter(max_concurrent: usize, min_time_ms: u64, reservoir: Option<(u32, u64)>) -> Limiter {
        Limiter::new(Limits { max_concurrent, min_time_ms, reservoir })
    }

    #[tokio::test]
    async fn requests_go_out_no_closer_together_than_the_service_allows() {
        let clock = ManualClock::new();
        let limiter = limiter(4, 200, None);
        let start = clock.now_ms();
        for _ in 0..5 {
            drop(limiter.acquire(&clock).await);
        }
        // four gaps of 200ms between five starts
        assert_eq!(clock.now_ms() - start, 800);
    }

    #[tokio::test]
    async fn only_so_many_may_be_in_flight_at_once() {
        let clock = ManualClock::new();
        let limiter = limiter(2, 0, None);
        let first = limiter.acquire(&clock).await;
        let second = limiter.acquire(&clock).await;
        assert_eq!(limiter.state.lock().unwrap().in_flight, 2);
        // a third has to wait for one of them to finish
        assert_eq!(limiter.take(&mut limiter.state.lock().unwrap(), clock.now_ms(), None), BUSY_POLL_MS);
        drop(first);
        assert_eq!(limiter.take(&mut limiter.state.lock().unwrap(), clock.now_ms(), None), 0);
        drop(second);
    }

    #[tokio::test]
    async fn a_request_that_failed_still_gives_its_slot_back() {
        // otherwise a run of errors wedges the limiter and nothing goes out again
        let clock = ManualClock::new();
        let limiter = limiter(1, 0, None);
        for _ in 0..10 {
            drop(limiter.acquire(&clock).await);
        }
        assert_eq!(limiter.state.lock().unwrap().in_flight, 0);
    }

    #[tokio::test]
    async fn an_allowance_is_spent_and_refilled_on_its_own_window() {
        let clock = ManualClock::new();
        let limiter = limiter(4, 0, Some((3, 60_000)));
        let start = clock.now_ms();
        for _ in 0..3 {
            drop(limiter.acquire(&clock).await);
        }
        assert_eq!(clock.now_ms(), start, "the allowance is not a delay while it lasts");
        drop(limiter.acquire(&clock).await);
        assert!(clock.now_ms() - start >= 60_000, "the fourth waits for the window to reopen");
    }

    #[tokio::test]
    async fn a_pause_the_service_asked_for_stops_everything_on_the_account() {
        // the shape this exists for: a 429 with retry-after, where the next request
        // through would only collect another one — playback included
        let clock = ManualClock::new();
        let limiter = limiter(4, 0, None);
        limiter.pause_for(&clock, 5_000);
        assert!(limiter.paused(&clock));
        let start = clock.now_ms();
        drop(limiter.acquire(&clock).await);
        assert!(clock.now_ms() - start >= 5_000);
        assert!(!limiter.paused(&clock));
    }

    #[tokio::test]
    async fn whoever_asked_first_goes_first() {
        // providers put the file the user asked for at the head of a pack's link requests,
        // so that if the burst trips a limit that one is the request that already went
        // through. A limiter that reorders quietly throws that guarantee away
        let clock = Arc::new(ManualClock::new());
        let limiter = Arc::new(limiter(1, 0, None));
        let order = Arc::new(Mutex::new(Vec::new()));
        let waiters = (0..5).map(|index| {
            let (limiter, clock, order) = (limiter.clone(), clock.clone(), order.clone());
            async move {
                let permit = limiter.acquire(clock.as_ref()).await;
                order.lock().unwrap().push(index);
                // held across a yield, so the next one really does have to wait its turn
                clock.sleep(1).await;
                drop(permit);
            }
        });
        futures::future::join_all(waiters).await;
        assert_eq!(*order.lock().unwrap(), vec![0, 1, 2, 3, 4]);
    }

    #[tokio::test]
    async fn a_caller_that_walked_away_mid_wait_does_not_hold_the_queue_up() {
        // a resolve that hit its overall budget drops its request future where it stands
        let clock = ManualClock::new();
        let limiter = limiter(1, 0, None);
        let held = limiter.acquire(&clock).await;
        let mut abandoned = Box::pin(limiter.acquire(&clock));
        // polled once so it takes a ticket, then dropped without ever getting a slot
        assert!(futures::poll!(abandoned.as_mut()).is_pending());
        drop(abandoned);
        drop(held);
        assert_eq!(limiter.state.lock().unwrap().waiting.len(), 0, "no ghost at the front of the queue");
        // and the next request really does go out rather than waiting behind it
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), limiter.acquire(&clock))
            .await
            .expect("a dropped waiter must not wedge the limiter");
    }

    #[tokio::test]
    async fn a_longer_pause_wins_over_one_already_running() {
        let clock = ManualClock::new();
        let limiter = limiter(4, 0, None);
        limiter.pause_for(&clock, 10_000);
        limiter.pause_for(&clock, 1_000);
        let start = clock.now_ms();
        drop(limiter.acquire(&clock).await);
        assert!(clock.now_ms() - start >= 10_000, "the shorter one must not cut it short");
    }
}
