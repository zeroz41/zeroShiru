# zeroShiru Linux patch

This directory vendors `media_kit_video` 2.0.1 under its MIT license so the
Linux texture path can be kept reproducible.

The upstream implementation reads `eglGetCurrentDisplay` and
`eglGetCurrentContext` while handling a Flutter platform-channel call. Flutter
does not guarantee that its renderer context is current on that thread, so a
healthy GPU can be mistaken for an unavailable one and video falls back to the
software pixel-buffer texture.

zeroShiru creates a temporary OpenGL ES context from the realized GTK
`FlView` window when no context is current. GDK chooses the application's
native display and driver, the existing plugin creates its isolated mpv EGL
context, and the temporary context is released. No driver name, GPU vendor, or
session environment override is used.

## Known Linux shutdown issue (unresolved)

On the current NVIDIA 610.43.03 system, the hardware path initializes
successfully (`H/W rendering with isolated EGL context`), but closing the app
after `Ctrl-C` can still end in `SIGSEGV`. Captured cores place the main thread
inside `libnvidia-eglcore.so` / `libEGL_nvidia.so` during libc process-exit
cleanup. The shutdown output also includes Flutter 3.47 attempting to remove
its implicit Linux view:

```text
FlutterEngineRemoveView returned kInvalidArguments
The implicit view cannot be removed.
```

Resource-ordering changes, deferred libmpv shutdown, lazy texture-context
initialization, and an engine-aware application exit were tested on
2026-08-24 and did not eliminate the crash; those experiments were reverted.
Do not reapply them without a smaller reproduction. A minimal Flutter Linux
app exited on `SIGINT` without producing a core, so the remaining interaction
is specific to zeroShiru's plugin/window shutdown path. The startup ATK and
blank cursor-theme messages are separate Flutter/GTK warnings and are not
evidence of software rendering.

Separately, this machine's `/usr/bin/flutter` installation had a stale
`flutter_tools.snapshot` (`Wrong full snapshot version`). The working SDK used
for builds was `/home/td/flutter/bin/flutter`; updating/reinstalling the system
Flutter package is an environment repair, not a repository change.
