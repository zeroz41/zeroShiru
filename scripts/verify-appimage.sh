#!/usr/bin/env bash
# Can the AppImage that was just built actually play video?
#
# This AppImage has now shipped broken twice, for two different reasons, with the
# same symptom: WebKit plays everything through GStreamer, and a build where the
# element lookup comes up empty does not degrade -- it freezes the player and takes
# the web process down on the first video. Both breaks were invisible until a human
# pressed play. This script is the machine pressing play at build time.
#
#   1. The gtk deployer copied the GStreamer core libraries (WebKit links them) and
#      none of the plugins (loaded by name at runtime): a core that finds nothing.
#   2. With the core deleted, the stock AppImage runtime (AppRun.wrapped) still
#      exported GST_PLUGIN_SYSTEM_PATH_1_0=$APPDIR/usr/lib/gstreamer-1.0:$old --
#      and that variable REPLACES GStreamer's built-in scan of the host plugin
#      directory. The directory does not exist in the AppDir, $old is empty, so the
#      host's plugins vanished just as thoroughly.
#
# The check: extract the AppImage, reconstruct the exact environment a launch gets
# (every apprun hook, plus the variables AppRun.wrapped hardcodes), and demand that
# the elements WebKit refuses to play without can be found in it. Runs after every
# bundle; a failure fails the build.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"

appimage="$(ls -t "$root"/target/release/bundle/appimage/*.AppImage 2> /dev/null | head -1)"
if [ -z "$appimage" ]; then
    echo "verify-appimage: no AppImage under target/release/bundle/appimage" >&2
    exit 1
fi

if ! command -v gst-inspect-1.0 > /dev/null; then
    echo "verify-appimage: WARNING: gst-inspect-1.0 not on this machine; the media" >&2
    echo "verify-appimage: pipeline of $appimage is UNVERIFIED. Install gstreamer" >&2
    echo "verify-appimage: (the app cannot play video without it anyway)." >&2
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT INT TERM

(cd "$workdir" && "$appimage" --appimage-extract > /dev/null)
appdir="$workdir/squashfs-root"

# Break #1: a bundled GStreamer core with no bundled plugins finds nothing, and it
# does not merely fail -- its empty registry, keyed only by $HOME, poisons every
# other GStreamer program on the machine. Either ship the pair or ship neither.
core="$(find "$appdir/usr" -maxdepth 2 -name 'libgstreamer-1.0.so*' -print -quit 2> /dev/null)"
plugins="$(find "$appdir/usr" -maxdepth 3 -path '*gstreamer-1.0/libgst*' -print -quit 2> /dev/null)"
if [ -n "$core" ] && [ -z "$plugins" ]; then
    echo "verify-appimage: FAIL: $core is bundled but no plugins are." >&2
    echo "verify-appimage: A GStreamer core without plugins cannot find appsink; the player freezes." >&2
    exit 1
fi

# Break #2 and anything like it: stand where a launched app stands. Hooks first,
# then the variables AppRun.wrapped exports over them (prior value appended, which
# is the seam the hooks use to keep the host plugin directories reachable).
elements="appsink autoaudiosink playbin3 matroskademux"
missing="$(
    cd "$appdir" || exit 1
    export APPDIR="$appdir"
    for hook in apprun-hooks/*.sh; do
        [ -f "$hook" ] && . "./$hook"
    done
    export LD_LIBRARY_PATH="$appdir/usr/lib/:$appdir/usr/lib/i386-linux-gnu/:$appdir/usr/lib/x86_64-linux-gnu/:$appdir/usr/lib32/:$appdir/usr/lib64/:$appdir/lib/:$appdir/lib/i386-linux-gnu/:$appdir/lib/x86_64-linux-gnu/:$appdir/lib32/:$appdir/lib64/:$LD_LIBRARY_PATH"
    # Reproduce what THIS artifact's AppRun really does, not what we wish it did: the
    # stock binary overwrites the GST plugin path with an AppDir directory and an
    # EMPTY tail (bundle.sh renames those template strings away; an unpatched AppRun
    # must fail here the way it fails a user).
    if strings "$appdir/AppRun.wrapped" 2> /dev/null | grep -q 'GST_PLUGIN_SYSTEM_PATH_1_0=%s'; then
        export GST_PLUGIN_SYSTEM_PATH="$appdir/usr/lib/gstreamer:"
        export GST_PLUGIN_SYSTEM_PATH_1_0="$appdir/usr/lib/gstreamer-1.0:"
    fi
    # hermetic: this probe must never read or write anyone's real registry
    export GST_REGISTRY_1_0="$workdir/registry.bin"
    export GST_REGISTRY="$GST_REGISTRY_1_0"
    for element in $elements; do
        gst-inspect-1.0 "$element" > /dev/null 2>&1 || printf '%s ' "$element"
    done
)"

if [ -n "$missing" ]; then
    echo "verify-appimage: FAIL: in the AppImage's launch environment these GStreamer" >&2
    echo "verify-appimage: elements cannot be found: $missing" >&2
    echo "verify-appimage: WebKit will freeze on the first video. Most likely a bundling" >&2
    echo "verify-appimage: change re-broke plugin discovery -- see scripts/bundle.sh." >&2
    exit 1
fi

echo "verify-appimage: OK: $(basename "$appimage") resolves $elements"
