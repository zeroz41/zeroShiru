# Every command, from the repository root, whatever your PATH looks like.
#
# The JS workspace lives in frontend/ and the Rust workspace at the root, so the
# raw commands need you to be in the right directory with the right tools on
# PATH. These targets do that for you: `make dev`, `make build`, `make test`.

# Bun is often installed without touching the shell PATH (fish especially), so
# find it rather than assuming it
BUN := $(shell command -v bun 2>/dev/null || echo $(HOME)/.bun/bin/bun)
CARGO := $(shell command -v cargo 2>/dev/null || echo $(HOME)/.cargo/bin/cargo)
FRONTEND := frontend

# the scripts these targets run call `bun` and `cargo` by name, so put whatever
# was found above within their reach too
export PATH := $(dir $(BUN)):$(dir $(CARGO)):$(PATH)

.DEFAULT_GOAL := help
.PHONY: help install dev build bundle android tv test test-js test-rust test-live test-torrent lint clean

help: ## show this list
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

install: ## fetch the frontend packages
	cd $(FRONTEND) && $(BUN) install

dev: ## run the desktop app against the dev server
	./scripts/dev.sh

build: ## production frontend into dist/web
	cd $(FRONTEND) && $(BUN) run build

bundle: build ## installers for this OS (AppImage/deb, MSI/NSIS, DMG)
	cd hosts/tauri && $(CARGO) tauri build

android: build ## APK from the same core
	cd hosts/tauri && $(CARGO) tauri android build --apk

tv: ## the shared core as WASM, for the TV hosts
	./scripts/build-tv-core.sh

test: test-js test-rust ## everything that runs offline

test-js: ## JS unit tests
	cd $(FRONTEND) && $(BUN) run test

test-rust: ## Rust workspace tests
	$(CARGO) test --workspace

test-live: ## opt-in: debrid providers and playback against real accounts
	$(CARGO) test -p shiru-debrid --features native --test live -- --ignored --nocapture
	set -a; [ -f .env ] && . ./.env; set +a; cd $(FRONTEND) && $(BUN) run test:live

test-torrent: ## opt-in: one real torrent through the engine and gateway
	$(CARGO) run -p shiru-torrent --features native --example smoke

clean: ## drop build output (not the packages)
	rm -rf dist/web dist/tv-core
	$(CARGO) clean
