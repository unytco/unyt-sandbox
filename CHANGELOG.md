# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file tracks **wrapper-level** changes only (README, release docs,
testing docs, and the pointer to the nested `unyt/` submodule).
Application-level changes belong in
[`unyt/CHANGELOG.md`](unyt/CHANGELOG.md).

## [Unreleased]

### Added

- **Release pipeline: a post-release install smoke (UNYT-966/967/968).** Installs each shipped artifact in pristine distro containers and asserts the app boots to a healthy state; report-only, and runnable locally with Docker (`scripts/smoke/run-smoke.sh <artifact>`). New `scripts/smoke/`.
  - **macOS and Windows lanes** — macOS is static checks only; Windows adds a silent install/uninstall cycle. The clean-machine check needs a hand ([`docs/windows-clean-machine-check.md`](docs/windows-clean-machine-check.md)).
  - **Two findings, both gated red:** the `.deb` declared 2 of its 11 shared libraries (fixed in `unyt/`), and the Windows installers are unsigned, so users meet a SmartScreen "unknown publisher" block.
- **Release pipeline: tag-derived release kinds + `.happ` inheritance (release-patterns UNYT-948).** `vM.m.0` builds the DNA; `vM.m.p` inherits it and repacks only the UI.
- **Release pipeline: a version contract (release-patterns UNYT-946).** `unyt/src-tauri/Cargo.toml` is the single source of truth for the version; a pushed tag or a `tauri.conf.json` that disagrees fails the release before any artifact is built (new `scripts/check-version-contract.sh`). The shipped app build now receives `VITE_MIGRATION_SERVICE_URL` (the update router the app polls), with a guard step that fails an empty value — no more installers that can never check for updates.

### Changed

- **Release pipeline: the pre-release tag channel is `-dev.*`, not `-rc.*`.** The update router matches `vM.m.p` only, so no pre-release tag is offered to users as an update.
- **Release pipeline: a pre-release build's MSI product version is derived from the tag (new `scripts/msi-version.sh`).** `0.101.0-dev.3` yields `0.101.0.3`, written at build time — committed, a `wix.version` would outlive its release.
- **Release smoke: an artifact is checked against its own version**, pre-release suffix included, and the `.msi` against the four-field version Windows registers.
- **Release smoke: the inventory matches asset suffixes literally, and every result row is vetted.** Two fields, a declared name, a verdict of `pass`, `warn` or `FAIL`; anything else reads `MALFORMED`.
- **Release smoke: the Windows lane summarises only the installers the release carries.** A skipped installer says so in the published table, and a lane that smoked neither installer fails.
- **Release smoke: the Windows uninstall check reads the install directory before it runs the uninstaller.** Missing state fails the check with the app still on disk to re-run against.
- **Release pipeline: the Linux build leg reports free disk either side of the build.** A release compile of the Holochain 0.7 stack is large enough to exhaust a runner.
- **Release pipeline: a pushed tag is never interpolated into a shell.** The changelog step takes the version through `env`; tag names are untrusted input.
- **Release pipeline: the release build installs with `yarn install --frozen-lockfile --ignore-engines`.** Both the build path and the UI-release path, matching the app's other CI.
- **Release pipeline: a release's smoke check is non-blocking.** It annotates and reports a failure without failing the release run; a hand-dispatched smoke still answers red.
- **Release pipeline: publish only artifacts the repo builds.** Drop the never-built `agent_details.dna` from the release, and set `artifactErrorsFailBuild` so a declared-but-missing artifact fails the release. The matrix job takes the version from the `publish-happ` job output instead of re-reading `tauri.conf.json`.
- **Release smoke: the `ui_ready` webview gate is gone — it could never pass.** The breadcrumb is emitted by `app-root`, which lives in the main window, and that window is created by `post_conductor_ready` only once the conductor is serving; a cold install on an authenticated build stops at `HcAuthRequired`, which deliberately does not reach `LairReady`, so setup never runs and the window never opens. The gate failed on every release it ran against while the app was working correctly. **The launch check now proves the backend only** — that the process comes up, reaches a healthy state, is a cold install, stays up and shuts down cleanly. Nothing in the release lane asserts what the webview drew; the screenshot lane that photographs the app's own window (`scripts/smoke/load-proving/`) runs outside the release path.
- **`AGENTS.md` lists the release scripts this repo owns and the four harnesses in `scripts/smoke/` that test them.**

### Fixed

- **Release smoke: the macOS check harness worked in the release's own state and results files.** `run_scenario` gave the real `check-macos.sh` a stub toolchain but no state directory of its own, so under the workflow's environment — which sets `UNYT_SMOKE_STATE` and `UNYT_SMOKE_RESULTS` before the harness step — every scenario mounted into one shared directory, the scenario whose image holds no `.app` passed nine checks against the bundle the previous one had extracted, and 48 fixture rows landed in the results file the release's real checks report from, where a duplicate row reads as "a check is wired up twice". A bare local run hid both: with the variable unset the script mints a temp directory per invocation. Every invocation now gets its own state and results files, the harness puts itself in CI's shape whatever the environment it is run from, and a seeded caller directory is checked at the end to prove nothing reached it.
- **Release smoke: the Linux lane starts on a runner with no cached image.** `docker run`'s stderr was folded into its stdout, so the pull narration became the container id and every later `docker exec` failed — which the reaping probe then reported as "PID 1 is not reaping orphans". The stderr is captured to the lane instead, and a genuine docker failure still prints it.

