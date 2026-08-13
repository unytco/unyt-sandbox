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
  - **macOS and Windows get their own lanes, static checks only.** Neither platform has an equivalent of dpkg's dependency metadata, and neither has a pristine-machine option (no macOS support in `tauri-driver`, two VMs per Mac under Apple's EULA, no Windows Sandbox on GitHub-hosted runners), so each answers the release question from what the artifact itself declares. macOS, per architecture: the DMG mounts, the bundle is the version it claims, no Mach-O references `/usr/local` `/opt/homebrew` `/opt/local`, every Mach-O is signed, Gatekeeper accepts it as notarized, the ticket is stapled, and nothing demands a newer macOS than the bundle supports. Windows: a silent install, the uninstall registration, the Authenticode signature, every DLL the shipped binaries import against what Windows itself guarantees, and a clean uninstall. Both non-blocking, both proven able to fail by regression tests that run on any platform (`scripts/smoke/test-macos-checks.sh`, `scripts/smoke/test-windows-checks.ps1`). The one question a runner cannot answer — does it start on a machine that never had a build on it — is checked by hand per release ([`docs/windows-clean-machine-check.md`](docs/windows-clean-machine-check.md)).
  - **A finding, and a prediction.** The Windows installers are **unsigned** — there is no Windows certificate in `docs/signing.md` and none passed to the build in `release-tauri-app.yaml`, so every user meets a SmartScreen "unknown publisher" block. That check is gated red until a certificate is wired in. Separately, the app repo sets no `+crt-static`, so the import check is *expected* to report the Visual C++ redistributable (which Windows does not ship) the first time it runs on a real runner — fixed with `static_vcruntime`/`+crt-static` or by chaining the redist from NSIS.
- **Release pipeline: tag-derived release kinds + `.happ` inheritance (release-patterns UNYT-948).** `vM.m.0` builds the DNA; `vM.m.p` inherits it and repacks only the UI.
- **Release pipeline: a version contract (release-patterns UNYT-946).** `unyt/src-tauri/Cargo.toml` is the single source of truth for the version; a pushed tag or a `tauri.conf.json` that disagrees fails the release before any artifact is built (new `scripts/check-version-contract.sh`). The shipped app build now receives `VITE_MIGRATION_SERVICE_URL` (the update router the app polls), with a guard step that fails an empty value — no more installers that can never check for updates.

### Changed

- **Release pipeline: publish only artifacts the repo builds.** Drop the never-built `agent_details.dna` from the release, and set `artifactErrorsFailBuild` so a declared-but-missing artifact fails the release. The matrix job takes the version from the `publish-happ` job output instead of re-reading `tauri.conf.json`.
