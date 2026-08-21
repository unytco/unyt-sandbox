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

Take your installer from the [latest release](https://github.com/unytco/unyt-sandbox/releases/latest). Every build, including the older ones, is on the [Releases page](https://github.com/unytco/unyt-sandbox/releases).

Each release ships the same app in two variants. You can run either.

1. The **default-arc** version is a full arc node: it holds a full copy of the DHT locally, synchronizing all data being published.
2. The **zero-arc** version is lighter weight to run (which will be good for mobile phones, for example) because it only holds your own history, and caches some other network data, but some actions will be slower because you'll need to fetch data from peers on the network. It gossips and validates like any other node. It simply stores no shard of the DHT.

Take default-arc unless you want the lighter one.

### Reading an installer's name

Every installer is named for what it is, so you can pick yours from the filename alone:

```
unyt_<version>_Unyt.Sandbox_<variant>_<architecture>_<platform><extension>
```

| Part | Values |
| --- | --- |
| `<variant>` | `default-arc`, `zero-arc` |
| `<architecture>` | `aarch64` for Apple Silicon, `x64` for 64-bit Intel or AMD on macOS and Windows, `amd64` for the same on Linux |
| `<platform>` | `darwin` for macOS, `linux`, `windows` |
| `<extension>` | macOS `.dmg`, Linux `.deb` or `.AppImage`, Windows `.exe` (setup) or `.msi` |

A release also carries assets that are not installers: the `.app.tar.gz` bundles, which the app's own updater uses, and `unyt.happ`, `unyt.webhapp` and `alliance.dna`, which are the Holochain application the installers are built around. Installing Unyt needs none of them.

### On Linux, swapping between the two variants

Both variants install as the package `unyt-sandbox` at the same version. With either one already installed, `apt install ./unyt_..._linux.deb` finds that version present, changes nothing and exits 0. A graphical software centre installs through the same package manager, so it does nothing either. To actually swap, install the .deb directly:

```sh
sudo dpkg -i ./unyt_*_zero-arc_amd64_linux.deb
```

or make apt reinstall it:

```sh
sudo apt install --reinstall ./unyt_*_zero-arc_amd64_linux.deb
```

The AppImage has none of this. Each file runs on its own.

Once installed, the Unyt software will run locally on your device and connect with others also running the software to operate as a peer-to-peer application.

## Setup

Note: In Mac, because you downloaded the software directly and not through Apple's App Store, you may need to open the System Settings and go to Privacy and Security, scroll down to Security and give Unyt permission to run.

To reset completely and start over with a new account: uninstall the app, delete local data (`~/Library/Application Support/co.unyt.unyt` on macOS), and reinstall. You'll get a new key pair and a fresh identity.

When you open Unyt on your operating system for the first time, it will create a set of public and private keys for you that you can use to interact with others. These are stored in a private keystore (Lair) on your own machine and are used during future uses. In Unyt we often refer to this public key as "your address" as it is how others can refer to you when sending, receiving or authorizing you to perform particular roles.

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
