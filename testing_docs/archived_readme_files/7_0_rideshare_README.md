# Unyt Tx5 Releases

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox-tx5?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox-tx5/total?style=for-the-badge)

## Intro

Unyt is a Holochain based application for creating p2p credit and payment systems with Smart Agreement functionality.

This release is focused on demonstrating how Unyt could be used to enable multiple regional rideshare groups to operate a single application for managing the pricing and payments for rides across their different cities.

The core of the story is the way in which Unyt's decentralized accounting engine enables different groups, running shared infrastructure to take different inputs like Kilometers and Minutes and transform those into prices according to their own custom price sheets.

We refer to this as multi-unit accounting, as all of these things, the Service Units (KM, Min etc) as well as the Payment (or Base) Units interact in accordance with the Smart Agreements that each group has put in place.

The rideshare side of this demo is just a quick interface that our team whipped together to show what is possible on the payments side. We haven't wired up anything sophisticated in terms of algorithms for logistics and dispatch. In fact, you select your own driver. In a production version of this app, that driver selection -- or perhaps some driver options with pricing and timing and reputation info -- would be shared from the coordination layer. But for this demo version the selection is manual.

## Invitation to Play

Help others book you as a driver by sharing your address with our [riders and drivers signup form](https://forms.gle/KfsN3GzM3Z7V7tbj7). And find others in the [riders and drivers sheet](https://docs.google.com/spreadsheets/d/1aZ_7baIEhOT0jGXRYE9lFje-2hmOL2b62pjzfsPaKiY/edit?usp=sharing).

Note: this is the sign up for Unyt Sandbox Tx5 v.0.42.0. If you are using another app (like a newer or older version, or Circulo), your address won't work here.

For a bit more detail check out the [Pays Well With Others](https://unyt.co/blog/pays-well-with-others/) blog post as well as this [video demo](https://www.youtube.com/watch?v=BezY8h4GZto).

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

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_zero-arc_0.42.0_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_zero-arc_0.42.0_x64_windows.exe)

</td>
<td width="25%" align="center">

#### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_zero-arc_0.42.0_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_zero-arc_0.42.0_x64_darwin.dmg)

</td>
<td width="25%" align="center">

#### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_zero-arc_0.42.0_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_zero-arc_0.42.0_amd64_linux.deb)

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

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_0.42.0_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_0.42.0_x64_windows.exe)

</td>
<td width="25%" align="center">

#### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_0.42.0_aarch64_darwin.dmg)

[Intel (x64)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_0.42.0_x64_darwin.dmg)

</td>
<td width="25%" align="center">

#### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_0.42.0_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox-tx5/releases/download/v0.42.0/Unyt-tx5_0.42.0_amd64_linux.deb)

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
- [Smart Agreement Release v.40 README](./testing_docs/5_0_Smart_Agreements_README.md)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)


## License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file.

Copyright (C) 2024 - 2025, unyt.co
