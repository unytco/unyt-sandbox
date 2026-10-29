# Code signing

Tracked in Linear as UNYT-1093 (sub-issues UNYT-1095 macOS, UNYT-1094 Windows).

Two repos release signed binaries, both with Tauri 2 and `tauri-apps/tauri-action`, and **both must be supported**:

| Repo | Releases |
|------|----------|
| `unytco/unyt-sandbox` (this one) | TestNet app, "Unyt Sandbox" |
| `unytco/unyt-release` | MainNet app |

As of 2026-10-29 their `.github/workflows/release-tauri-app.yaml` and `scripts/check-build-credentials.sh` are byte-identical. Each builds the app code from the `unytco/unyt` checkout (a submodule here) with `--config ../identity.json` merged on top, which supplies the product name, identifier and updater key. Tags `vX.Y.Z` release, `vX.Y.Z-dev.*` make throwaway builds. Because the pipelines are the same, anything below that says "the workflow" applies to both, and changes should be made in both.

Both products are published by the same legal entity, so one Apple team and one Windows certificate serve both.

Publisher of record: **Unyt Accounting Ltd** (British Virgin Islands). The certificate name users see on Windows and macOS is the validated legal entity name, so every account below must be opened in that name.

## Status

| Platform | What it needs | CI (both repos) | Accounts open? |
|----------|---------------|-----------------|----------------|
| macOS (direct download) | Apple Developer Program, Developer ID Application cert, notarization | Wired: reads `APPLE_*` secrets (Apple ID + app-specific password) | Secrets exist at org level; **whose Apple account is behind them is unknown** |
| Windows | OV/EV certificate with HSM-backed key, or Azure Artifact Signing | Not wired | No |
| Linux (deb, AppImage) | Nothing OS-level | n/a | n/a |
| Auto-updater | Tauri minisign key (`TAURI_SIGNING_PRIVATE_KEY`) | Wired, held in the `release` environment | Yes |

Secrets as listed on 2026-10-29 (names only; values and who set them aren't visible):
- Each repo has one repo-level secret, `UNYT_DEPLOY_KEY`, and a `release` environment.
- The `unytco` organization shares with both repos: `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_DEV_IDENTITY`, `APPLE_ID_EMAIL`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`, plus `ANDROID_KEY_*` and `CLOUDFLARE_ACCOUNT_ID`. Listing the full set needs org admin access.

So macOS signing is already set up, and the open question for UNYT-1093 is ownership: whether that Developer ID certificate and Apple ID belong to Unyt Accounting Ltd or to a person or another entity. `APPLE_DEV_IDENTITY` is the certificate's common name, which would show the answer, but its value can't be read from GitHub. Ask whoever set the secrets, or look in the Apple Developer account that issued the certificate.

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
5. **GitHub secrets.** Both workflows read the same names, which already exist as `unytco` organization secrets shared with both repos. When moving to Unyt Accounting Ltd's own Apple team, replace the values of those org secrets, so both repos pick them up; don't add repo-level duplicates. The values:
   - `APPLE_CERTIFICATE`: base64 of the `.p12`
   - `APPLE_CERTIFICATE_PASSWORD`
   - `APPLE_DEV_IDENTITY`: the cert's common name, `Developer ID Application: Unyt Accounting Ltd (TEAMID)`
   - `APPLE_TEAM_ID`
   - Notarization, either the current `APPLE_ID_EMAIL` + `APPLE_ID_PASSWORD` (app-specific password), or the API key: `APPLE_API_ISSUER`, `APPLE_API_KEY` (key ID), and the `.p8` contents written to a file with `APPLE_API_KEY_PATH` pointing at it. Check the Tauri macOS signing guide when switching.
   - **Credential guard (both repos):** `scripts/check-build-credentials.sh` fails CI if a build job reads any secret outside a fixed allowlist (`UNYT_DEPLOY_KEY` and the six `APPLE_*` names above). Switching to the API key means adding the new names to that allowlist, in both repos, which is a change to a security check and needs its owners' agreement.

Existing hardened-runtime entitlements are in `unyt/src-tauri/entitlements.plist`.

Check what already exists before enrolling: the org-level `APPLE_*` secrets (see Status) show that a certificate was set up, and the Apple Developer portal for that account shows who the Account Holder is. If it's already a Unyt Accounting Ltd organization membership, there may be nothing to open on the Apple side.

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

**Do not put `signCommand` in the shared app config.** `tauri.conf.json` lives in the `unytco/unyt` app repo, which both release repos build, and local dev builds use it too. A committed `signCommand` would make every build, including local and `-dev` builds, try to sign. Each release repo injects it in CI instead. Both already build with `--config ../identity.json` and write `tauri.merged.json`, so the signing config goes in that merged config or a CI-written overlay passed the same way, in the Windows leg only. The two repos' workflows are identical, so make the same change in both.

**Credential guard (decision needed).** `scripts/check-build-credentials.sh`, identical in both repos, requires every job other than a few named credential holders to have read-only `permissions` and to read no secret beyond the allowlist. The Windows build leg is such a job with `contents: read`, and Tauri signs inside the build. So:
- Azure OIDC needs `id-token: write`, which the guard rejects.
- An Azure client secret is not on the allowlist, and would sit where build code can read it.
- Moving signing to a separate holder job after the build would change the artifacts after `updater-provenance.sh` records their hashes.

Which of these to accept, or how to redesign it, is for the owners of that guard to decide. Don't edit the guard as part of a signing change without that agreement. The guard's reasoning applies to signing credentials generally: whatever can sign as Unyt can change what users trust.

**Which tags sign (decision needed).** Both repos trigger on `vX.Y.Z` and the throwaway `vX.Y.Z-dev.*`. Signing `-dev` builds spends signing quota (Basic is 5,000 signatures a month) and puts the Unyt identity on builds nobody should install. Decide whether they sign. Note `-dev` runs already sign updates with a throwaway key rather than the release key.

`unyt-release` has its own copy of `docs/signing.md`, still the old HackMD links, and `docs/windows-clean-machine-check.md` there links to it. It should be replaced with a pointer to this page, via a PR in that repo.

## Account tracker

- [ ] Confirm who is Account Holder / legal signatory for Unyt Accounting Ltd
- [ ] Find out whose Apple account and Developer ID certificate are behind the existing org `APPLE_*` secrets (ask whoever set them; check the Apple Developer portal)
- [ ] If not Unyt Accounting Ltd's: D-U-N-S number located or requested, then Apple Developer Program enrollment (organization)
- [ ] Developer ID Application certificate created under that team, `.p12` stored in the team password manager
- [ ] App Store Connect API key created
- [ ] `unytco` org `APPLE_*` secrets replaced with the org-owned team's values (both repos pick them up)
- [ ] New Entra tenant and pay-as-you-go subscription for Unyt
- [ ] Artifact Signing account created; BVI dropdown check done (record result here)
- [ ] Identity validation submitted / completed, or fallback CA chosen
- [ ] Decision with owners of the credential guard (`check-build-credentials.sh`, both repos) on how Windows signing credentials reach the build
- [ ] Decision on whether `-dev` tags sign
- [ ] Windows signing injected by CI config (not committed to the `unyt` app repo) in `unyt-sandbox` and `unyt-release`
- [ ] `docs/signing.md` in `unyt-release` replaced (PR)
- [ ] Test release tag in each repo: verify `spctl -a -vv`, `xcrun stapler validate`, and Windows `signtool verify /pa`
