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

- **A release now proves its app opens (UNYT-966/967/968).** Every installer it ships is installed on a clean machine, launched, and photographed: the release passes only if the app reached a healthy state and a frame of its own window shows a drawn screen. It does not prove the screen is the *right* screen — nothing in the frame is read or identified.
- **Static checks of what each artifact is:** install and uninstall, version, binary compatibility and declared dependencies in pristine distro containers; signing, notarization, architecture and deployment target on macOS. Runnable locally with Docker: `scripts/smoke/run-smoke.sh <artifact>`.
- **The gap CI cannot cover, written down as a hand check** ([`docs/windows-clean-machine-check.md`](docs/windows-clean-machine-check.md)): **our Windows installers are unsigned**, so a user meets a SmartScreen "unknown publisher" block that no runner ever sees.

### Changed

- **The run goes red when the app does not open**, when a lane cannot trust what it captured, or when the smoke can no longer prove its own checks still fail. A release is created as a draft, so the run's colour is what a human reads before publishing it — and the harnesses behind all of this now run on every pull request, not only inside a release.
- **A workflow holds its credentials only while it is checking out** — the release PAT is no longer left behind in the job's git config — and the Rust toolchain action is pinned to a commit rather than a branch that moves under it.
- **Release kinds come from the tag, and the version from one file (UNYT-946/948).** `vM.m.0` builds the DNA, `vM.m.p` inherits it and repacks only the UI, and `unyt/src-tauri/Cargo.toml` is the single source of truth for the version — a tag or a config that disagrees fails the release before an artifact is built. Pre-releases ship on a `-dev.*` channel the update router ignores, so one is never offered to users as an update.

### Fixed

- **Several smoke checks could pass without testing anything:** a webview gate a cold install could never satisfy, a dependency check that misread a correctly-declared package, macOS scenarios sharing state with the release around them, and a handful of platform-specific parse and path faults. Each now fails when the thing it checks is broken.
