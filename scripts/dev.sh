#!/usr/bin/env sh
# Desktop dev: the Vite dev server and the Tauri window, together.
#
# Deliberately a shell script rather than a dependency — the package that used to
# do this pulled in 12MB of reactive-streams library to run two commands.
set -e
cd "$(dirname "$0")/../frontend"

# bun and cargo are often installed without touching the shell PATH
PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
export PATH

bun x --bun vite common &
VITE=$!
# whatever ends the window ends the dev server with it, including Ctrl-C
trap 'kill $VITE 2>/dev/null || true' EXIT INT TERM

cargo run -p shiru-tauri
