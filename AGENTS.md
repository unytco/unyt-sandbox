# unyt-sandbox — Agent Instructions

> **This repo follows the workshop root's patterns — it does not define its own.** Development workflow, process, changelog conventions, and spec/feature-doc discipline live in the workshop: [`CLAUDE.md`](../CLAUDE.md), [`AGENTS.md`](../AGENTS.md), [`documentation/DEVELOPMENT_WORKFLOW.md`](../documentation/DEVELOPMENT_WORKFLOW.md). Below is only what's specific to THIS repo.

## Purpose

`release` (deployment target is the nested `unyt/` repo) — outer wrapper for the Unyt application. Holds the release pipeline, release docs, testing docs, the project README, and **the actual app as a nested submodule** at [`unyt/`](unyt/). No application source code lives at this level.

## Stack

- Docs (`README.md`, `docs/`, `release_docs/`, `testing_docs/`).
- The release pipeline: `.github/workflows/` plus the bash and PowerShell it drives — `scripts/` (version contract, release kind, UI-release inheritance, MSI product version) and `scripts/smoke/` (the post-release smoke for Linux, macOS and Windows: phase 2's static install checks at the top level, phase 1's launch-and-photograph lanes in `scripts/smoke/load-proving/`).
- The application stack lives in [`unyt/`](unyt/): Tauri (Rust + TypeScript), `flake.nix`-based dev shell.

## Build / Format / Test

No build step — the scripts are the deliverable. Each has a harness that proves its checks can still fail, and all of them run on any platform:

```bash
bash scripts/smoke/test-oracle.sh        # the log matchers, the release inventory, the summary guard, the workflows' wiring
bash scripts/smoke/test-macos-checks.sh  # the macOS check bodies
bash scripts/msi-version.sh --self-test  # the MSI product-version derivation
pwsh -NoProfile -File scripts/smoke/test-windows-checks.ps1   # the Windows check bodies
bash scripts/smoke/load-proving/test-proving.sh                  # phase 1's watch loop, verdicts and control frames
python3 scripts/smoke/load-proving/screenshot-stats.py --self-test  # phase 1's is-this-the-app-on-screen threshold
pwsh -NoProfile -File scripts/smoke/load-proving/prove-windows.ps1 -SelfTest  # phase 1's Windows install/launch decisions
```

Each prints `<n> passed, <n> failed`, exits non-zero on a failure, and enforces a floor on the count so that deleting assertions fails too — raise the floor whenever you add one. Without pwsh installed, reach for `nix run nixpkgs#powershell -- -NoProfile -File scripts/smoke/test-windows-checks.ps1`. `test-proving.sh` also has to pass under **bash 3.2** (what a macOS runner ships): `docker run --rm -v "$PWD:/w:ro" -w /w bash:3.2 sh -c 'apk add --no-cache python3 >/dev/null; bash scripts/smoke/load-proving/test-proving.sh'`.

Lint (not yet wired into CI):

```bash
nix run nixpkgs#actionlint -- .github/workflows/*.yaml
nix run nixpkgs#shellcheck -- scripts/*.sh scripts/smoke/*.sh scripts/smoke/load-proving/*.sh
```

Application build / format / test belongs to the nested submodule — follow [`unyt/AGENTS.md`](unyt/AGENTS.md).

## Deploy

A pushed `vM.m.p` — or `vM.m.p-dev.N`, a throwaway build that proves the pipeline — runs [`.github/workflows/release-tauri-app.yaml`](.github/workflows/release-tauri-app.yaml): stage 1 publishes the `.happ`, stage 2 builds and uploads the installers, stage 3 smokes them in two phases — **phase 1 "does it open"** launches every shipped installer and photographs the app's own window, and **fails the run** when it cannot; **phase 2 "static checks"** is the install/signing/dependency set, and stays advisory. The release is a draft either way: a human publishes it, and the run's colour is what tells them. Packaging the app itself is the nested submodule's — see [`unyt/AGENTS.md`](unyt/AGENTS.md).

## Repo-specific rules

- **All app work happens in [`unyt/`](unyt/); follow [`unyt/AGENTS.md`](unyt/AGENTS.md).** Never edit application source from this directory. Changelog entries here are wrapper-level (the release pipeline, README, release/testing docs); app-level entries belong in [`unyt/CHANGELOG.md`](unyt/CHANGELOG.md).
- **Pointer bumps to `unyt/`** are how new app builds are recorded here. The corresponding app commit must already be on the inner repo's tracked branch before bumping the pointer. See [workshop AGENTS.md § Nested submodule note](../AGENTS.md#nested-submodule-note-unyt-sandboxunyt).
