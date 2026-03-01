# Oracles Release (v0.55.0)

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox/total?style=for-the-badge)

## Intro

Unyt is a peer-to-peer accounting framework built on Holochain that lets groups define their own economic rules — their own currencies, fee structures, and programmable agreements.

This release brings **configurable pricing oracles** to Unyt apps, allowing communities to securely bring external pricing data — both crypto and fiat — into their peer-to-peer accounting environments. Participants can view price estimates converted to their preferred currency, and dynamic smart agreements can react to external market data.

Also check out the [Oracles: Blockchain Token & Forex Pricing in Unyt Apps](https://unyt.co/blog/oracles:-blockchain-token-and-forex-pricing-in-unyt-apps/) blog post.

## What's New

An oracle is a trusted data bridge that reports external price information into a Unyt app so participants can make decisions based on current market values. This release adds oracle support for both cryptocurrency prices (BTC, ETH, etc.) and forex exchange rates (USD, EUR, TRY, etc.).

**How it works:** A designated oracle bot fetches prices from multiple external APIs and publishes them as immutable on-chain price sheets, each valid for a defined time window. Because every peer validates against the same committed data point, determinism is preserved even though the price data originates off-chain. The system uses a multi-source resilience strategy — querying up to three APIs and dropping outliers — so no single API glitch can corrupt pricing.

**What it enables:**

- **Preferred currency display** — View transaction values and balances converted to the currency you think in.
- **Dynamic smart agreements** — Agreements that react to external prices, such as escrow tied to a USD value or billing pegged to a forex rate.
- **Informed trading** — Recent price estimates during multi-currency trades for quick apples-to-apples comparison.

This implementation of oracles is primarily intended to

1. enable users to be able to see and think about value in whatever units they are most comfortable thinking in and
2. have pricing information to provide some guidance or sanity around proposed trades.

This is not configured for high frequency trading. For that, you would want to use different data sources and custom validation of the correctness and timeliness of data from those sources.

For the full technical details — including the three-step hybrid architecture, the single/dual/triple source resilience patterns, and considerations around multiple authorized oracles — see the [Oracles blog post](https://unyt.co/blog/oracles:-blockchain-token-and-forex-pricing-in-unyt-apps/).

---

Feel free to join the conversation in the Unyt Thread on the [Holochain DEV.HC Discord](https://discord.com/invite/k55DS5dmPH).

The Unyt Channel is here:
https://discordapp.com/channels/919686143581253632/1425157240972902430

How to give yourself access?

1. Go to the '#👤・5・select-a-role'' Channel
2. Assign yourself the ''Access to: Projects'' role
3. In the category ''Projects'' go to the channel called ''Unyt"

## Downloads

Select from two versions of apps to download.

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

## Related Resources

- [Unyt Setup](../README.md)
- [Unyt Documentation](https://unyt.co/docs/)
- [Unyt Dictionary](../testing_docs/4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](../testing_docs/4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)

## License

This project is licensed under the terms specified in the [LICENSE](../LICENSE) file.

Copyright (C) 2024 - 2026, unyt.co
