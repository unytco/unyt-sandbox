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

- **Release pipeline: a post-release install smoke on pristine distro containers.** A release now installs the `.deb` it just published into stock `ubuntu:22.04` / `ubuntu:24.04` / `debian:12` containers — not a CI runner, which carries hundreds of preinstalled libraries and would hide an under-declared dependency — and checks four things: the package's dependencies resolve on a machine with nothing on it, the binary's glibc requirement is within the oldest supported target, its declared `Depends:` match what the binary actually links against, and the app launches, stays up past a conductor-heartbeat interval, and exits on SIGTERM. Report-only against a release; runnable on a laptop with just Docker (`scripts/smoke/run-smoke.sh <artifact.deb>`). New `scripts/smoke/`.
  - The **AppImage** gets its own sequence, since it declares no dependencies to check: the gate is the glibc ceiling across the *whole bundle* (v0.100.0's inner binary needs 2.34 but its bundled WebKit needs 2.35, so checking the executable alone would under-report the floor by a release), plus the list of libraries it expects the host to provide and a check that no build-machine paths are baked into `AppRun`.
  - **It already found a real packaging bug:** `tauri-bundler` writes a hardcoded `Depends:` and never computes one from the binary, so our `.deb` declares 2 of the 11 shared-library dependencies it actually has — including the missing `libc6 (>= 2.34)` floor that would let the package install on a too-old glibc and then fail at exec.
- **Release pipeline: tag-derived release kinds + `.happ` inheritance (release-patterns UNYT-948).** `vM.m.0` builds the DNA; `vM.m.p` inherits it and repacks only the UI.
- **Release pipeline: a version contract (release-patterns UNYT-946).** `unyt/src-tauri/Cargo.toml` is the single source of truth for the version; a pushed tag or a `tauri.conf.json` that disagrees fails the release before any artifact is built (new `scripts/check-version-contract.sh`). The shipped app build now receives `VITE_MIGRATION_SERVICE_URL` (the update router the app polls), with a guard step that fails an empty value — no more installers that can never check for updates.

### Changed

- **Release pipeline: publish only artifacts the repo builds.** Drop the never-built `agent_details.dna` from the release, and set `artifactErrorsFailBuild` so a declared-but-missing artifact fails the release. The matrix job takes the version from the `publish-happ` job output instead of re-reading `tauri.conf.json`.
