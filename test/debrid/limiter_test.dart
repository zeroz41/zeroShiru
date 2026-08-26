import 'package:flutter_test/flutter_test.dart' hide pumpEventQueue;
import 'package:zero/infrastructure/debrid/errors.dart';
import 'package:zero/infrastructure/debrid/limiter.dart';

import 'testing.dart';

Limiter limiter(int maxConcurrent, int minTimeMs, [(int, int)? reservoir]) =>
    Limiter(
      Limits(
        maxConcurrent: maxConcurrent,
        minTimeMs: minTimeMs,
        reservoir: reservoir,
      ),
    );

void main() {
  test('requests go out no closer together than the service allows', () async {
    final clock = ManualClock();
    final paced = limiter(4, 200);
    final start = clock.nowMs;
    for (var i = 0; i < 5; i++) {
      final permit = await paced.acquire(clock);
      permit.release();
    }
    // four gaps of 200ms between five starts
    expect(clock.nowMs - start, 800);
  });

  test('only so many may be in flight at once', () async {
    final clock = ManualClock();
    final paced = limiter(2, 0);
    final first = await paced.acquire(clock);
    final second = await paced.acquire(clock);
    expect(paced.snapshot(clock).inFlight, 2);
    // a third has to wait for one of them to finish
    var thirdHeld = false;
    final third = paced.acquire(clock).then((permit) {
      thirdHeld = true;
      return permit;
    });
    await pumpEventQueue(5);
    expect(thirdHeld, isFalse, reason: 'the pipe is full');
    first.release();
    final permit = await third;
    expect(thirdHeld, isTrue);
    permit.release();
    second.release();
  });

  test('a request that failed still gives its slot back', () async {
    // otherwise a run of errors wedges the limiter and nothing goes out again
    final clock = ManualClock();
    final paced = limiter(1, 0);
    for (var i = 0; i < 10; i++) {
      final permit = await paced.acquire(clock);
      permit.release();
    }
    expect(paced.snapshot(clock).inFlight, 0);
  });

  test('an allowance is spent and refilled on its own window', () async {
    final clock = ManualClock();
    final paced = limiter(4, 0, (3, 60000));
    final start = clock.nowMs;
    for (var i = 0; i < 3; i++) {
      (await paced.acquire(clock)).release();
    }
    expect(
      clock.nowMs,
      start,
      reason: 'the allowance is not a delay while it lasts',
    );
    (await paced.acquire(clock)).release();
    expect(
      clock.nowMs - start,
      greaterThanOrEqualTo(60000),
      reason: 'the fourth waits for the window to reopen',
    );
  });

  test(
    'a pause the service asked for stops everything on the account',
    () async {
      // the shape this exists for: a 429 with retry-after
      final clock = ManualClock();
      final paced = limiter(4, 0);
      paced.pauseFor(clock, 5000);
      expect(paced.paused(clock), isTrue);
      final start = clock.nowMs;
      (await paced.acquire(clock)).release();
      expect(clock.nowMs - start, greaterThanOrEqualTo(5000));
      expect(paced.paused(clock), isFalse);
    },
  );

  test('whoever asked first goes first', () async {
    // providers put the file the user asked for at the head of a pack's link
    // requests. A limiter that reorders quietly throws that guarantee away
    final clock = ManualClock();
    final paced = limiter(1, 0);
    final order = <int>[];
    final waiters = <Future<void>>[];
    for (var index = 0; index < 5; index++) {
      final mine = index;
      waiters.add(() async {
        final permit = await paced.acquire(clock);
        order.add(mine);
        // held across a yield, so the next one really has to wait its turn
        await clock.sleep(const Duration(milliseconds: 1));
        permit.release();
      }());
    }
    await Future.wait(waiters);
    expect(order, [0, 1, 2, 3, 4]);
  });

  test(
    'a caller that walked away mid-wait does not hold the queue up',
    () async {
      // a resolve that hit its overall budget cancels its request mid-wait
      final clock = ManualClock();
      final paced = limiter(1, 0);
      final held = await paced.acquire(clock);
      final cancel = CancelToken();
      final abandoned = paced.acquire(clock, cancel: cancel);
      await pumpEventQueue(3); // it takes a ticket and starts waiting
      cancel.cancel();
      await expectLater(abandoned, throwsA(isA<CancelledException>()));
      held.release();
      expect(
        paced.snapshot(clock).waiting,
        0,
        reason: 'no ghost at the front of the queue',
      );
      // and the next request really does go out rather than waiting behind it
      final next = await paced.acquire(clock);
      next.release();
    },
  );

  test('a longer pause wins over one already running', () async {
    final clock = ManualClock();
    final paced = limiter(4, 0);
    paced.pauseFor(clock, 10000);
    paced.pauseFor(clock, 1000);
    final start = clock.nowMs;
    (await paced.acquire(clock)).release();
    expect(
      clock.nowMs - start,
      greaterThanOrEqualTo(10000),
      reason: 'the shorter one must not cut it short',
    );
  });
}
