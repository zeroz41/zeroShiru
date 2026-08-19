# webOS host (migration phases 15, 17)

Planning baseline: webOS TV 5.x / 2020+ (Chromium 68+, WASM enabled by default;
report sections 28-29). Packaged app model: ares-package -> .ipk.

REQUIRED FIRST: the hardware feasibility spike from report section 28 —
package a hello-world + tiny WASM module, call it, perform HTTP, persist a
value, play test media, on a real LG TV. Nothing else starts until that passes.

Player: HTMLMediaElement/MSE behind the shared PlayerBackend (report section 30).
No webOS Node services (report section 57) — the shared Rust/WASM core is the
application.

Assembly mirrors the Tizen host: Vite renderer output + dist/tv-core WASM glue
+ this directory's adapters.
