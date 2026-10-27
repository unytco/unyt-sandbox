# Unyt Sandbox

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox/total?style=for-the-badge)

## Intro

Unyt is peer-to-peer accounting infrastructure built on [Holochain](https://holochain.org/). Create currencies, automate economic agreements, bridge value across networks, and trade directly between any units — all without central servers, miners, or platform middlemen.

Every participant runs the application on their own device, maintains their own signed chain of records, and (if operating as a full arc node) validates peers directly. There is no blockchain consensus, no mining, and no third party holding your funds. Fees are entirely configurable by the community — they can even be set to zero.

Unyt isn't a platform you sign up for. It's a template you customize. Each deployment — called a Unyt Alliance — defines its own currencies, rules, smart agreements, and governance. You can bridge between alliances, connect to EVM blockchains, and trade across currency boundaries with atomic guarantees.

This repository is the Unyt Sandbox — a starting point on your journey to building and running your own Unyt Accounting Alliance apps. It ships pre-configured example apps that demonstrate different use cases.

For full documentation, visit [unyt.co/docs](https://unyt.co/docs/).

## Downloads

Take your installer from the [latest release](https://github.com/unytco/unyt-sandbox/releases/latest). Every build, including the older ones, is on the [Releases page](https://github.com/unytco/unyt-sandbox/releases). A release run publishes its release as a pre-release. A person then makes it the latest release by hand.

Each release ships the same app in two variants. You can run either.

1. The **default-arc** version is a full arc node: it holds a full copy of the DHT locally, synchronizing all data being published.
2. The **zero-arc** version is lighter weight to run (which will be good for mobile phones, for example) because it only holds your own history, and caches some other network data, but some actions will be slower because you'll need to fetch data from peers on the network. It gossips and validates like any other node. It simply stores no shard of the DHT.

Take default-arc unless you want the lighter one.

### Reading an installer's name

Every installer is named for what it is, so you can pick yours from the filename alone:

```
unyt_<version>_<product>_<variant>_<architecture>_<platform><extension>
```

| Part | Values |
| --- | --- |
| `<product>` | The app's name, `productName` in [`identity.json`](identity.json), with each space as a dot |
| `<variant>` | `default-arc`, `zero-arc` |
| `<architecture>` | `aarch64` for Apple Silicon, `x64` for 64-bit Intel or AMD on macOS and Windows, `amd64` for the same on Linux |
| `<platform>` | `darwin` for macOS, `linux`, `windows` |
| `<extension>` | macOS `.dmg`, Linux `.deb` or `.AppImage`, Windows `.exe` (setup) or `.msi` |

A release also carries assets that are not installers: the `.app.tar.gz` bundles, and `unyt.happ`, `unyt.webhapp` and `alliance.dna`, which are the Holochain application the installers are built around. It also carries `.sig` signatures, the `updater-default-arc.json` and `updater-zero-arc.json` manifests the app's Update reads, and a `SHA256SUMS` file with the checksum of every installer, of the Holochain files and of `unyt_cli`. `SHA256SUMS.minisig` is its signature by the key the app's updates are signed with. Installing the app needs none of them.

To check a download, put it in one folder with `SHA256SUMS` and `SHA256SUMS.minisig`, and run [minisign](https://jedisct1.github.io/minisign/) and then `sha256sum` there:

```sh
minisign -VHm SHA256SUMS -P RWTMgl5pLxSOVpkRiS5CMlFkrn7enASWilDEzRpfPeTBcBBJXcdu/rFO
sha256sum --check --ignore-missing SHA256SUMS
```

The key after `-P` is this repo's update key, the second line of `plugins.updater.pubkey` in [`identity.json`](identity.json) once base64 decoded. minisign prints a trusted comment that names the release's version. On macOS, use `shasum -a 256 --check --ignore-missing SHA256SUMS`.

A `-dev` release is signed with a throwaway key, so this check holds for stable releases only.

### On Linux, swapping between the two variants

Both variants install as one package, the app's `productName` in lower case with dashes for spaces, at the same version. With either one already installed, `apt install ./unyt_..._linux.deb` finds that version present, changes nothing and exits 0. A graphical software centre installs through the same package manager, so it does nothing either. To actually swap, install the .deb directly:

```sh
sudo dpkg -i ./unyt_*_zero-arc_amd64_linux.deb
```

or make apt reinstall it:

```sh
sudo apt install --reinstall ./unyt_*_zero-arc_amd64_linux.deb
```

The AppImage has none of this. Each file runs on its own.

Once installed, the Unyt software will run locally on your device and connect with others also running the software to operate as a peer-to-peer application.

## unyt_cli

`unyt_cli` has releases of its own, tagged `cli-vX.Y.0.N`. Each is build `N` of the CLI for the app release `vX.Y.0`, whose DNA every `vX.Y.Z` carries.

- **Which one:** for any app release `vX.Y.Z`, take `unyt_cli` from the newest `cli-vX.Y.0.N` release. `unyt_cli --version` prints `X.Y.0.N`, and the release's notes are the section `## [X.Y.0.N]` of the pinned app's `crates/unyt_cli/CHANGELOG.md`. A CLI release is a pre-release that carries `unyt_cli` alone, so it is never the repo's latest release. Check it against the sha256 digest GitHub shows for it on that release.
- **Build 0:** once a `vX.Y.0` release run publishes its release, it makes `cli-vX.Y.0.0` from its own commit. Before you tag `vX.Y.0`, cut the Unreleased entries of the app's `crates/unyt_cli/CHANGELOG.md` into `## [X.Y.0.0]`. A `vX.Y.0-dev.M` run makes `cli-vX.Y.0-dev.M.0`.
- **Releasing newer CLI code:** in unyt-app, cut the Unreleased entries of `crates/unyt_cli/CHANGELOG.md` into a section `## [X.Y.0.N]`, with the next `N`. Make a branch here from the `vX.Y.0` tag. On it, pin `unyt` to an app commit with that code and that section, which must be on the app's remote. Push the tag `cli-vX.Y.0.N` at that commit. A lineage whose `vX.Y.0` predates CLI releases also needs, on that branch, this repo's CLI release workflow and the scripts it runs, and an app commit whose `unyt_cli` reads `UNYT_CLI_VERSION`.
- **The DNA rule:** the run builds the pinned app's DNA, and publishes nothing unless the `vX.Y.0` release carries that `alliance.dna` byte for byte. A change to `unyt_cli`'s own code never changes the DNA, so it never blocks a release. Anything the zomes build from does: `dnas/`, `crates/rave_engine`, their dependencies and the toolchain. If that changed since `vX.Y.0`, the run refuses: cherry-pick the CLI change onto the app commit `vX.Y.0` pins instead.

## Setup

Note: In Mac, because you downloaded the software directly and not through Apple's App Store, you may need to open the System Settings and go to Privacy and Security, scroll down to Security and give the app permission to run.

To reset completely and start over with a new account: uninstall the app, delete local data (`~/Library/Application Support/<identifier>` on macOS, where `<identifier>` is `identifier` in [`identity.json`](identity.json)), and reinstall. You'll get a new key pair and a fresh identity.

When you open the app on your operating system for the first time, it will create a set of public and private keys for you that you can use to interact with others. These are stored in a private keystore (Lair) on your own machine and are used during future uses. In Unyt we often refer to this public key as "your address" as it is how others can refer to you when sending, receiving or authorizing you to perform particular roles.

## Network

[`network.json`](network.json) names the network a release builds the app for.

Each X.Y.0 release and each pre-release runs its own joining, bootstrap, relay and auth services, and a patch release uses its X.Y.0 release's. So a release puts a version, with dots as dashes, in front of the subdomain of `UNYT_JOINING_SERVICE_URL`, `UNYT_BOOTSTRAP_URL`, `UNYT_RELAY_URL` and `UNYT_AUTH_SERVER_URL`: X.Y.0 at a stable tag vX.Y.Z, and the whole version at a pre-release. At tags `v0.115.0` and `v0.115.1`, `https://relay.unyt.dev` builds as `https://0-115-0-relay.unyt.dev`, and at tag `v0.111.0-dev.0` as `https://0-111-0-dev-0-relay.unyt.dev`. If `network.json` sets `UNYT_BOOTSTRAP_URL`, `UNYT_RELAY_URL` or `UNYT_AUTH_SERVER_URL` to `""`, the app uses its own default for that service, and no version is added.

`VITE_MIGRATION_SERVICE_URL`, `VITE_HOT_BRIDGE_URL` and `VITE_VOUCHER_SERVICE_URL` outlive any one app version, so they build as written. A release's notes list every value as it was built.

## Past Releases

Each of these describes one release, and its download links stay pinned to that version.

- [Oracles v0.55.0](./release_docs/oracles_v0.55.0.md): configurable pricing oracles, bringing external crypto and fiat pricing data into a Unyt app. Participants see price estimates in their preferred currency, and dynamic smart agreements can react to market data. There is also an [Oracles blog post](https://unyt.co/blog/oracles:-blockchain-token-and-forex-pricing-in-unyt-apps/).
- [Blockchain Bridging v0.54.0](./release_docs/blockchain_bridging_v0.54.0.md): bridge EVM blockchain tokens into Unyt. Lock ERC-20 tokens on-chain and mirror them into a peer-to-peer environment with smart agreements, customizable fees, and direct trading.
- [Unyt Bridging v0.50.0](./release_docs/unyt_bridging_v0.50.0.md): cross-application bridging and mirroring between independent Unyt Accounting Apps, plus bi-directional multi-unit payments.
- [Rideshare v0.42.0](./release_docs/rideshare_v0.42.0.md): multi-unit accounting demonstrated through regional rideshare groups with custom price sheets and service unit accounting.
- [Smart Agreements v0.40.0](./release_docs/smart_agreements_v0.40.0.md): introduction to Unyt's programmable Smart Agreements for automating economic logic.

## Related Resources

- [Unyt Documentation](https://unyt.co/docs/)
- [Unyt Blog](https://unyt.co/blog/)
- [Unyt Dictionary](./testing_docs/4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](./testing_docs/4_1_intro_to_smart_agreements.md)
- [Smart Agreement Code Library](https://github.com/unytco/smart_agreement_library)
- [Holochain DEV.HC Discord](https://discord.com/invite/k55DS5dmPH) — The Unyt channel is under Projects
- [Feedback / Issues](https://github.com/orgs/unytco/projects/5/views/1)

## License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file.

Copyright (C) 2024 - 2026, unyt.co
