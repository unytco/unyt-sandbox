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
	git submodule update --init
	cd unyt && git submodule update --init

launch:
	cd unyt && yarn build:happ
	mkdir -p workdir
	cp -r unyt/workdir/unyt.happ workdir/unyt.happ
	yarn network:tauri

launch-android: install
	yarn launch:android

package:
	cd unyt && APP_VERSION=$(jq -r '.version' ./src-tauri/tauri.conf.json) make package

build-android: install
	yarn tauri android build --debug

build-android-release: install
	yarn tauri android build

build-linux: build-linux-default

build-linux-default: install
	HOLOCHAIN_ARC_FACTOR="" TAURI_SIGNING_PRIVATE_KEY="/home/zo-el/Documents/git-repo/unyt/release/unyt-sandbox/.tauri/test.key" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" yarn tauri build --bundles deb

build-linux-zero: install
	HOLOCHAIN_ARC_FACTOR="0" TAURI_SIGNING_PRIVATE_KEY="/home/zo-el/Documents/git-repo/unyt/release/unyt-sandbox/.tauri/test.key" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" yarn tauri build --bundles deb

test-arc-factor: install
	@echo "Testing default arc factor (empty string):"
	HOLOCHAIN_ARC_FACTOR="" yarn tauri build --bundles deb
	@echo "Testing zero arc factor:"
	HOLOCHAIN_ARC_FACTOR="0" yarn tauri build --bundles deb

test-original-approach: install
	@echo "Testing original approach with environment variable at runtime:"
	HOLOCHAIN_ARC_FACTOR="0" yarn tauri build --bundles deb
	@echo "Built app should show arc factor in logs when run"


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
	TAURI_APP_IDENTIFIER=co.unyt.unyt.sandbox TAURI_APP_ID_PREFIX=unyt-sandbox yarn tauri build

build-holo-hosting: prep-app-holo-hosting
	TAURI_APP_IDENTIFIER=co.unyt.holo-hosting.sandbox TAURI_APP_ID_PREFIX=holo-hosting yarn tauri build