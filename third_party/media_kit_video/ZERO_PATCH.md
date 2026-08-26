# Zero Linux patch

This directory vendors `media_kit_video` 2.0.1 under its MIT license so the
Linux texture path can be kept reproducible.

The upstream implementation reads `eglGetCurrentDisplay` and
`eglGetCurrentContext` while handling a Flutter platform-channel call. Flutter
does not guarantee that its renderer context is current on that thread, so a
healthy GPU can be mistaken for an unavailable one and video falls back to the
software pixel-buffer texture.

Zero creates a temporary OpenGL ES context from the realized GTK
`FlView` window when no context is current. GDK chooses the application's
native display and driver, the existing plugin creates its isolated mpv EGL
context, and the temporary context is released. No driver name, GPU vendor, or
session environment override is used.

The Linux texture callback also passes
`MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME=0`. Flutter invokes that callback on
its raster thread, so libmpv must return the rendered texture immediately
instead of holding the UI compositor until the media presentation time. This
matches current upstream source while remaining unreleased in 2.0.1.

## Linux shutdown ownership

The texture used to outlive its isolated EGL context, so its EGLImage, FBO and
OpenGL texture could not be released. When no Flutter context was current, the
isolated context also remained current while `eglDestroyContext` was called;
EGL therefore deferred the destruction until process exit.

Shutdown now unregisters the Flutter texture, releases all texture-owned GPU
objects, frees the mpv render context, explicitly unbinds the isolated EGL
context, and only then destroys it. The application awaits this teardown before
destroying its window. The accompanying `media_kit` patch synchronously joins
the in-process mpv core, so no child renderer or delayed GPU owner remains.
