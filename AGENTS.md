# unyt-sandbox — Agent Instructions

## Purpose

Outer wrapper repo for the Unyt application. Holds release docs,
testing docs, the project README, and **the actual app as a nested
submodule** at [`unyt/`](unyt/). No application source code lives at
this level.

## Classification

`release` — the deployment target is the nested `unyt/` repo.

## Stack

- Markdown docs only at this level (`README.md`, `docs/`,
  `release_docs/`, `testing_docs/`).
- The application stack lives in [`unyt/`](unyt/): Tauri
  (Rust + TypeScript), `flake.nix`-based dev shell.

## Build / Format / Test

Defer to the nested submodule:

```bash
cd unyt
# follow ./unyt/AGENTS.md for build, format, test, run instructions
```

This wrapper has no build, format, or test of its own.

## Deploy

Deployment is the nested `unyt` app. See
[`unyt/AGENTS.md`](unyt/AGENTS.md) for release packaging.

## Related repos in workshop

- Contains [`unyt`](unyt/) as a nested submodule (`unytco/unyt`) — the
  actual Tauri app.
- Workshop AGENTS.md describes the nested-submodule workflow gap (this
  wrapper's pointer-to-`unyt` is what `make open-prs` picks up; edits
  inside `unyt/` need their own commit + PR first). See
  [workshop AGENTS.md § Nested submodule note](../AGENTS.md#nested-submodule-note-unyt-sandboxunyt).

## Changelog

File: [`./CHANGELOG.md`](./CHANGELOG.md). Format: [Keep a Changelog
1.1.0](https://keepachangelog.com/en/1.1.0/) with `## [Unreleased]` at
the top. Entries here are limited to wrapper-level changes — README,
release docs, testing docs. App-level entries belong in
[`unyt/CHANGELOG.md`](unyt/CHANGELOG.md). Most agent sessions will
NOT need to touch this file.

## Repo-specific rules

- **Never edit application source from this directory.** All app code
  lives in `unyt/`. Treat this wrapper as docs-only.
- **Pointer bumps to `unyt/`** are how new app builds are recorded
  here. The corresponding app commit must already be on the inner
  repo's tracked branch before bumping the pointer.
