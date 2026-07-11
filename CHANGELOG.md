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

- **Release pipeline: tag-derived release kinds + `.happ` inheritance (release-patterns UNYT-948).** The release kind is derived from the pushed tag — `vM.m.0` builds the DNA from source (migration release, a new lineage), while `vM.m.p` with `p>0` inherits its lineage's `unyt.happ` + `alliance.dna` byte-for-byte from the parent `vM.m.0` release and repacks only the UI into `unyt.webhapp` (UI release: one lineage, one DNA, one `app_id`). Three guards keep it safe: the inherited happ's sha256 must match the committed `lineage.json`; the DNA source (`dnas/`, `crates/rave_engine`, and the workspace `Cargo.toml`/`Cargo.lock` — the full set `yarn build:zomes` compiles into the DNA) must be identical between the parent and current inner-app commits (a zome or workspace-dep change fails, naming a new lineage as the correct kind); and a missing parent release, or one missing the `unyt.happ`/`alliance.dna` assets, fails rather than rebuilding. New `scripts/release-kind.sh`, `scripts/inherit-ui-release.sh`, and the `lineage.json` pin.
- **Release pipeline: a version contract (release-patterns UNYT-946).** `unyt/src-tauri/Cargo.toml` is the single source of truth for the version; a pushed tag or a `tauri.conf.json` that disagrees fails the release before any artifact is built (new `scripts/check-version-contract.sh`). The shipped app build now receives `VITE_MIGRATION_SERVICE_URL` (the update router the app polls), with a guard step that fails an empty value — no more installers that can never check for updates.

### Changed

- **Release pipeline: publish only artifacts the repo builds.** Drop the never-built `agent_details.dna` from the release, and set `artifactErrorsFailBuild` so a declared-but-missing artifact fails the release. The matrix job takes the version from the `publish-happ` job output instead of re-reading `tauri.conf.json`.
