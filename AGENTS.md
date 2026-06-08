# unyt-sandbox — Agent Instructions

> **This repo follows the workshop root's patterns — it does not define its own.** Development workflow, process, changelog conventions, and spec/feature-doc discipline live in the workshop: [`CLAUDE.md`](../CLAUDE.md), [`AGENTS.md`](../AGENTS.md), [`documentation/DEVELOPMENT_WORKFLOW.md`](../documentation/DEVELOPMENT_WORKFLOW.md). Below is only what's specific to THIS repo.

## Purpose

`release` (deployment target is the nested `unyt/` repo) — outer wrapper for the Unyt application. Holds release docs, testing docs, the project README, and **the actual app as a nested submodule** at [`unyt/`](unyt/). No application source code lives at this level.

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

## Repo-specific rules

- **All app work happens in [`unyt/`](unyt/); follow [`unyt/AGENTS.md`](unyt/AGENTS.md).** This wrapper is docs-only — never edit application source from this directory. Changelog entries here are wrapper-level (README, release/testing docs); app-level entries belong in [`unyt/CHANGELOG.md`](unyt/CHANGELOG.md).
- **Pointer bumps to `unyt/`** are how new app builds are recorded here. The corresponding app commit must already be on the inner repo's tracked branch before bumping the pointer. See [workshop AGENTS.md § Nested submodule note](../AGENTS.md#nested-submodule-note-unyt-sandboxunyt).
