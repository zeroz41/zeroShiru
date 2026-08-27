# Zero media_kit patch

This directory vendors `media_kit` 1.2.6 under its MIT license. Native player
shutdown clears libmpv's wakeup callback, terminates and joins the mpv core,
and only then closes the Dart `NativeCallable`. This removes the upstream
five-second deferred destroy and its callback race. Platforms that must use
the isolate initializer retain upstream's deferred teardown.

Upstream status (checked 2026-08-27): media_kit 1.2.6 is still the latest
release and its dispose path is unchanged (the one rework attempt, PR #1350,
was reverted the next day). Upstream's unreleased hot-restart fix for
media-kit/media-kit#1314 independently adopted the same wakeup-clearing
technique.

## Bounded teardown

`mpv_terminate_destroy` joins every mpv thread, so a demuxer parked in a dead
network read (a stalled debrid HTTPS stream) used to freeze the UI isolate —
and with it the window teardown that awaits `Player.dispose()`, leaving a
hidden window with a live process.

Dispose therefore now:

- bounds each awaited stage (initialization completers, `stop`, platform
  teardown) with a 5-second timeout, so a completer that was never completed
  cannot block shutdown;
- joins the core in a helper isolate (`compute`) with a 10-second limit. The
  wakeup callback is cleared before the join starts, so the core cannot call
  back into Dart while terminating. On timeout the handle and `NativeCallable`
  are deliberately leaked: the process is exiting and any further wait would
  block that exit.

The event pump (`InitializerNativeCallable._callback`) re-checks that its
handle is still registered before every `mpv_wait_event`: the loop suspends
while an event handler runs, dispose can execute during that suspension, and
the handle must not be waited on once the core may be terminating on another
thread.

The application (`lib/main.dart`) additionally wraps the whole service
teardown in a 15-second timeout before destroying its window.
