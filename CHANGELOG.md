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
  - **macOS and Windows lanes** — macOS is static checks only (signing, notarization, linkage and deployment target per architecture); Windows adds a real silent install/uninstall cycle alongside its Authenticode and import checks. The one check a runner cannot do is documented for hand-running ([`docs/windows-clean-machine-check.md`](docs/windows-clean-machine-check.md)).
  - **Two findings, both gated red:** the `.deb` declared 2 of its 11 shared libraries (fixed in `unyt/`), and the Windows installers are unsigned, so users meet a SmartScreen "unknown publisher" block.
- **Release pipeline: tag-derived release kinds + `.happ` inheritance (release-patterns UNYT-948).** `vM.m.0` builds the DNA; `vM.m.p` inherits it and repacks only the UI.
- **Release pipeline: a version contract (release-patterns UNYT-946).** `unyt/src-tauri/Cargo.toml` is the single source of truth for the version; a pushed tag or a `tauri.conf.json` that disagrees fails the release before any artifact is built (new `scripts/check-version-contract.sh`). The shipped app build now receives `VITE_MIGRATION_SERVICE_URL` (the update router the app polls), with a guard step that fails an empty value — no more installers that can never check for updates.

### Changed

- **Release pipeline: publish only artifacts the repo builds.** Drop the never-built `agent_details.dna` from the release, and set `artifactErrorsFailBuild` so a declared-but-missing artifact fails the release. The matrix job takes the version from the `publish-happ` job output instead of re-reading `tauri.conf.json`.

