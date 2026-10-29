# Code signing

Tracked in Linear as UNYT-1093 (sub-issues UNYT-1095 macOS, UNYT-1094 Windows).

Two repos release signed binaries, both with Tauri 2 and `tauri-apps/tauri-action` on a `v*` tag, and **both must be supported**:

| Repo | Releases | Workflow | Tauri config |
|------|----------|----------|--------------|
| `unytco/unyt-sandbox` (this one) | TestNet app, "Unyt Sandbox" | `.github/workflows/release-tauri-app.yaml` | `unyt/src-tauri/tauri.conf.json`, inside the `unytco/unyt` submodule |
| `unytco/unyt-release` | MainNet app | `.github/workflows/release-tauri-app.yaml` | Same app code, built with `--config ../identity.json` merged on top |

Both products are published by the same legal entity, so one Apple team and one Windows certificate serve both. What differs per repo is the CI wiring and the secrets.

Publisher of record: **Unyt Accounting Ltd** (British Virgin Islands). The certificate name users see on Windows and macOS is the validated legal entity name, so every account below must be opened in that name.

## Status

| Platform | What it needs | `unyt-sandbox` CI | `unyt-release` CI | Accounts open? |
|----------|---------------|-------------------|-------------------|----------------|
| macOS (direct download) | Apple Developer Program, Developer ID Application cert, notarization | Reads `APPLE_*` secrets (Apple ID + app-specific password) | Same secret names | Unknown, verify (see below) |
| Windows | OV/EV certificate with HSM-backed key, or Azure Artifact Signing | No | No | No |
| Linux (deb, AppImage) | Nothing OS-level | n/a | n/a | n/a |
| Auto-updater | Tauri minisign key (`TAURI_SIGNING_PRIVATE_KEY`) | Yes | Yes, held in the `release` environment | Yes |

As of 2026-10-29 `unyt-release` has one repo secret, `UNYT_DEPLOY_KEY`, so no signing secrets are set there. `unyt-sandbox` secrets haven't been listed.

Older notes on key generation (personal HackMD pages, not authoritative):
- Tauri keys: https://hackmd.io/@zo-el/S1vu7IFrxx
- Apple certificates: https://hackmd.io/@zo-el/SkARhyw9ke
- Android signing: https://hackmd.io/@zo-el/B1sHELKHxe

## Who does what

Opening these accounts needs a person who can bind Unyt Accounting Ltd to agreements, with a payment card, a phone, and government ID. An agent or CI cannot do it. Keep ready:
- Certificate of incorporation / good standing from the BVI registry (issued within the last 12 months)
- Registered address exactly as on the registry
- Company website and a monitored email on the company's own domain
- Government photo ID of the person validating

## macOS

Apple Developer Program membership is required to get a Developer ID certificate and notarize. App Store Connect is not needed to distribute outside the Mac App Store, but its API key is the recommended way to notarize from CI.

1. **D-U-N-S number** for Unyt Accounting Ltd. Look it up or request it via Apple's D-U-N-S page (free in most jurisdictions). Apple rejects DBAs, trade names and branches. Apple's pages do not say whether the BVI is a supported region; confirm at enrollment.
2. **Enroll as an organization** at https://developer.apple.com/programs/enroll/ (USD 99/year). The enrolling person becomes Account Holder. Requires a public website tied to the company's domain.
3. **Developer ID Application certificate.** Only the Account Holder can create it (Certificates, Identifiers & Profiles). Generate a CSR in Keychain Access, upload, download the `.cer`, export the pair as `.p12` with a password.
4. **App Store Connect API key** (Users and Access > Integrations > App Store Connect API > Team Keys). Note the Issuer ID, Key ID, and download the `.p8` once.
5. **GitHub secrets**, in **both** `unytco/unyt-sandbox` and `unytco/unyt-release` (the workflows use identical names). Either set them in each repo, or create them once as unytco organization secrets scoped to those two repos. The values:
   - `APPLE_CERTIFICATE`: base64 of the `.p12`
   - `APPLE_CERTIFICATE_PASSWORD`
   - `APPLE_DEV_IDENTITY`: the cert's common name, `Developer ID Application: Unyt Accounting Ltd (TEAMID)`
   - `APPLE_TEAM_ID`
   - Notarization, either the current `APPLE_ID_EMAIL` + `APPLE_ID_PASSWORD` (app-specific password), or the API key: `APPLE_API_ISSUER`, `APPLE_API_KEY` (key ID), and the `.p8` contents written to a file with `APPLE_API_KEY_PATH` pointing at it. Check the Tauri macOS signing guide when switching.
   - **`unyt-release` guard:** `scripts/check-build-credentials.sh` in that repo fails CI if a build job reads any secret outside a fixed allowlist (`UNYT_DEPLOY_KEY` and the six `APPLE_*` names above). Switching to the API key means adding the new names to that allowlist, which is a change to the repo's security check and needs its owners' agreement.

Existing hardened-runtime entitlements are in `unyt/src-tauri/entitlements.plist`.

Check what already exists before opening anything: `gh secret list -R unytco/unyt-sandbox` shows whether `APPLE_*` secrets were ever set, and the Apple Developer portal shows who the Account Holder is.

### Later: Mac App Store

The App Store needs an `Apple Distribution` certificate (not Developer ID) and a provisioning profile, with an app record in App Store Connect. Tauri config will need to know it is an App Store build, which is not notarized the same way.

## Windows

### Path A: Azure Artifact Signing (preferred if eligible)

Artifact Signing (formerly Trusted Signing) is about USD 10/month for the Basic plan, billed in full when the account is created. Public Trust certificates are limited to organizations in the US, Canada, EU, UK, Australia, New Zealand, Japan, South Korea, Singapore, Switzerland, Norway and Israel ([quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)). **The BVI is not listed.** Whether Microsoft treats a BVI company as "United Kingdom" is unconfirmed; the test is whether it appears in the Country/Region dropdown of the organization identity validation form.

Constraints:
- Needs a paid subscription (pay-as-you-go or enterprise). Free, trial and sponsored subscriptions are refused.
- Certificate name is the validated legal name; no customization.
- Identity validation is portal-only and takes 1 to 20 business days. Three attempts if Microsoft asks for documents. A failure cannot be appealed through the same request.
- Resources cannot be moved between subscriptions or tenants. Pick the final home first.

Steps:
1. **New Unyt tenant.** https://entra.microsoft.com > Identity > Overview > Manage tenants > Create (Microsoft Entra ID). Name it for Unyt, use a domain owned by Unyt.
2. **New subscription** in that tenant, pay-as-you-go, billed to Unyt Accounting Ltd.
3. Register the provider and add the CLI extension:
   ```
   az provider register --namespace Microsoft.CodeSigning
   az extension add --name artifact-signing
   ```
4. Create the account in a supported region (for example West Europe or East US):
   ```
   az group create -n unyt-signing -l westeurope
   az artifact-signing create -n <globally-unique-name> -l westeurope -g unyt-signing --sku Basic
   ```
5. Assign yourself **Artifact Signing Identity Verifier**, then in the portal: Account > Identity validations > Organization > New Identity > Public. Complete the individual ID check from the emailed link.
6. When validation is **Completed**, create a **Public Trust** certificate profile (portal or `az artifact-signing certificate-profile create`).
7. **CI identity.** Create an app registration and give it **Artifact Signing Certificate Profile Signer** on the account. Prefer GitHub Actions OIDC over a client secret, with one federated credential per repo (`unyt-sandbox` and `unyt-release`). Standard federated credentials match the token's subject exactly, so a tag wildcard such as `refs/tags/*` does not work. Options: an `environment:<name>` subject (the signing job must then run in that environment), or a *flexible* federated credential, which allows `matches` patterns on `sub` and must also match `repository_id` or `repository_owner_id`. Flexible credentials can only be created in the portal or via Microsoft Graph, not the Azure CLI ([docs](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-set-up-flexible-federated-identity-credential)). Re-check the current GitHub subject format before creating them.
8. Store non-secret IDs as GitHub variables in each repo: tenant ID, subscription ID, client ID, endpoint URL (for example `https://weu.codesigning.azure.net`), account name, profile name.

### Path B: commercial certificate with cloud-hosted key (fallback)

Publicly trusted code signing keys must live in an HSM, so the choice is a CA with a cloud signing service, such as DigiCert KeyLocker or SSL.com eSigner. EV is not required for SmartScreen trust any more, but check current vendor guidance. Not yet evaluated: whether they validate a BVI company, price, and how they integrate with CI. Get quotes before choosing.

### Wiring into Tauri (not done yet)

Tauri calls a custom `bundle.windows.signCommand` for each binary, `%1` being the file. Either path ends up there, with Artifact Signing typically through a CLI wrapper such as `trusted-signing-cli`. Verify the tool name and flags against current docs when implementing. See https://v2.tauri.app/distribute/sign/windows/.

**Do not put `signCommand` in the shared app config.** `tauri.conf.json` lives in the `unytco/unyt` submodule, which both release repos build, and local dev builds use it too. A committed `signCommand` would make every build, including local and `-dev` builds, try to sign. Each release repo injects it in CI instead:
- `unyt-release`: it already builds with `--config ../identity.json` and writes `tauri.merged.json`, so the signing config goes in its merged config or a CI-written overlay.
- `unyt-sandbox`: the build step passes no `--config` today, so it needs its own overlay (for example a `--config` file written in the Windows leg only).

**`unyt-release` credential guard (decision needed).** That repo's `scripts/check-build-credentials.sh` requires every job other than a few named credential holders to have read-only `permissions` and to read no secret beyond the allowlist. The Windows build leg is such a job with `contents: read`, and Tauri signs inside the build. So:
- Azure OIDC needs `id-token: write`, which the guard rejects.
- An Azure client secret is not on the allowlist, and would sit where build code can read it.
- Moving signing to a separate holder job after the build would change the artifacts after `updater-provenance.sh` records their hashes.

Which of these to accept, or how to redesign it, is for the owners of that guard to decide. Don't edit the guard as part of a signing change without that agreement. The guard's reasoning applies to signing credentials generally: whatever can sign as Unyt can change what users trust.

**Which tags sign (decision needed).** `unyt-sandbox` triggers on `vX.Y.Z` and `vX.Y.Z-rc.*`; `unyt-release` on `vX.Y.Z` and `vX.Y.Z-dev.*`. Signing `-dev` and `-rc` builds spends signing quota (Basic is 5,000 signatures a month) and puts the Unyt identity on throwaway builds. Decide whether they sign.

`unyt-release` also has its own copy of `docs/signing.md`, still the old HackMD links. It should be replaced with a pointer to this page or this content, via a PR in that repo.

## Account tracker

- [ ] Confirm who is Account Holder / legal signatory for Unyt Accounting Ltd
- [ ] `gh secret list` to see whether any Apple secrets exist; check Apple Developer portal for an existing team
- [ ] D-U-N-S number located or requested
- [ ] Apple Developer Program enrollment (organization)
- [ ] Developer ID Application certificate created, `.p12` stored in the team password manager
- [ ] App Store Connect API key created
- [ ] GitHub secrets for macOS updated
- [ ] New Entra tenant and pay-as-you-go subscription for Unyt
- [ ] Artifact Signing account created; BVI dropdown check done (record result here)
- [ ] Identity validation submitted / completed, or fallback CA chosen
- [ ] Apple secrets set in both `unyt-sandbox` and `unyt-release` (or as org secrets scoped to both)
- [ ] Decision with owners of `unyt-release`'s credential guard on how Windows signing credentials reach the build
- [ ] Decision on whether `-rc` / `-dev` tags sign
- [ ] Windows signing injected by CI config (not committed to the `unyt` submodule) in `unyt-sandbox`
- [ ] Windows signing injected by CI config in `unyt-release`
- [ ] `docs/signing.md` in `unyt-release` replaced (PR)
- [ ] Test release tag in each repo: verify `spctl -a -vv`, `xcrun stapler validate`, and Windows `signtool verify /pa`
