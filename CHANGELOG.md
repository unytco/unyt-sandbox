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

- **Release pipeline: the pre-release tag channel is `-dev.*`, replacing `-rc.*`.** A build off it proves the pipeline and is never something a user installs, so it is named for what it is. The update router is unaffected either way — its tag regex is anchored to `vM.m.p`, so no pre-release tag has ever matched.
- **Release pipeline: a pre-release build gets an MSI product version (new `scripts/msi-version.sh`).** tauri's msi bundler parses the whole pre-release identifier as one number and bails on anything else, which would have taken the entire Windows job — `.exe` included — down with the `.msi`. `0.101.0-dev.3` now yields an MSI version of `0.101.0.3`. It is derived and self-tested in stage 1, so a tag the MSI cannot carry fails in seconds instead of after four platforms have started building, and it is written into `tauri.conf.json` at build time rather than committed — a `wix.version` sitting there would outlive the release that set it. A stable version is left alone for tauri to derive.
- **Release smoke: a pre-release artifact is checked against its own version.** Both the Windows and macOS lanes read the version out of the asset filename by stopping at the first `-`, so a `unyt_0.101.0-dev.0_…` artifact carried no readable version and every check that compares one went red saying nothing about the build. The `.msi` is compared against the four-field product version its bundler was handed, since that — not the tag — is what Windows registers.
- **Release smoke: two ways a lane could report clean without having checked.** The inventory matched asset suffixes as a regex, so `linux.deb` also answered true for an asset ending `linuxXdeb`. And the result table read a row's second field and stopped, so `check|pass|junk` printed the pass it had not earned while a row naming a check nobody declares was never looked up at all — rows are vetted now, and one that breaks the contract reads `MALFORMED` in the table rather than its claimed verdict.
- **Release smoke: the Windows lane no longer answers for an installer the release does not carry.** It summarised both whatever the inventory said, failing the lane its present sibling had just passed; a skipped installer now says so in the published table instead of vanishing from it, and a lane that smoked neither is a failure rather than an empty table that reads clean.
- **Release smoke: the Windows uninstall check demands the install directory before it removes anything.** It read that state only while polling for removal, so when the state was missing it uninstalled the app and only then discovered it could not verify the removal — red, with nothing left on disk to re-run against.
- **Release pipeline: the Linux build leg reports free disk either side of the build.** A release compile of the Holochain 0.7 stack is the same shape that ran the app's own test job out of space, and without a number in the log there is nothing to size a fix from.
- **Release pipeline: the release build installs dependencies the way the app's other CI does.** `yarn install --frozen-lockfile --ignore-engines`, on both the build path and the UI-release path — a bare `yarn install` aborted on `@holochain/hc-spin-rust-utils`'s `engines.node >= 24`, so `v0.101.0-rc.0` produced no installers at all. The smoke check a release calls is now non-blocking in the run's conclusion too, not just structurally: it still reports the failure, but no longer marks the release run itself failed.
- **Release pipeline: publish only artifacts the repo builds.** Drop the never-built `agent_details.dna` from the release, and set `artifactErrorsFailBuild` so a declared-but-missing artifact fails the release. The matrix job takes the version from the `publish-happ` job output instead of re-reading `tauri.conf.json`.
- **`AGENTS.md` lists what this repo actually has to run.** It claimed no build, format or test of its own while `scripts/` held the release scripts and `scripts/smoke/` four test harnesses, so a reader was told there was nothing here to run.

