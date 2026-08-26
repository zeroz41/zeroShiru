# zeroShiru media_kit patch

This directory vendors `media_kit` 1.2.6 under its MIT license. Native player
shutdown clears libmpv's wakeup callback, synchronously terminates and joins
the mpv core, and only then closes the Dart `NativeCallable`. This removes the
upstream five-second deferred destroy and its callback race. Platforms that
must use the isolate initializer retain upstream's deferred teardown.
