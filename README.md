# Unyt Tx5 Releases

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox-tx5?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox-tx5/total?style=for-the-badge)

## Intro

Unyt is a Holochain based application for creating p2p credit and payment systems with Smart Agreement functionality.

This version 0.46.0 release is primarily focused on providing support for a billing process that can enable even very low capacity devices to be able to "get credit for their work." 

They don't even have to run the billing app. They just need to be able to create logs documenting the services that they have provided, including any proofs of that work, encrypt and sign the logs and then upload them to a log collector (think of it almost like dropping the logs in a mailbox). From there other devices, even with ordinary consumer grade specs can handle all invoice creation, notifications etc. Customers can pay multiple invoices at once. Service Providers can accept a batch of payments from different customers with a single click.

For a bit more detail check out the [Elegant Billing for the Machine Economy](https://unyt.co/blog/elegant-billing-for-the-machine-economy/) blog post.

Feel free to join the conversation in the Unyt Thread on the [Holochain DEV.HC Discord](https://discord.com/invite/k55DS5dmPH).

The Unyt Channel is here:
https://discordapp.com/channels/919686143581253632/1425157240972902430

How to give yourself access? 
1. Go to the '#👤・5・select-a-role'' Channel
2. Assign yourself the ''Access to: Projects'' role 
3. In the category ''Projects'' go to the channel called ''Unyt"

For those that want to go a bit deeper, we'd like you to test the usability of custom Smart Agreement configurations and system features.

* create and test service units relevant to your network.
* aggregate receives via a Smart Agreement RAVE (e.g. process bulk invoices via a log collector with a single payment)
* aggregate sends via a Smart Agreement RAVE (e.g. collection of transaction fees)


## Downloads 

Select from two versions of apps to download. 
1. The **Full-Arc** verson holds a full copy of the DHT locally, synchronizing all data being published. 
2. The **Zero-Arc** version is lighter weight to run (which will be good for mobile phones, for example) because only holds your own history, and caches some other network data, but some actions will be slower because you'll need to fetch data from peers on the network.

### Zero-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

#### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_zero-arc_0.46.0_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_zero-arc_0.46.0_x64_windows.exe)

</td>
<td width="25%" align="center">

#### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_zero-arc_0.46.0_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_zero-arc_0.46.0_x64_darwin.dmg)

</td>
<td width="25%" align="center">

#### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_zero-arc_0.46.0_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_zero-arc_0.46.0_amd64_linux.deb)

</td>
<!-- 
<td width="25%" align="center">

#### **Android**

---

[APK](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.0.1/app-universal-release.apk)

[AAB Bundle](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.0.1/app-universal-release.aab)

</td> 
-->
</tr>
</table>

</div>

### Full-Arc Releases

<div align="center">

<table>
<tr>
<td width="33%" align="center">

#### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_0.46.0_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_0.46.0_x64_windows.exe)

</td>
<td width="25%" align="center">

#### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_0.46.0_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_0.46.0_x64_darwin.dmg)

</td>
<td width="25%" align="center">

#### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_0.46.0_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.46.0/Unyt-tx5_0.46.0_amd64_linux.deb)

</tr>
</table>
</div>

All available versions can be found in the [Releases](https://github.com/unytco/unyt-sandbox-tx5/releases/)

Once installed, the Unyt software will run locally on your device and connect with others also running the software to operate as a peer-to-peer application.

## Setup

Note: In Mac, because you downloaded the software directly and not through Apple's App Store, you may need to open the System Settings and go to Privacy and Security, scroll down to Security and give Unyt permission to run.

If you want to delete everything and start over with a new account, check out [Starting Fresh](./testing_docs/starting_fresh.md)


When you open Unyt on your operating system for the first time, it will create a set of public and private keys for you that you can use to interact with others. These are stored in a private keystore (Lair) on your own machine and are used during future uses. In Unyt we often refer to this public key as "your address" as it is how others can refer to you when sending, receiving or authorizing you to perform particular roles.

## Related Resources

- [Unyt Setup](./README.md)
- [Detailed Documentation](./testing_docs/5_0_phase_5_testing_details.md)
- [Unyt Dictionary](./testing_docs/4_2_unyt-dictionary.md)
- [The Smart Agreement Overview](./testing_docs/5_0_Smart_Agreement_Release.md)
- [Intro to Smart Agreements (Three Layers)](./testing_docs/4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Smart Agreement Release v.0.40.0 README](./testing_docs/archived_readme_files/5_0_Smart_Agreements_README.md_5_0_Smart_Agreements_README.md)
- [Rideshare Release v.0.42.0 README](./testing_docs/archived_readme_files/7_0_rideshare_README.md)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)


## Development and Testing

For developers working on the codebase, the following environment variables can be used to customize the runtime behavior:

### Persistent Development Mode
By default, development builds on desktop use a temporary directory for Holochain data which is deleted when the app closes. To use the standard app data directory and persist your state across restarts:

```bash
UNYT_PERSISTENT_DEV=true yarn network:tauri
```

### Bypass Lair Password
To skip the Lair keystore password prompt during development (uses an empty password):

```bash
UNYT_BYPASS_PASSWORD=true yarn network:tauri
```


## License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file.

Copyright (C) 2024 - 2025, unyt.co
