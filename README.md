# Unyt Sandbox

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox/total?style=for-the-badge)

## Intro

Unyt is peer-to-peer accounting infrastructure built on [Holochain](https://holochain.org/). Create currencies, automate economic agreements, bridge value across networks, and trade directly between any units — all without central servers, miners, or platform middlemen.

Every participant runs the application on their own device, maintains their own signed chain of records, and (if operating as a full arc node) validates peers directly. There is no blockchain consensus, no mining, and no third party holding your funds. Fees are entirely configurable by the community — they can even be set to zero.

Unyt isn't a platform you sign up for. It's a template you customize. Each deployment — called a Unyt Alliance — defines its own currencies, rules, smart agreements, and governance. You can bridge between alliances, connect to EVM blockchains, and trade across currency boundaries with atomic guarantees.

This repository is the Unyt Sandbox — a starting point on your journey to building and running your own Unyt Accounting Alliance apps. It ships pre-configured example apps that demonstrate different use cases.

For full documentation, visit [unyt.co/docs](https://unyt.co/docs/).

## Current Release — Oracles (v0.55.0)

This release brings **configurable pricing oracles** to Unyt apps, allowing communities to securely bring external pricing data — both crypto and fiat — into their peer-to-peer accounting environments. Participants can view price estimates converted to their preferred currency, and dynamic smart agreements can react to external market data.

For full details, see the [Oracles Release Documentation](./release_docs/oracles_v0.55.0.md).

Also check out the [Oracles blog post](https://unyt.co/blog/oracles:-blockchain-token-and-forex-pricing-in-unyt-apps/).

## Downloads — v0.55.0

The current release ships two pre-configured apps. You can run either or both.

- **Holo Hosting** — Configured to demonstrate what a Holo Hosting Unyt app might look like. Includes smart agreements for proof-of-service billing, invoicing, and service unit accounting. Also demonstrates bridging to the Infrastructure Marketplace Unyt app, blockchain bridging with HOT (EVM) tokens, multi-currency atomic trades, and cross-network value exchange.
- **Infrastructure Marketplace** — Configured for trading between monetary currencies from multiple external sources. Bridges to the Holo Hosting Unyt app.

Select from two versions of each app to download.

1. The **Full-Arc** version holds a full copy of the DHT locally, synchronizing all data being published.
2. The **Zero-Arc** version is lighter weight to run (which will be good for mobile phones, for example) because it only holds your own history, and caches some other network data, but some actions will be slower because you'll need to fetch data from peers on the network.

---

### Holo Hosting

#### Zero-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

##### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_0-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_0-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_0-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_0-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_0-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_0-arc_amd64_linux.deb)

</td>
</tr>
</table>

</div>

#### Full-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

##### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_default-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_default-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_default-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_default-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_default-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Holo.Hosting_default-arc_amd64_linux.deb)

</td>
</tr>
</table>

</div>

---

### Infrastructure Marketplace

#### Zero-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

##### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_0-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_0-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_0-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_0-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_0-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_0-arc_amd64_linux.deb)

</td>
</tr>
</table>

</div>

#### Full-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

##### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_default-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_default-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_default-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_default-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_default-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.55.0/unyt_0.55.0_Infrastructure.Marketplace_default-arc_amd64_linux.deb)

</td>
</tr>
</table>

</div>

---

All available versions can be found in the [Releases](https://github.com/unytco/unyt-sandbox/releases/)

Once installed, the Unyt software will run locally on your device and connect with others also running the software to operate as a peer-to-peer application.

## Setup

Note: In Mac, because you downloaded the software directly and not through Apple's App Store, you may need to open the System Settings and go to Privacy and Security, scroll down to Security and give Unyt permission to run.

To reset completely and start over with a new account: uninstall the app, delete local data (`~/Library/Application Support/co.unyt.unyt` on macOS), and reinstall. You'll get a new key pair and a fresh identity.

When you open Unyt on your operating system for the first time, it will create a set of public and private keys for you that you can use to interact with others. These are stored in a private keystore (Lair) on your own machine and are used during future uses. In Unyt we often refer to this public key as "your address" as it is how others can refer to you when sending, receiving or authorizing you to perform particular roles.

## Past Releases

- [Blockchain Bridging — v0.54.0](./release_docs/blockchain_bridging_v0.54.0.md) — Bridge EVM blockchain tokens into Unyt. Lock ERC-20 tokens on-chain and mirror them into a peer-to-peer environment with smart agreements, customizable fees, and direct trading.
- [Unyt Bridging — v0.50.0](./release_docs/unyt_bridging_v0.50.0.md) — Cross-application bridging and mirroring between independent Unyt Accounting Apps, plus bi-directional multi-unit payments.
- [Rideshare — v0.42.0](./release_docs/rideshare_v0.42.0.md) — Multi-unit accounting demonstrated through regional rideshare groups with custom price sheets and service unit accounting.
- [Smart Agreements — v0.40.0](./release_docs/smart_agreements_v0.40.0.md) — Introduction to Unyt's programmable Smart Agreements for automating economic logic.

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
