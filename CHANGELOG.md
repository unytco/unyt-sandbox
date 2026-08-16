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

- **Every installer a release ships is installed, launched and photographed (UNYT-966/967/968)** — the `.deb`, the AppImage, both `.dmg`s, the NSIS `.exe` on windows-2022 and windows-2025, and the `.msi` (`scripts/smoke/load-proving/`, phase 1 of `release-smoke.yaml`).
- **A green phase-1 lane means:** the artifact installed, the app reached a healthy backend state, and a frame of *its own window* is the app's own screen.
- **The bars that frame clears:** at least 1000 distinct colours, and no single colour over 75% of it. A bare menu bar over a blank window clears neither.
- **It does not mean the screen is the right screen.** No text is read and no element is identified.
- **A lane that cannot launch, or cannot trust its capture, is red.** Nothing here skips, and nothing is quietly green.
- **Every lane photographs the screen before it launches anything.** On Linux and Windows a frame that already passes for the app answers `UNTRUSTED`; on macOS it turns pixel mode off instead.
- **macOS may answer `WINDOW-ONLY`:** the app put a real on-screen window up at a real size, and webview paint is unverified. Green with a warning, and never the word a photographed lane gets.
- **Static checks of what the artifact is** (phase 2): install, version, binary compatibility and declared dependencies in pristine distro containers; macOS signing, notarization, architecture and deployment target; a Windows install/uninstall cycle with an import-table check. Runnable locally with Docker: `scripts/smoke/run-smoke.sh <artifact>`.
- **A lane that does not answer is red on every platform.** Each reads its verdict in a step of its own that runs whatever the launch did, so a launch that never happened reads as NO ANSWER.
- **An installer the inventory cannot name fails the run.** The presence tests are exact suffixes, so a renamed artifact used to read as an absent one and its lane would quietly stop existing.
- **Two findings on the first release smoked, both gated red:** the `.deb` declared 2 of its 11 shared libraries (fixed in `unyt/`), and **the Windows installers are unsigned**, so users meet a SmartScreen "unknown publisher" block.
- **The phases run concurrently**, so a notarization finding still lands on a build whose window came up blank.
- **The harnesses run on every pull request** (`.github/workflows/ci.yaml`): the smoke oracle, the macOS check harness bare and in CI's shape, both again under bash 3.2, the load-proving suite against an Xvfb display of its own, and four linters.
- **Tag-derived release kinds and `.happ` inheritance (UNYT-948).** `vM.m.0` builds the DNA; `vM.m.p` inherits it and repacks only the UI.
- **A version contract (UNYT-946).** `unyt/src-tauri/Cargo.toml` is the single source of truth for the version; a tag or a `tauri.conf.json` that disagrees fails the release before an artifact is built (`scripts/check-version-contract.sh`).
- **The shipped build receives `VITE_MIGRATION_SERVICE_URL`** — the update router the app polls — and an empty value fails the run.
- **What CI cannot cover, as a hand check** ([`docs/windows-clean-machine-check.md`](docs/windows-clean-machine-check.md)): SmartScreen's "unknown publisher" block, a missing WebView2 runtime, a missing Visual C++ redistributable.

### Changed

- **A release run fails when the app does not open**, or when the smoke cannot prove its own checks still fail. The `static-checks-advisory` input softens phase 2 alone; nothing can reach phase 1 or the oracle.
- **A release is created draft.** A human publishes it, and the run's colour is what they read first.
- **The phase-1 lanes are one driver, not three.** `load-proving/prove.py` holds the control, the watch and the verdict for every platform; the capture stays native — ImageMagick on Linux, `screencapture` on macOS, `PrintWindow` on Windows.
- **The pre-release tag channel is `-dev.*`.** The update router matches `vM.m.p` only, so no pre-release is offered to users as an update.
- **A pre-release MSI's product version is derived from its tag at build time** (`scripts/msi-version.sh`): `0.101.0-dev.3` yields `0.101.0.3`.
- **An artifact is checked against its own version**, pre-release suffix included, and the `.msi` against the four-field version Windows registers.
- **The macOS gate images are pinned to `macos-15` / `macos-15-intel`, and the build legs are not.** The artifact is launched on an OS older than the one that produced it, which is what most users have.
- **Each stage-3 lane is named for what it tests**: `setup test`, `test opens app — <target>`, `test static checks — <target>`.
- **Only artifacts the repo builds are published**, and a declared-but-missing artifact fails the release.
- **A pushed tag never reaches a shell.** Tag names are untrusted input and travel through `env`.
- **The Linux build leg reports free disk either side of the build.** A release compile of the Holochain 0.7 stack can exhaust a runner.
- **`AGENTS.md` is one line: read the code.** The scripts, the harnesses that test them and the workflows that run them are the only account of this repo that cannot drift.

### Fixed

- **The `ui_ready` webview gate is gone — it could never pass.** The breadcrumb comes from the main window, which a cold install on an authenticated build never opens. Whether the webview drew anything is phase 1's question, answered by a photograph.
- **The dependency check called a correctly-floored package under-declared.** tauri-bundler appends bare duplicates of two entries it also copies with floors; every declared entry for a name is now weighed and the strongest lower bound decides.
- **A declared alternation handed one package's floor to another.** An alternation is only as strong as its weakest branch, since apt may satisfy it through any of them.
- **The expected-dependency snapshots were a pre-0.7 baseline**, so the drift gate fired on every image of the first 0.7 release. Re-captured from `v0.101.0-dev.1`.
- **The macOS check harness worked in the release's own state and results files**, so scenarios shared a mountpoint and fixture rows reached the release's table. Every invocation now gets its own.
- **The Linux smoke starts on a runner with no cached image.** `docker run`'s pull narration no longer arrives as the container id.
