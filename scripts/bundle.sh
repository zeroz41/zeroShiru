#!/usr/bin/env sh
# Installer bundling: build the frontend, then run Tauri's bundlers.
#
# The same two steps BUILDING.md spells out, plus two workarounds for
# linuxdeploy, the tool Tauri shells out to for the AppImage. It is old enough
# to choke on a current Linux userland. Both are skipped off Linux.
set -e
cd "$(dirname "$0")/../frontend"

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
    # No-op once applied: the patched line no longer matches.
    if [ -f "$gtk_plugin" ]; then
        sed -i 's|find "$directory" \\( -type l|find "$directory" -maxdepth 1 \\( -type l|' "$gtk_plugin"
    fi
fi

cd ../hosts/tauri
exec cargo tauri build "$@"
