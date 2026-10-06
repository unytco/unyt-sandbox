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
- Zero-arc installers ship alongside the default-arc ones, on all four platforms.
- **A release carries updater signatures and one update manifest per arc factor for the app's Update.** The installers themselves are signed no differently.
- A release carries a `SHA256SUMS` file, and `SHA256SUMS.minisig` signed by the update key, to check a downloaded installer, Holochain file or `unyt_cli` against.

### Changed

- **A release, and every installer in it, is Unyt Sandbox. It installs beside Unyt, and over Unyt Sandbox 0.108 or earlier.**
- **A release's notes name the network it was built for.**
- **The run goes red when the app does not open**, when a lane cannot trust what it captured, or when the smoke can no longer prove its own checks still fail. A release is created as a draft, so the run's colour is what a human reads before publishing it — and the harnesses behind all of this now run on every pull request, not only inside a release.
- **No job that builds the app holds a credential that can change a release, and no job that runs a built installer holds a token that can write.**
- **A workflow holds its credentials only while it is checking out** — the release PAT is no longer left behind in the job's git config — and the Rust toolchain action is pinned to a commit rather than a branch that moves under it.
- **A pre-release (a `-dev.*` tag) is never offered to users as an update.**
- **Installers and unyt_cli build with Rust 1.98.1, and a release stops when the app's CI pins another.**

### Fixed

- **Several smoke checks could pass without testing anything:** a webview gate a cold install could never satisfy, a dependency check that misread a correctly-declared package, macOS scenarios sharing state with the release around them, and a handful of platform-specific parse and path faults. Each now fails when the thing it checks is broken.
