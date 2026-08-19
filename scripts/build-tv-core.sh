#!/usr/bin/env bash
# Builds the shared Rust core for the TV hosts: wasm32 + wasm-bindgen web glue.
# Baseline WebAssembly only (no SIMD/threads) — migration report section 55.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build -p shiru-wasm-bridge --target wasm32-unknown-unknown --release
mkdir -p dist/tv-core
wasm-bindgen target/wasm32-unknown-unknown/release/shiru_wasm_bridge.wasm \
  --target web --out-dir dist/tv-core --out-name shiru-core
echo "TV core: $(du -h dist/tv-core/shiru-core_bg.wasm | cut -f1) -> dist/tv-core/"
