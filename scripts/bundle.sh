#!/usr/bin/env sh
# Installer bundling: build the frontend, then run Tauri's bundlers.
#
# The same two steps BUILDING.md spells out, plus two workarounds for
# linuxdeploy, the tool Tauri shells out to for the AppImage. It is old enough
# to choke on a current Linux userland. Both are skipped off Linux.
set -e
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$scripts_dir/../frontend"

# bun and cargo are often installed without touching the shell PATH
PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
export PATH

bun x --bun vite build common

if [ "$(uname -s)" = Linux ]; then
    # linuxdeploy strips with the binutils bundled inside its own AppImage,
    # which predates DT_RELR and so rejects every library a current toolchain
    # produces: "unknown type [0x13] section `.relr.dyn'". A fatter AppImage
    # beats no AppImage.
    NO_STRIP=true
    export NO_STRIP

    # linuxdeploy-plugin-gtk finds libgobject/libgdk_pixbuf/libpango with an
    # unbounded `find` over the pkg-config libdir, so a vendored copy parked in
    # a subdirectory of /usr/lib -- VMware ships one linked against libffi.so.6
    # -- shadows the real one and then fails to deploy. Those libraries only
    # ever live in libdir itself, so bound the search to it. Tauri downloads
    # the plugin once and reuses it, which is why patching it in place sticks.
    gtk_plugin="${XDG_CACHE_HOME:-$HOME/.cache}/tauri/linuxdeploy-plugin-gtk.sh"
    if [ ! -f "$gtk_plugin" ]; then
        # Not fetched yet. Fetch it ourselves, from the URL Tauri would use, so
        # the patch below lands before the first bundle rather than after it.
        gtk_plugin_url=https://raw.githubusercontent.com/tauri-apps/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh
        mkdir -p "$(dirname "$gtk_plugin")"
        if command -v curl > /dev/null; then
            curl -fsSL "$gtk_plugin_url" -o "$gtk_plugin" && chmod +x "$gtk_plugin"
        elif command -v wget > /dev/null; then
            wget -qO "$gtk_plugin" "$gtk_plugin_url" && chmod +x "$gtk_plugin"
        else
            echo "$0: no curl or wget; leaving linuxdeploy-plugin-gtk to Tauri." >&2
            echo "$0: if the AppImage fails to bundle, re-run this script." >&2
        fi
    fi
    # Each patch is a no-op once applied: the matched line no longer exists.
    if [ -f "$gtk_plugin" ]; then
        sed -i 's|find "$directory" \\( -type l|find "$directory" -maxdepth 1 \\( -type l|' "$gtk_plugin"

        # The plugin's AppRun hook forces every launch onto XWayland, a workaround
        # for a real crash that was never the backend's fault: the plugin bundles
        # libwayland-client, and a copy older than the host's EGL stack dies in
        # wl_proxy_* the moment GTK opens a Wayland display. Fix the cause instead:
        # never bundle libwayland (every distro that ships GTK3 ships it, and the
        # host copy always matches the host EGL), and let GDK pick its backend the
        # way it does outside an AppImage -- Wayland on Wayland, X11 elsewhere --
        # while still honouring a GDK_BACKEND the user set themselves.
        sed -i 's|^export GDK_BACKEND=x11.*|export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"|' "$gtk_plugin"
        if ! grep -q 'libwayland-\*' "$gtk_plugin"; then
            printf '\n%s\n%s\n' \
                '# a bundled libwayland is the crash the x11 forcing used to paper over' \
                'find "$APPDIR"/usr/lib* -maxdepth 1 -name '"'"'libwayland-*'"'"' -delete' \
                >> "$gtk_plugin"
        fi

        # GStreamer, which is how the webview plays anything at all. The plugin deployer
        # copies the core libraries because WebKit links against them, and copies none of
        # the ~275 plugins, because nothing links against those -- they are loaded by name
        # at runtime. A GStreamer with no plugins is not a degraded GStreamer: it cannot
        # find `appsink` or `autoaudiosink`, so the webview builds no pipeline, hands a
        # null element to a signal connection, and takes the whole web process down.
        #
        # And it does not keep that to itself. The registry is a cache keyed by nothing but
        # the user's home directory, so the empty result gets written over the one every
        # other GStreamer program on the machine reads -- including this app installed
        # properly, which then stops playing video too, long after the AppImage is gone.
        #
        # So: do not bundle the core without the plugins. The host has both, as a matched
        # pair, or it could not have run a GTK app in the first place. And write the
        # registry somewhere of our own regardless, so a bundled anything can never again
        # cost someone the rest of their system.
        if ! grep -q 'libgst\*' "$gtk_plugin"; then
            printf '\n%s\n%s\n' \
                '# core without plugins is worse than no bundle at all; the host has the pair' \
                'find "$APPDIR"/usr/lib* -maxdepth 1 -name '"'"'libgst*'"'"' -delete' \
                >> "$gtk_plugin"
        fi
        if ! grep -q 'GST_REGISTRY_1_0' "$gtk_plugin"; then
            hook_line='cat >> "$HOOKFILE" <<'"'"'GSTEOF'"'"''
            printf '\n%s\n%s\n%s\n%s\n%s\n%s\n' \
                '# never write the registry every other GStreamer program on the box reads' \
                "$hook_line" \
                'export GST_REGISTRY_1_0="${XDG_CACHE_HOME:-$HOME/.cache}/zeroshiru/gstreamer-registry.bin"' \
                'export GST_REGISTRY="$GST_REGISTRY_1_0"' \
                'mkdir -p "$(dirname "$GST_REGISTRY_1_0")" 2> /dev/null || true' \
                'GSTEOF' \
                >> "$gtk_plugin"
        fi

    fi

    # Deleting the bundled core was necessary but not sufficient. The stock type-2
    # AppRun binary Tauri wraps around the app exports
    # GST_PLUGIN_SYSTEM_PATH_1_0=$APPDIR/usr/lib/gstreamer-1.0: -- and setting that
    # variable REPLACES GStreamer's built-in scan of the host plugin directory. The
    # AppDir has no plugins and AppRun writes the tail EMPTY (its getenv list covers
    # LD_LIBRARY_PATH and friends, not the GST pair -- verified from a live process
    # env, which is also why pre-seeding the variable from a hook cannot win). So the
    # host's plugins vanish, WebKit finds no appsink, and the first video freezes the
    # player and takes the web process down.
    #
    # The fix is to make AppRun never say the words: rename both template strings in
    # the binary, same length, so its putenv sets a variable nothing reads. With the
    # variable untouched, the host's libgstreamer scans its own default plugin
    # directory -- correct on every distro, exotic prefixes included.
    apprun="${XDG_CACHE_HOME:-$HOME/.cache}/tauri/AppRun-x86_64"
    if [ ! -f "$apprun" ]; then
        # Not fetched yet: fetch it from the URL Tauri would use, so the patch lands
        # before the first bundle rather than failing verify-appimage once.
        apprun_url=https://github.com/AppImage/AppImageKit/releases/download/continuous/AppRun-x86_64
        mkdir -p "$(dirname "$apprun")"
        if command -v curl > /dev/null; then
            curl -fsSL "$apprun_url" -o "$apprun" && chmod +x "$apprun"
        elif command -v wget > /dev/null; then
            wget -qO "$apprun" "$apprun_url" && chmod +x "$apprun"
        fi
    fi
    if [ -f "$apprun" ]; then
        LC_ALL=C sed -i 's/GST_PLUGIN_SYSTEM_PATH/ZST_PLUGIN_SYSTEM_PATH/g' "$apprun"
    fi
fi

cd ../hosts/tauri
cargo tauri build "$@"

# A bundle that cannot play video is not a bundle. The verifier reconstructs the
# AppImage's launch environment and demands the GStreamer elements WebKit needs;
# both ways this has shipped broken would have been caught by it.
if [ "$(uname -s)" = Linux ]; then
    "$scripts_dir/verify-appimage.sh"
fi
