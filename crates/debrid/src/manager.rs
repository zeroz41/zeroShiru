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
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Consecutive unanswered probes before a sweep gives up.
const MAX_PROBE_FAILURES: usize = 3;
/// Probes running at once. Small, since each briefly owns a torrent on the account.
const MAX_PROBE_CONCURRENCY: usize = 3;

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

/// Wraps a provider with the shared availability bookkeeping.
pub struct ManagedProvider {
    provider: Arc<dyn DebridProvider>,
    /// Whether a check that adds magnets is running, since only one may be.
    sweeping: AtomicBool,
    /// Hashes being probed right now. The JS shares the pending promise; here a
    /// second asker simply skips the hash — it stays unknown and re-checkable.
    in_flight: Mutex<std::collections::HashSet<String>>,
}

impl ManagedProvider {
    pub fn new(provider: Arc<dyn DebridProvider>) -> Self {
        ManagedProvider { provider, sweeping: AtomicBool::new(false), in_flight: Mutex::new(Default::default()) }
    }

    pub fn provider(&self) -> &Arc<dyn DebridProvider> {
        &self.provider
    }

    fn client(&self) -> &DebridClient {
        self.provider.client()
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
        // harder than reading, so overlapping checks do not answer faster, they get refused
        let guarded = config.check_adds_magnets;
        if guarded && self.sweeping.swap(true, Ordering::SeqCst) {
            return Ok(answers);
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
        if guarded {
            self.sweeping.store(false, Ordering::SeqCst);
        }
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
        for chunk in hashes.chunks(max_batch) {
            let states = self.provider.check_availability_batch(chunk).await?;
            for hash in chunk {
                let state = states.get(hash).copied().unwrap_or(Availability::Unknown);
                self.client().remember(hash, state);
                if state != Availability::Unknown {
                    answer(hash, state);
                }
            }
        }
        Ok(())
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
        let queue = Mutex::new(hashes.to_vec());
        let answered = Mutex::new(Vec::<(String, Availability)>::new());
        let failures = Mutex::new(0usize);
        let stopped = Mutex::new(Option::<DebridError>::None);

        let worker = || async {
            loop {
                if stopped.lock().unwrap().is_some() {
                    return;
                }
                let Some(hash) = ({ let mut q = queue.lock().unwrap(); if q.is_empty() { None } else { Some(q.remove(0)) } }) else {
                    return;
                };
                match self.probe(&hash).await {
                    Ok(state) => {
                        answered.lock().unwrap().push((hash, state));
                        *failures.lock().unwrap() = 0;
                    }
                    Err(error) => {
                        let auth = matches!(error, DebridError::Auth { .. });
                        let throttled = error.throttled();
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

        let workers = hashes.len().min(MAX_PROBE_CONCURRENCY).max(1);
        futures::future::join_all((0..workers).map(|_| worker())).await;

        for (hash, state) in answered.into_inner().unwrap() {
            answer(&hash, state);
        }
        match stopped.into_inner().unwrap() {
            Some(error @ DebridError::Auth { .. }) => Err(error),
            _ => Ok(()),
        }
    }

    /// Runs one probe. Only a reported state or a definite error counts as an answer;
    /// anything else errors, so the release stays re-checkable.
    async fn probe(&self, hash: &str) -> Result<Availability, DebridError> {
        {
            let mut in_flight = self.in_flight.lock().unwrap();
            if !in_flight.insert(hash.to_string()) {
                return Err(DebridError::Service {
                    message: format!("a probe for {hash} is already running"),
                    status: None,
                    code: None,
                });
            }
        }
        let outcome = async {
            let state = match self.provider.probe_availability(hash).await {
                Ok(state) => state,
                Err(error) => error.proven_availability().ok_or(error)?,
            };
            if state == Availability::Unknown {
                return Err(DebridError::Service {
                    message: format!("{} gave no usable answer for {hash}", self.provider.config().title),
                    status: None,
                    code: None,
                });
            }
            self.client().remember(hash, state);
            Ok(state)
        }
        .await;
        self.in_flight.lock().unwrap().remove(hash);
        outcome
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
}
