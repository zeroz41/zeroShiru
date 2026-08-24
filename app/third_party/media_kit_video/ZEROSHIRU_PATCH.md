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
