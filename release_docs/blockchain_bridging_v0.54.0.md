# Blockchain Bridging Release (v0.54.0)

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox/total?style=for-the-badge)

## Intro

Unyt is a peer-to-peer accounting framework built on Holochain that lets groups define their own economic rules — their own currencies, fee structures, and programmable agreements.

This release enables **bridging between Unyt apps and EVM-compatible blockchains**, making it possible to lock ERC-20 tokens on Ethereum and mirror them into a Unyt app configured however you want.

For a summary, check out the [Blockchain Bridging: Use Unyt as Your Own Configurable L2](https://unyt.co/blog/blockchain-bridging:-use-unyt-as-your-own-configurable-l2/) blog post and see the blockchain bridging section of [the docs section](https://unyt.co/docs/) of the Unyt website for a walk through guide with more screenshots.

## What This Release Demonstrates

This release enables Unyt to bridge to any EVM-compatible blockchain (Ethereum, Polygon, Arbitrum, etc.), allowing on-chain tokens to be represented and used within a Unyt environment. When you bridge blockchain tokens into a Unyt app, it functions like a configurable L2 — with capabilities that go beyond what a typical L2 offers:

- **Peer-to-peer.** No miners, stakers, or gas fees needed. Validation is performed by the participants' own devices. Every action is cryptographically auditable, and dishonest actors are detected and excluded by peers.
- **Customizable fees.** Set fees to whatever makes sense for your project — including zero. Use them to fund development, reward participants, or eliminate them to remove friction.
- **Smart agreements.** Programmable economic logic that goes beyond simple token transfers — non-custodial escrow, recurring billing, bulk processing, multi-currency trades, and whatever your imagination can conceive of.
- **Direct trading.** Exchange value without needing order books or hopping across multiple trading pairs and limited liquidity pools.
- **Define additional units.** Beyond the bridged token, you can create native units for whatever else you want to account for, whether measurable (bandwidth, storage), monetary (an additional currency), or something else.

## How Blockchain Bridging Works

Bridging between Unyt apps and blockchains relies on blockchain smart contracts, Unyt bridging agreements, and one or more bridge agents — participating agents that you set up and authorize to take actions within your Unyt app based on events on the blockchain side and vice versa.

### Bringing Tokens In

Lock ERC-20 tokens in a smart contract on the EVM chain, specifying the destination Unyt app and your agent address. The bridge agent monitors the blockchain, detects your lock transaction, waits for sufficient block confirmations, then executes a bridge Smart Agreement that credits mirrored tokens to your Unyt address. The bridging agreement tracks deposit and withdrawal state per contract address.

From there, your tokens live in the Unyt environment — with access to smart agreements, direct trades, bridging to other Unyt apps, customizable fees, the works.

### Taking Tokens Out

Initiate a transfer out from within the Unyt app, specifying your blockchain destination address. The bridge agent executes the bridge Smart Agreement and produces a cryptographic coupon — signed using EVM-native methods (KECCAK-256 hashing, ECDSA signatures). Present this coupon to the blockchain smart contract, which independently verifies the signature and releases your tokens.

### Verification

Every lock and unlock is a standard blockchain transaction, visible on [Etherscan](https://sepolia.etherscan.io/) or any block explorer. The bridge doesn't hide anything behind opaque off-chain processes — the on-chain side is fully transparent.

---

## Blockchain Bridging Guide

This walkthrough covers the full process of bridging ERC-20 tokens between the Ethereum Sepolia testnet and a Unyt app. You will set up MetaMask, get test tokens, lock them on-chain, and receive mirrored tokens inside Unyt.

### 1. Install and Configure MetaMask

[MetaMask](https://metamask.io/) is a browser-based Ethereum wallet. You need it to sign blockchain transactions for bridging.

#### Install the Extension

Visit [metamask.io](https://metamask.io/) and install the browser extension for Chrome, Firefox, Brave, or Edge.

#### Create or Import a Wallet

When you first open MetaMask, you'll be asked whether to create a new wallet or import an existing one using a secret recovery phrase.

#### Enable Test Networks

By default, MetaMask only shows mainnet. To use the Sepolia testnet:

1. Click the network selector in MetaMask (accessible in the dropdown menu).
2. Select Networks.
3. In the Manage Networks menu, scroll down and toggle on **Show test networks**.

After enabling Show test networks, you should see Sepolia in the network list.

#### Copy Your Ethereum Address

Switch to the Sepolia network, then copy your wallet address — you'll need it for the faucets and for bridging.

### 2. Get Sepolia Test ETH

You need a small amount of Sepolia ETH to pay gas fees for lock and unlock transactions.

1. Go to the [Google Cloud Sepolia Faucet](https://cloud.google.com/application/web3/faucet/ethereum/sepolia).
2. Paste your Ethereum address from MetaMask.
3. Click "Get 0.05 Sepolia ETH".

After a moment for the transaction to process on the blockchain, you should see the ETH balance in MetaMask on the Sepolia network.

### 3. Get Mock HOT Tokens

The test environment uses a mock HOT ERC-20 token deployed on Sepolia. You get these from the Unyt bridge page.

1. Navigate to [hot-bridge.unyt.dev](https://hot-bridge.unyt.dev/).
2. Click **Connect Wallet** (assuming you are logged in, this should add the correct network details).
3. Click **"Get mock HOT"**.
4. Your wallet address should auto-fill. Click **Request 10 mockHOT**.

#### Import Mock HOT into MetaMask

To see your mock HOT balance in MetaMask, import the token:

1. In MetaMask, under the Tokens tab, with Sepolia selected, click the 3-dot menu on the right, then select **Import tokens**.
2. Paste the contract address: `0xeaC8eEEE9f84F3E3F592e9D8604100eA1b788749`
3. Click **Next** to confirm the import.

Now you should see a HOT balance in your wallet (under Sepolia).

### 4. Transfer In: Lock on Ethereum, Mirror in Unyt

Now you'll lock mock HOT tokens on the Sepolia blockchain and receive mirrored HOT inside the Unyt Holo Hosting app.

#### Initiate the Transfer

1. Open the Unyt Holo Hosting app.
2. Navigate to the **Bridges** section and select **Transfer In**.
3. Select the **HOT** unit and the **Sepolia Blockchain (Eth Test Network)**.
4. Click **Initialize Transfer**.
5. Click **Proceed** to continue to the Bridge interface.

> **Note:** If the transfer request opens in a different browser than the one with your MetaMask wallet, you can connect the wallet in that browser or click **Copy this page URL** to ensure no characters are missed. Then paste it into the browser where your wallet is connected.

#### Lock Your Tokens

1. Choose the amount of mock HOT to lock.
2. Click **"Approve HOT"** to authorize a spending cap for the HOT token.
3. Your wallet should open — confirm the spending cap request with the number of HOT that you entered.
4. Now that the spending cap has been authorized, click **Lock HOT**.
5. Confirm the lock transaction in MetaMask.
6. Once the transaction is confirmed on-chain, the lock is complete.
7. It may take a few minutes for the bridge agent to see the on-chain confirmation and then transfer Mirrored HOT to your Unyt Holo Hosting Address.

#### Receive Mirrored Tokens in Unyt

The bridge agent monitors the blockchain, detects your lock, waits for sufficient block confirmations, and then executes a bridge Smart Agreement that credits mirrored HOT to your Unyt address.

1. Back in the Unyt app, you'll see the incoming transfer in your action list.
2. Accept the incoming mirrored HOT tokens.

Your mirrored HOT tokens are now available in the Unyt environment — with access to smart agreements, direct trades, bridging to other Unyt apps, and customizable fees.

### 5. Transfer Out: Redeem in Unyt, Unlock on Ethereum

To move mirrored tokens back to the Ethereum blockchain:

1. In the Unyt app, click **Bridges** and then initiate a **Transfer Out**.
2. Select the mirrored HOT unit and the Ethereum (Sepolia) bridging network.
3. Enter your Ethereum wallet address as the destination (you can copy it from MetaMask, under Sepolia > Receive > Ethereum > copy address).
4. Confirm the transfer. The bridge agent will execute the bridge Smart Agreement and produce a cryptographic coupon — signed using EVM-native methods (KECCAK-256 hashing, ECDSA signatures).
5. The coupon will appear in your Action table. Click **Claim**, which redirects you to your browser where MetaMask can submit the unlock transaction.
6. The Ethereum smart contract independently verifies the coupon signature and releases your tokens.

Every lock and unlock is a standard blockchain transaction, visible on [Etherscan](https://sepolia.etherscan.io/) or any block explorer.

---

## What This Means for Token Projects

This opens up real flexibility for token projects. Your holders could transact with each other inside a Unyt app — with custom rules, customizable fees, and smart agreements — without paying L1 or even L2 gas on every interaction. The L1 tokens stay locked and verifiable on-chain while mirrored tokens move freely in the Unyt environment.

Unyt also supports bridging between Unyt networks. That means two projects that each bridge their tokens into Unyt apps could enable direct purchasing and spending between their communities — without needing to go through an exchange. That's increased utility for your token holders without changing supply dynamics.

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

> **Note:** To use blockchain bridging features, you'll need a browser-based wallet (e.g. MetaMask) installed and connected on your device.

---

### Holo Hosting

#### Zero-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

##### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_0-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_0-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_0-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_0-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_0-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_0-arc_amd64_linux.deb)

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

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_default-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_default-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_default-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_default-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_default-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Holo.Hosting_default-arc_amd64_linux.deb)

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

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_0-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_0-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_0-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_0-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_0-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_0-arc_amd64_linux.deb)

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

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_default-arc_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_default-arc_x64_windows.exe)

</td>
<td width="25%" align="center">

##### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_default-arc_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_default-arc_x64_darwin.dmg)

</td>
<td width="25%" align="center">

##### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_default-arc_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.54.0/unyt_0.54.0_Infrastructure.Marketplace_default-arc_amd64_linux.deb)

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
