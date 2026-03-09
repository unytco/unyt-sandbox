install:
	@if [ -d node_modules ]; then \
		echo "node_modules already exists, skipping install"; \
	else \
		if [ -n "$$CI" ] && [ -z "$$BUILD_WEAVE_CLI" ]; then \
			echo "CI detected and BUILD_WEAVE_CLI not set, skipping postinstall scripts"; \
			yarn install --ignore-scripts; \
		else \
			yarn install; \
		fi \
	fi
	@cd unyt && if [ -d node_modules ]; then \
		echo "node_modules already exists, skipping install"; \
	else \
		if [ -n "$$CI" ] && [ -z "$$BUILD_WEAVE_CLI" ]; then \
			echo "CI detected and BUILD_WEAVE_CLI not set, skipping postinstall scripts"; \
			yarn install --ignore-scripts; \
		else \
			yarn install; \
		fi \
	fi

setup: 
	git submodule update --init --recursive

launch:
	cd unyt && yarn build:happ
	mkdir -p workdir
	cp -r unyt/workdir/unyt.happ workdir/unyt.happ
	yarn network:tauri

#JOINING_SERVICE_URL=http://localhost:3000 

# Uses current tauri.conf.json and icons. Run prep-app-<variant> first for a specific variant.
launch-android: install
	yarn launch:android

package:
	cd unyt && APP_VERSION=$(jq -r '.version' ./src-tauri/tauri.conf.json) make package

# Signing key: set TAURI_SIGNING_PRIVATE_KEY (and TAURI_SIGNING_PRIVATE_KEY_PASSWORD) or leave unset for unsigned.
TAURI_SIGNING_PRIVATE_KEY ?= $(CURDIR)/.tauri/test.key
TAURI_SIGNING_PRIVATE_KEY_PASSWORD ?=

build-linux: build-linux-default

# Uses current tauri.conf.json. For a specific variant use build-linux-unyt-sandbox or build-linux-holo-hosting.
build-linux-default: install
	HOLOCHAIN_ARC_FACTOR="" make build-unyt-sandbox

build-linux-zero: install
	HOLOCHAIN_ARC_FACTOR="0" make build-unyt-sandbox

# Multi-app: prep generates tauri.conf.json and copies icons for the active variant.
# Set TAURI_APP_VARIANT (unyt-sandbox | holo-hosting) and identity env vars, or use prep-app-* targets.
prep-app: install
	bash scripts/generate-tauri-config.sh
	bash scripts/copy-app-icons.sh

prep-app-unyt-sandbox: install
	TAURI_PRODUCT_NAME="Unyt Sandbox" TAURI_APP_IDENTIFIER=co.unyt.unyt.sandbox TAURI_APP_ID_PREFIX=unyt-sandbox TAURI_DEEP_LINK_SCHEME=unyt-sandbox TAURI_SPLASHSCREEN_TITLE="Unyt Loading" TAURI_APP_VARIANT=unyt-sandbox bash scripts/generate-tauri-config.sh
	TAURI_APP_VARIANT=unyt-sandbox bash scripts/copy-app-icons.sh

prep-app-holo-hosting: install
	TAURI_PRODUCT_NAME="Holo Hosting" TAURI_APP_IDENTIFIER=co.unyt.holo-hosting.sandbox TAURI_APP_ID_PREFIX=holo-hosting TAURI_DEEP_LINK_SCHEME=holo-hosting TAURI_SPLASHSCREEN_TITLE="Holo Hosting Loading" TAURI_APP_VARIANT=holo-hosting bash scripts/generate-tauri-config.sh
	TAURI_APP_VARIANT=holo-hosting bash scripts/copy-app-icons.sh

# Build a specific app variant (prep + tauri build with same identity env).
build-unyt-sandbox: prep-app-unyt-sandbox
	TAURI_APP_IDENTIFIER=co.unyt.unyt.sandbox TAURI_APP_ID_PREFIX=unyt-sandbox TAURI_SIGNING_PRIVATE_KEY="$(TAURI_SIGNING_PRIVATE_KEY)" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$(TAURI_SIGNING_PRIVATE_KEY_PASSWORD)" yarn tauri build --bundles deb

build-holo-hosting: prep-app-holo-hosting
	TAURI_APP_IDENTIFIER=co.unyt.holo-hosting.sandbox TAURI_APP_ID_PREFIX=holo-hosting TAURI_SIGNING_PRIVATE_KEY="$(TAURI_SIGNING_PRIVATE_KEY)" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$(TAURI_SIGNING_PRIVATE_KEY_PASSWORD)" yarn tauri build --bundles deb

# Uses current tauri.conf.json. Run prep-app-<variant> first, or use build-android-<variant> for full CI-like flow.
build-android: install
	yarn tauri android build --debug

build-android-release: install
	yarn tauri android build

# Android variant build: same sequence as CI (prep → init Android project → cleartext → build).
# Run from repo root. Requires nix and flake .#androidDev. For release AAB/APK, set up signing in src-tauri/gen/android/key.properties.
build-android-unyt-sandbox: prep-app-unyt-sandbox
	rm -rf src-tauri/gen/android
	nix develop --accept-flake-config .#androidDev --command bash -c "yarn tauri android init"
	bash scripts/android-uses-cleartext-traffic.sh
	HOLOCHAIN_ARC_FACTOR=0 TAURI_APP_IDENTIFIER=co.unyt.unyt.sandbox TAURI_APP_ID_PREFIX=unyt-sandbox nix develop --accept-flake-config .#androidDev --command bash -c "make build-android-release"

build-android-holo-hosting: prep-app-holo-hosting
	rm -rf src-tauri/gen/android
	nix develop --accept-flake-config .#androidDev --command bash -c "yarn tauri android init"
	bash scripts/android-uses-cleartext-traffic.sh
	HOLOCHAIN_ARC_FACTOR=0 TAURI_APP_IDENTIFIER=co.unyt.holo-hosting.sandbox TAURI_APP_ID_PREFIX=holo-hosting nix develop --accept-flake-config .#androidDev --command bash -c "make build-android-release"
