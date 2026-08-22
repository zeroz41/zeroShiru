//! The orchestration half of the JS DebridService base class: remembered answers
//! come back free, the rest are asked about the cheapest way the service supports,
//! sweeps stop when the service is in no state to answer more. Runtime-agnostic —
//! concurrency is plain futures, so the same code serves native and WASM hosts.

use crate::client::DebridClient;
use crate::error::DebridError;
use crate::platform::Platform;
use crate::{AvailabilityCheck, DebridProvider};
use shiru_domain::Availability;
use shiru_networking::HttpTransport;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Every service the app can be configured to use, in the order the settings menu
/// offers them. The one list; hosts enumerate it rather than naming services.
pub const PROVIDER_IDS: [&str; 4] = ["alldebrid", "premiumize", "realdebrid", "torbox"];

/// Consecutive unanswered probes before a sweep gives up.
const MAX_PROBE_FAILURES: usize = 3;
/// How long a watch waits before asking again about releases a check could not answer.
/// Without the retry, one bad minute leaves a results list half badged for good.
const WATCH_RETRY_MS: u64 = 10_000;
/// How far the retry backs off while the service keeps not answering.
const WATCH_RETRY_MAX_MS: u64 = 4 * 60_000;
/// Probes running at once. Small, since each briefly owns a torrent on the account.
const MAX_PROBE_CONCURRENCY: usize = 3;
/// How long a resolve waits for a probe of the same release to finish before going
/// ahead anyway. A probe owns a torrent on the account until it tears it down, and a
/// resolve that reuses that id gets a torrent deleted out from under it mid-play.
const PROBE_HANDOVER_MS: u64 = 5_000;
/// How often that wait looks again.
const PROBE_HANDOVER_POLL_MS: u64 = 100;

/// Builds a provider by its settings id. The one place the concrete types appear.
pub fn create_provider(
    id: &str,
    api_key: String,
    transport: Arc<dyn HttpTransport>,
    platform: Arc<dyn Platform>,
) -> Option<Arc<dyn DebridProvider>> {
    use crate::providers::{alldebrid::AllDebrid, premiumize::Premiumize, realdebrid::RealDebrid, torbox::TorBox};
    Some(match id {
        "torbox" => Arc::new(TorBox::new(api_key, transport, platform)),
        "realdebrid" => Arc::new(RealDebrid::new(&api_key, transport, platform)),
        "alldebrid" => Arc::new(AllDebrid::new(&api_key, transport, platform)),
        "premiumize" => Arc::new(Premiumize::new(api_key, transport, platform)),
        _ => return None,
    })
}

/// What a watch reports as it goes. Borrowed payloads: events are delivered inline and
/// hosts serialize them on the spot.
pub enum WatchEvent<'a> {
    /// One release answered, with the service's own name for it when it has one.
    Answer { hash: &'a str, state: Availability, name: Option<String> },
    /// Whether a round of asking is on the wire right now, as opposed to waiting out a
    /// backoff. The UI shows badges still filling in while this is true.
    Checking(bool),
    /// A round failed. The watch retries on its own unless the failure was auth, which
    /// ends it — retrying a bad key answers nothing.
    Outage(&'a DebridError),
}

/// Wraps a provider with the shared availability bookkeeping.
pub struct ManagedProvider {
    provider: Arc<dyn DebridProvider>,
    /// Whether a check that adds magnets is running, since only one may be.
    sweeping: AtomicBool,
    /// Hashes being probed right now. The JS shares the pending promise; here a
    /// second asker skips the hash rather than asking about it twice — it stays
    /// unknown and re-checkable, and skipping is not a failure to answer.
    in_flight: Mutex<std::collections::HashSet<String>>,
}

impl ManagedProvider {
    pub fn new(provider: Arc<dyn DebridProvider>) -> Self {
        ManagedProvider {
            provider,
            sweeping: AtomicBool::new(false),
            in_flight: Mutex::new(Default::default()),
        }
    }

    pub fn provider(&self) -> &Arc<dyn DebridProvider> {
        &self.provider
    }

    pub fn client(&self) -> &DebridClient {
        self.provider.client()
    }

    /// Turns a magnet into player-ready files, and gives up if the service will not.
    ///
    /// Every other budget in `Timeouts` bounds one round trip, but a resolve is a chain of
    /// them — add the magnet, poll until it settles, then ask for a link per file. A service
    /// that answers each of those slowly, or accepts the connection and never answers at all,
    /// can therefore leave somebody watching a black screen for minutes while nothing is
    /// wrong as far as any single request is concerned. This is the end-to-end bound, so a
    /// silent service becomes a message rather than a wait with no end.
    pub async fn resolve(
        &self,
        magnet: &str,
        opts: &crate::ResolveOptions,
    ) -> Result<crate::DebridResolved, DebridError> {
        let budget = self.client().config.timeouts.resolve;
        let platform = self.client().platform();
        self.await_probe(magnet).await;
        let work = self.provider.resolve(magnet, opts);
        futures::pin_mut!(work);
        let resolved = match futures::future::select(work, Box::pin(platform.sleep(budget))).await {
            futures::future::Either::Left((result, _)) => result,
            futures::future::Either::Right(_) => Err(DebridError::Timeout {
                message: format!(
                    "{} did not answer with a playable link within {}s",
                    self.provider.config().title,
                    budget / 1_000
                ),
            }),
        }?;
        // enforced here rather than trusted to each provider: a debrid link is account
        // bound, so a cleartext one puts the user's traffic and their link on the wire in
        // the clear, and that must not depend on a provider having remembered to check
        let files = crate::secure_files(resolved.files, self.provider.config().title)?;
        Ok(crate::DebridResolved { files, ..resolved })
    }

    /// Waits out a probe of this same release before resolving it.
    ///
    /// A probe on a service with no cache endpoint works by putting the magnet on the
    /// account, reading the status back and taking it off again. A resolve that starts
    /// while one is in the air finds that torrent, reuses its id, and then has it
    /// deleted out from under it as the probe finishes — which reaches the user as a
    /// play that dies a second after it starts, for a release that is definitely
    /// cached. Waiting is bounded: a probe that outlives the budget is one this resolve
    /// will simply have to race, and a resolve that adds the magnet again is recoverable
    /// where a resolve that waits forever is not.
    async fn await_probe(&self, magnet: &str) {
        let Some(hash) = shiru_domain::parse_hash(magnet) else { return };
        let platform = self.client().platform();
        let deadline = platform.now_ms() + PROBE_HANDOVER_MS;
        while self.in_flight.lock().unwrap().contains(&hash) {
            if platform.now_ms() >= deadline {
                tracing::debug!(target: "debrid", %hash, "resolving while a probe of the same release is still running");
                return;
            }
            platform.sleep(PROBE_HANDOVER_POLL_MS).await;
        }
    }

    /// Whether a check that owns the account is running right now. A caller that
    /// finds one running knows its own answers were only read from memory.
    pub fn sweeping(&self) -> bool {
        self.sweeping.load(Ordering::SeqCst)
    }

    /// What the account itself says: the free badge source. The listing behind it is
    /// read at most once a minute and shared with every resolve, in the client — the
    /// badge refresh and the play path both want it, and reading it per play would put
    /// a full account listing ahead of the links the user is waiting for. Answers land
    /// in the availability memory, so later checks are free.
    pub async fn list_availability(&self) -> Result<HashMap<String, Availability>, DebridError> {
        let known = self.provider.list_availability().await?;
        for (hash, state) in &known {
            self.client().remember(hash, *state);
        }
        Ok(known)
    }

    /// Drops the remembered listing, because the account just changed.
    pub async fn forget_listing(&self) {
        self.client().forget_listing().await;
    }

    /// The given hashes nothing is known about yet, in the order supplied. Callers
    /// use this to skip work entirely, not to decide what to ask about.
    pub fn unknown_hashes(&self, magnets_or_hashes: &[String]) -> Vec<String> {
        let in_flight = self.in_flight.lock().unwrap();
        DebridClient::normalize_hashes(magnets_or_hashes, self.provider.config().max_ask())
            .into_iter()
            .filter(|hash| self.client().recall(hash).is_none() && !in_flight.contains(hash))
            .collect()
    }

    /// What the service can do with each of the given releases. Remembered answers
    /// come back free, the rest are asked about the cheapest way the service
    /// supports. Hashes that stay unanswered are absent from the result, which
    /// callers must read as unknown rather than "not cached".
    pub async fn check_availability(
        &self,
        magnets_or_hashes: &[String],
        mut on_answer: impl FnMut(&str, Availability),
    ) -> Result<HashMap<String, Availability>, DebridError> {
        let config = self.provider.config();
        let mut answers = HashMap::new();
        let candidates = DebridClient::normalize_hashes(magnets_or_hashes, config.max_ask());
        let mut unknown = Vec::new();
        for hash in candidates {
            match self.client().recall(&hash) {
                Some(state) => {
                    answers.insert(hash, state);
                }
                None => unknown.push(hash),
            }
        }
        if unknown.is_empty() || config.availability_check == AvailabilityCheck::None {
            return Ok(answers);
        }

        // one at a time where asking adds magnets: services rate limit adding far
        // harder than reading, so overlapping checks do not answer faster, they get refused.
        // The claim is released by the guard's Drop rather than by code after the sweep —
        // a Tauri command being cancelled drops this future wherever it is, and a flag
        // that only reset on the happy path stayed true forever, after which every later
        // check returned memory-only answers while the UI retried on its shortest timer
        let guarded = config.check_adds_magnets;
        let _sweep_claim = if guarded {
            if self.sweeping.swap(true, Ordering::SeqCst) {
                return Ok(answers);
            }
            Some(SweepClaim(&self.sweeping))
        } else {
            None
        };
        // clear our own leftovers before adding more: a check that dropped mid-probe owes
        // the account a removal, and asking again would stack a second one on top of it
        if self.client().orphaned() > 0 {
            self.provider.retry_cleanup().await;
        }
        let result = match config.availability_check {
            AvailabilityCheck::Batch => {
                self.batch(&unknown, &mut |hash, state| {
                    answers.insert(hash.to_string(), state);
                    on_answer(hash, state);
                })
                .await
            }
            AvailabilityCheck::Probe => {
                self.sweep(&unknown, &mut |hash, state| {
                    answers.insert(hash.to_string(), state);
                    on_answer(hash, state);
                })
                .await
            }
            AvailabilityCheck::None => unreachable!(),
        };
        result.map(|()| answers)
    }

    /// Asks about the hashes in as few requests as the service allows. The provider's
    /// batch call already applies its own left-out-hash semantics; unknown here only
    /// means the provider could not answer.
    async fn batch(
        &self,
        hashes: &[String],
        answer: &mut impl FnMut(&str, Availability),
    ) -> Result<(), DebridError> {
        let max_batch = self.provider.config().max_batch;
        // The chunks are independent reads of the same account, so they are asked for
        // together rather than one after another. How many actually travel at once is
        // the client limiter's decision, not this loop's — it was the waiting between
        // chunks that made a long results list badge itself in visible waves.
        let answer = &Mutex::new(answer);
        let asked = futures::future::join_all(hashes.chunks(max_batch).map(|chunk| async move {
            let states = self.provider.check_availability_batch(chunk).await?;
            for hash in chunk {
                let state = states.get(hash).copied().unwrap_or(Availability::Unknown);
                self.client().remember(hash, state);
                if state != Availability::Unknown {
                    (answer.lock().unwrap())(hash, state);
                }
            }
            Ok(())
        }))
        .await;
        // a chunk that failed leaves its own hashes unknown, which is exactly the
        // re-askable state they should be in; the failure is still reported so the UI
        // schedules its retry, and the chunks that did answer keep their answers
        asked.into_iter().collect::<Result<Vec<()>, DebridError>>().map(|_| ())
    }

    /// Probes hashes a few at a time, stopping early once the service is in no state
    /// to answer more. Stopping is not finishing: what is left stays unknown and the
    /// caller comes back to it.
    async fn sweep(
        &self,
        hashes: &[String],
        answer: &mut impl FnMut(&str, Availability),
    ) -> Result<(), DebridError> {
        // worker pool without a runtime dependency: shared queue, N concurrent futures
        let queue = Mutex::new(VecDeque::from(hashes.to_vec()));
        // each answer is published the moment it lands rather than when the sweep ends.
        // A probing service takes several requests per release, so a list of ten is the
        // better part of a minute — badging it all at once at the end reads, for that
        // whole minute, exactly like a service that holds nothing
        let answer = Mutex::new(answer);
        let failures = Mutex::new(0usize);
        let stopped = Mutex::new(Option::<DebridError>::None);

        let worker = || async {
            loop {
                if stopped.lock().unwrap().is_some() {
                    return;
                }
                let Some(hash) = queue.lock().unwrap().pop_front() else {
                    return;
                };
                match self.probe(&hash).await {
                    Ok(Some(state)) => {
                        (answer.lock().unwrap())(&hash, state);
                        *failures.lock().unwrap() = 0;
                    }
                    // somebody else is already asking about this one. Not an answer, and
                    // emphatically not a failure to get one: counting it would let two
                    // overlapping checks stop each other after three shared hashes
                    Ok(None) => {}
                    Err(error) => {
                        let auth = matches!(error, DebridError::Auth { .. });
                        let throttled = self.provider.throttled(&error);
                        let mut count = failures.lock().unwrap();
                        *count += 1;
                        // an auth failure means every other probe would fail too
                        if auth || throttled || *count >= MAX_PROBE_FAILURES {
                            *stopped.lock().unwrap() = Some(error);
                            return;
                        }
                    }
                }
            }
        };

        let workers = hashes.len().clamp(1, MAX_PROBE_CONCURRENCY);
        futures::future::join_all((0..workers).map(|_| worker())).await;

        match stopped.into_inner().unwrap() {
            Some(error @ DebridError::Auth { .. }) => Err(error),
            _ => Ok(()),
        }
    }

    /// Answers about a results list for as long as it takes, pushing each answer as it
    /// lands. This is the whole badge lifecycle in one place: remembered answers first,
    /// then a check round for the rest, then patient retries on a backing-off timer for
    /// whatever the service left unanswered — a service may answer only part of a list,
    /// and one bad minute must not leave the list half badged for good.
    ///
    /// Runs until everything asked about has an answer, or until the caller drops the
    /// future — cancellation is the caller's word for "the user moved on", and every
    /// claim this takes is released by a guard. An auth failure ends it early, since
    /// retrying a bad key answers nothing.
    pub async fn watch_availability(&self, hashes: &[String], mut on_event: impl FnMut(WatchEvent)) {
        let platform = self.client().platform();
        let mut delay = WATCH_RETRY_MS;
        // remembered answers come back before any request, so a list the service has
        // already described badges instantly
        let known = DebridClient::normalize_hashes(hashes, self.provider.config().max_ask());
        for hash in &known {
            if let Some(state) = self.client().recall(hash) {
                on_event(WatchEvent::Answer { hash, state, name: self.client().release_name(hash) });
            }
        }
        loop {
            let pending = self.unknown_hashes(hashes);
            if pending.is_empty() {
                return;
            }
            let busy = self.sweeping();
            on_event(WatchEvent::Checking(true));
            let round = self
                .check_availability(&pending, |hash, state| {
                    on_event(WatchEvent::Answer { hash, state, name: self.client().release_name(hash) })
                })
                .await;
            on_event(WatchEvent::Checking(false));
            match &round {
                Ok(answers) => {
                    tracing::info!(
                        target: "debrid",
                        service = self.provider.config().id,
                        asked = pending.len(),
                        answered = answers.len(),
                        busy,
                        "availability round"
                    );
                }
                Err(error) => {
                    tracing::warn!(target: "debrid", service = self.provider.config().id, %error, "availability round failed");
                    let fatal = matches!(error, DebridError::Auth { .. });
                    on_event(WatchEvent::Outage(error));
                    if fatal {
                        return;
                    }
                }
            }
            let left = self.unknown_hashes(hashes);
            if left.is_empty() {
                return;
            }
            // any progress means the service is willing to talk, so start over at the
            // short wait. Only a round that got nowhere backs off
            if busy || left.len() < pending.len() {
                delay = WATCH_RETRY_MS;
            } else {
                delay = (delay * 2).min(WATCH_RETRY_MAX_MS);
            }
            tracing::debug!(
                target: "debrid",
                service = self.provider.config().id,
                unanswered = left.len(),
                retry_in_ms = delay,
                "asking again later"
            );
            platform.sleep(delay).await;
        }
    }

    /// Runs one probe. Only a reported state or a definite error counts as an answer;
    /// anything else errors, so the release stays re-checkable. `Ok(None)` means a probe
    /// of this hash is already in the air — the JS waited on that same promise, which is
    /// not expressible without keeping the future itself, and skipping is equivalent from
    /// the caller's side: the hash stays unknown and the next pass picks it up.
    async fn probe(&self, hash: &str) -> Result<Option<Availability>, DebridError> {
        if !self.in_flight.lock().unwrap().insert(hash.to_string()) {
            return Ok(None);
        }
        // released on Drop, not by code after the await: a dropped probe future used to
        // leave its hash in the set forever, after which it could never be badged again
        // and every resolve of it paid the full probe-handover wait
        let _claim = InFlightClaim { set: &self.in_flight, hash };
        let state = match self.provider.probe_availability(hash).await {
            Ok(state) => state,
            Err(error) => match error.proven_availability() {
                Some(state) => state,
                None => return Err(error),
            },
        };
        if state == Availability::Unknown {
            return Err(DebridError::Service {
                message: format!("{} gave no usable answer for {hash}", self.provider.config().title),
                status: None,
                code: None,
            });
        }
        self.client().remember(hash, state);
        Ok(Some(state))
    }
}

/// Resets the sweep flag when the sweep ends, however it ends — including the future
/// being dropped mid-flight.
struct SweepClaim<'a>(&'a AtomicBool);

impl Drop for SweepClaim<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// Takes a hash back out of the in-flight set when its probe ends, however it ends.
struct InFlightClaim<'a> {
    set: &'a Mutex<std::collections::HashSet<String>>,
    hash: &'a str,
}

impl Drop for InFlightClaim<'_> {
    fn drop(&mut self) {
        self.set.lock().unwrap().remove(self.hash);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{ManualClock, MockTransport, Route};

    const HASHES: [&str; 3] = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccccccccccccccccccccccc",
    ];

    /// A service that accepts the connection and never answers — which is not the same as
    /// one that is down, and is the shape that leaves a player waiting on nothing.
    struct Silent;

    #[async_trait::async_trait]
    impl HttpTransport for Silent {
        async fn execute(
            &self,
            _request: shiru_networking::HttpRequest,
        ) -> Result<shiru_networking::HttpResponse, shiru_networking::TransportError> {
            futures::future::pending().await
        }
    }

    fn torbox_with(routes: Vec<Route>) -> ManagedProvider {
        let transport = Arc::new(MockTransport::new(routes));
        let platform = Arc::new(ManualClock::new());
        ManagedProvider::new(create_provider("torbox", "key".into(), transport, platform).unwrap())
    }

    #[test]
    fn factory_knows_every_service_and_refuses_strangers() {
        let transport = Arc::new(MockTransport::new(vec![]));
        let platform = Arc::new(ManualClock::new());
        for id in ["torbox", "realdebrid", "alldebrid", "premiumize"] {
            let provider = create_provider(id, "k".into(), transport.clone(), platform.clone()).unwrap();
            assert_eq!(provider.config().id, id);
        }
        assert!(create_provider("nope", "k".into(), transport, platform).is_none());
    }

    #[tokio::test]
    async fn remembered_answers_come_back_without_a_request() {
        let managed = torbox_with(vec![Route::json(
            "checkcached",
            200,
            r#"{"success":true,"data":[{"hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"A"}]}"#,
        )]);
        let asked: Vec<String> = HASHES[..2].iter().map(|h| h.to_string()).collect();
        let first = managed.check_availability(&asked, |_, _| {}).await.unwrap();
        assert_eq!(first.get(HASHES[0]), Some(&Availability::Cached));
        // a cache endpoint that answered without mentioning a hash has said it does not hold it
        assert_eq!(first.get(HASHES[1]), Some(&Availability::Available));

        // second ask: everything recalled
        let second = managed.check_availability(&asked, |_, _| {}).await.unwrap();
        assert_eq!(second, first);
        assert!(managed.unknown_hashes(&asked).is_empty());
    }

    /// One line per event, so a whole watch can be asserted as a transcript.
    fn describe(event: &WatchEvent) -> String {
        match event {
            WatchEvent::Answer { hash, state, name } => format!(
                "answer {} {:?}{}",
                &hash[..4],
                state,
                name.as_deref().map(|name| format!(" ({name})")).unwrap_or_default()
            ),
            WatchEvent::Checking(active) => format!("checking {active}"),
            WatchEvent::Outage(error) => format!("outage {error}"),
        }
    }

    #[tokio::test]
    async fn a_watch_answers_from_memory_first_and_finishes_once_everything_is_answered() {
        let managed = torbox_with(vec![Route::json(
            "checkcached",
            200,
            r#"{"success":true,"data":[{"hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"Show B"}]}"#,
        )]);
        managed.client().remember(HASHES[0], Availability::Cached);
        let asked: Vec<String> = HASHES[..2].iter().map(|h| h.to_string()).collect();
        let mut events = Vec::new();
        managed.watch_availability(&asked, |event| events.push(describe(&event))).await;
        assert_eq!(
            events,
            [
                "answer aaaa Cached",
                "checking true",
                "answer bbbb Cached (Show B)",
                "checking false",
            ],
            "memory answers before any request, fresh answers as they land, then the watch ends"
        );
    }

    #[tokio::test]
    async fn a_watch_that_gets_nowhere_backs_off_and_a_bad_key_ends_it() {
        // a service that keeps failing: every round is an outage, and the wait between
        // rounds must grow — retrying a dead service every ten seconds forever is how the
        // old JS loop hammered a wedged API
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "checkcached",
            500,
            r#"{"success":false,"error":"SERVER_ERROR","detail":"the disk fell over"}"#,
        )]));
        let clock = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), transport.clone(), clock.clone()).unwrap(),
        );
        let asked = vec![HASHES[0].to_string()];
        let rounds = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        {
            let seen = rounds.clone();
            let recorder = clock.clone();
            let watch = managed.watch_availability(&asked, move |event| {
                if matches!(event, WatchEvent::Checking(true)) {
                    seen.borrow_mut().push(recorder.now_ms());
                }
            });
            futures::pin_mut!(watch);
            for _ in 0..400 {
                if rounds.borrow().len() >= 4 {
                    break;
                }
                assert!(futures::poll!(watch.as_mut()).is_pending(), "a failing service never satisfies the watch");
                tokio::task::yield_now().await;
            }
        }
        let rounds = rounds.borrow();
        assert_eq!(rounds.len(), 4, "the watch must keep asking");
        let deltas: Vec<u64> = rounds.windows(2).map(|pair| pair[1] - pair[0]).collect();
        assert!(deltas[0] >= 10_000, "the first retry waits the short delay, got {deltas:?}");
        assert!(deltas[1] >= 2 * deltas[0], "a round that got nowhere doubles the wait, got {deltas:?}");
        assert!(deltas[2] >= 2 * deltas[1], "and keeps doubling, got {deltas:?}");

        // auth is different: every retry would fail the same way, so the watch ends itself
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "checkcached",
            401,
            r#"{"success":false,"error":"BAD_TOKEN","detail":"nope"}"#,
        )]));
        let managed = ManagedProvider::new(
            create_provider("torbox", "bad".into(), transport.clone(), Arc::new(ManualClock::new())).unwrap(),
        );
        let mut events = Vec::new();
        managed.watch_availability(&asked, |event| events.push(describe(&event))).await;
        assert_eq!(events, ["checking true", "checking false", "outage Invalid TorBox API key"]);
        assert_eq!(transport.urls().len(), 1, "a bad key is not retried");
    }

    /// The wedge this pins: a Tauri command being cancelled (webview reload, window
    /// close) drops the check's future wherever it is. The sweep claim and the in-flight
    /// hashes are released by Drop guards now — before that, the flag stayed true
    /// forever, every later check returned memory-only answers with `busy: true`, and the
    /// UI retried on its shortest timer without the service ever being asked again.
    #[tokio::test]
    async fn a_dropped_sweep_releases_its_claim_and_its_hashes() {
        let transport = Arc::new(Silent);
        let platform = Arc::new(ManualClock::new());
        let managed =
            ManagedProvider::new(create_provider("realdebrid", "key".into(), transport, platform).unwrap());
        let asked = vec![HASHES[0].to_string()];
        {
            let sweep = managed.check_availability(&asked, |_, _| {});
            futures::pin_mut!(sweep);
            for _ in 0..20 {
                assert!(
                    futures::poll!(sweep.as_mut()).is_pending(),
                    "a silent service cannot have answered"
                );
                tokio::task::yield_now().await;
            }
            assert!(managed.sweeping(), "the sweep owns the account while it runs");
            assert!(
                managed.unknown_hashes(&asked).is_empty(),
                "the hash is in flight, so nothing should re-ask about it yet"
            );
        }
        assert!(!managed.sweeping(), "a dropped sweep must hand the account back");
        assert_eq!(
            managed.unknown_hashes(&asked).len(),
            1,
            "a dropped probe leaves its hash unknown and re-checkable, not stuck in flight"
        );
    }

    #[tokio::test]
    async fn unknown_hashes_reports_only_the_unasked() {
        let managed = torbox_with(vec![]);
        let asked: Vec<String> = HASHES.iter().map(|h| h.to_string()).collect();
        assert_eq!(managed.unknown_hashes(&asked).len(), 3);
        managed.client().remember(HASHES[0], Availability::Cached);
        assert_eq!(managed.unknown_hashes(&asked).len(), 2);
    }

    #[tokio::test]
    async fn batch_chunks_by_max_batch() {
        // 80 hashes with maxBatch 75 → two checkcached requests
        let managed = torbox_with(vec![Route::json("checkcached", 200, r#"{"success":true,"data":[]}"#)]);
        let asked: Vec<String> = (0..80).map(|n| format!("{n:040x}")).collect();
        let answers = managed.check_availability(&asked, |_, _| {}).await.unwrap();
        assert_eq!(answers.len(), 80);
        assert!(answers.values().all(|state| *state == Availability::Available));
    }

    /// Answers a cache check only once every chunk of the sweep has arrived together.
    /// Code that waits for one chunk before sending the next never gets that far and
    /// hangs, which the timeout below turns into a failure.
    struct ChunksMustOverlap {
        arrived: tokio::sync::Barrier,
    }

    #[async_trait::async_trait]
    impl HttpTransport for ChunksMustOverlap {
        async fn execute(
            &self,
            _request: shiru_networking::HttpRequest,
        ) -> Result<shiru_networking::HttpResponse, shiru_networking::TransportError> {
            self.arrived.wait().await;
            Ok(shiru_networking::HttpResponse {
                status: 200,
                headers: HashMap::new(),
                body: br#"{"success":true,"data":[]}"#.to_vec(),
            })
        }
    }

    #[tokio::test]
    async fn a_long_results_list_asks_about_its_hashes_together_rather_than_a_chunk_at_a_time() {
        // waiting out a round trip between chunks is what made a big list badge itself in
        // visible waves; the client's limiter is what decides how many actually travel
        let asked: Vec<String> = (0..200).map(|n| format!("{n:040x}")).collect();
        let transport = Arc::new(ChunksMustOverlap {
            // 200 hashes at TorBox's max_batch of 75 is three requests, which is also
            // exactly what its limiter lets overlap
            arrived: tokio::sync::Barrier::new(3),
        });
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), transport, Arc::new(ManualClock::new())).unwrap(),
        );
        let answers = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            managed.check_availability(&asked, |_, _| {}),
        )
        .await
        .expect("the chunks never overlapped, so the sweep is still waiting on the first one")
        .unwrap();
        assert_eq!(answers.len(), 200, "and every hash is still answered");
    }

    #[tokio::test]
    async fn a_chunk_that_fails_does_not_take_the_chunks_that_answered_with_it() {
        // 80 hashes at a max_batch of 75 is two chunks. The link drops for the chunk
        // holding the eightieth hash, and answers the one holding the first seventy five
        let managed = torbox_with(vec![
            Route::offline("000000000000000000000000000000000000004f"),
            Route::json("checkcached", 200, r#"{"success":true,"data":[]}"#),
        ]);
        let asked: Vec<String> = (0..80).map(|n| format!("{n:040x}")).collect();
        let failed = managed.check_availability(&asked, |_, _| {}).await;
        assert!(failed.is_err(), "the caller is told to come back, since not everything was asked");
        assert_eq!(
            managed.unknown_hashes(&asked).len(),
            5,
            "but the chunk that did answer is remembered rather than thrown away with the one that did not"
        );
    }

    #[tokio::test]
    async fn the_account_listing_is_read_once_per_ttl_and_feeds_the_memory() {
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "torrents/mylist",
            200,
            &format!(
                r#"{{"success":true,"data":[{{"hash":"{}","name":"A pack","download_finished":true,"download_present":true}}]}}"#,
                HASHES[0]
            ),
        )]));
        let platform = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), transport.clone(), platform.clone()).unwrap(),
        );

        let first = managed.list_availability().await.unwrap();
        assert_eq!(first.get(HASHES[0]), Some(&Availability::Cached));
        // what the account holds is remembered, so the badge check asks about nothing
        assert!(!managed.unknown_hashes(&[HASHES[0].to_string()]).contains(&HASHES[0].to_string()));

        managed.list_availability().await.unwrap();
        assert_eq!(transport.urls().len(), 1, "a second read inside the TTL costs no request");

        platform.advance(61_000);
        managed.list_availability().await.unwrap();
        assert_eq!(transport.urls().len(), 2, "and one after it does");

        managed.forget_listing().await;
        managed.list_availability().await.unwrap();
        assert_eq!(transport.urls().len(), 3, "an account that just changed is read again");
    }

    #[tokio::test]
    async fn a_failed_listing_is_never_remembered() {
        let transport = Arc::new(MockTransport::new(vec![Route::json("torrents/mylist", 500, "{}")]));
        let platform = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), transport.clone(), platform).unwrap(),
        );
        assert!(managed.list_availability().await.is_err());
        assert!(managed.list_availability().await.is_err());
        assert_eq!(transport.urls().len(), 2, "the next caller asks again rather than reusing a failure");
    }

    // giving up on a check has to be temporary: a bad minute must not cost the whole
    // results list until the user changes the sort order
    #[tokio::test]
    async fn a_link_that_answers_nothing_badges_nothing_and_leaves_everything_askable() {
        let transport = Arc::new(MockTransport::new(vec![Route::offline("checkcached")]));
        let platform = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), transport.clone(), platform).unwrap(),
        );
        let asked: Vec<String> = HASHES.iter().map(|h| h.to_string()).collect();

        let failed = managed.check_availability(&asked, |_, _| {}).await;
        assert!(matches!(failed, Err(DebridError::Network { .. })));
        assert_eq!(
            managed.unknown_hashes(&asked).len(),
            3,
            "a release the link could not be asked about is unanswered, never 'not cached'"
        );

        // the retry the UI schedules, once the link is back
        transport.rescript(vec![Route::json(
            "checkcached",
            200,
            &format!(r#"{{"success":true,"data":[{{"hash":"{}","name":"A"}}]}}"#, HASHES[0]),
        )]);
        let answers = managed.check_availability(&asked, |_, _| {}).await.unwrap();
        assert_eq!(answers.len(), 3, "the same list answers in full on a later attempt");
        assert_eq!(answers.get(HASHES[0]), Some(&Availability::Cached));
        assert!(managed.unknown_hashes(&asked).is_empty());
    }

    #[tokio::test]
    async fn a_timeout_says_nothing_about_a_release_so_it_stays_re_checkable() {
        let transport = Arc::new(MockTransport::new(vec![Route::timeout("checkcached", 30_000)]));
        let platform = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), transport, platform).unwrap(),
        );
        let asked: Vec<String> = HASHES[..1].iter().map(|h| h.to_string()).collect();
        let failed = managed.check_availability(&asked, |_, _| {}).await;
        assert!(matches!(failed, Err(DebridError::Timeout { .. })));
        assert_eq!(managed.unknown_hashes(&asked).len(), 1);
    }

    #[tokio::test]
    async fn what_a_check_owes_the_account_is_cleared_before_it_adds_anything() {
        // a probe that dropped mid-flight left a removal outstanding
        let transport = Arc::new(MockTransport::new(vec![Route::offline("delete")]));
        let platform = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("realdebrid", "key".into(), transport.clone(), platform).unwrap(),
        );
        managed
            .client()
            .release(
                &crate::PlainDialect,
                "https://api.real-debrid.com/rest/1.0/torrents/delete/abc",
                crate::RequestOpts { method: Some(shiru_networking::Method::Delete), ..Default::default() },
            )
            .await;
        assert_eq!(managed.client().orphaned(), 1);

        transport.rescript(vec![
            Route::json("torrents/delete", 200, "{}"),
            Route::offline("torrents"), // the check itself still cannot get through
        ]);
        let _ = managed.check_availability(&[HASHES[0].to_string()], |_, _| {}).await;
        assert_eq!(managed.client().orphaned(), 0, "the leftover is taken off the account first");
    }

    #[tokio::test]
    async fn an_auth_failure_stops_a_sweep_loudly() {
        let transport = Arc::new(MockTransport::new(vec![Route::json(
            "torrents",
            401,
            r#"{"error_code":8,"error":"bad_token"}"#,
        )]));
        let platform = Arc::new(ManualClock::new());
        let managed = ManagedProvider::new(
            create_provider("realdebrid", "key".into(), transport, platform).unwrap(),
        );
        let asked: Vec<String> = HASHES.iter().map(|h| h.to_string()).collect();
        let result = managed.check_availability(&asked, |_, _| {}).await;
        assert!(matches!(result, Err(DebridError::Auth { .. })));
    }

    #[tokio::test]
    async fn a_service_that_never_answers_ends_as_a_message_rather_than_a_wait() {
        // the black screen this was written for: play a release, the service accepts every
        // request and answers none, and nothing anywhere says so
        let managed = ManagedProvider::new(
            create_provider("torbox", "key".into(), Arc::new(Silent), Arc::new(ManualClock::new())).unwrap(),
        );
        let error = managed
            .resolve("magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &Default::default())
            .await
            .expect_err("a service that says nothing cannot have resolved anything");
        assert!(matches!(error, DebridError::Timeout { .. }), "got {error:?}");
        let message = error.to_string();
        assert!(message.contains("TorBox"), "the message names who went quiet: {message}");
        assert!(message.contains("60s"), "and how long it was given: {message}");
    }

    #[tokio::test]
    async fn a_service_that_answers_is_left_alone() {
        let managed = torbox_with(vec![
            Route::json("torrents/mylist", 200, r#"{"success":true,"data":[]}"#),
            Route::json("torrents/createtorrent", 200, r#"{"success":false,"error":"DATABASE_ERROR"}"#),
        ]);
        let error = managed
            .resolve("magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &Default::default())
            .await
            .expect_err("the script refuses the add");
        assert!(!matches!(error, DebridError::Timeout { .. }), "the service answered, so this is its answer: {error:?}");
    }
}
