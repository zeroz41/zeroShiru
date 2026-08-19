# Tizen host (migration phases 15-16)

Planning baseline: Tizen 5.5+ (guaranteed WASM), standard browser WebAssembly
only — no Samsung C/C++ WASM extensions, no SIMD/threads (report sections 23, 55).

Assembly (once `scripts/build-tv-core.sh` has run):

    frontend  <- electron/build (the Vite renderer output)
    wasm      <- dist/tv-core/  (wasm-bindgen web-target glue + .wasm)
    host      <- this directory (config.xml, bootstrap, AVPlay adapter)
    tizen build-web && tizen package  -> signed .wgt

Before ANY UI work: run the section-11 networking verification gate on real
hardware — every API in config.xml `<access>` plus stream CDN redirects, range
requests, and auth headers, from inside the TV sandbox.

Player: AVPlay behind the shared PlayerBackend (report section 25). The host
adapter belongs here (`player/`), never in the shared frontend.
