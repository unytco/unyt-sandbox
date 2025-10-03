# Unyt Releases

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox/total?style=for-the-badge)

## Intro

Unyt is a Holochain based application for creating agent-centric, peer-to-peer, Mutual Credit accounting systems with smart contract like functionality.

We are working with potential partner projects like yours as we build out this software to ensure that it meets the needs of your team as well as your community of users.

## Overview

This [Test Plan](./1_0_testing_plan.md) document gives a bit of a overview of the sorts of UX / UI feedback that we are seeking at present.

## Downloads Zero Arc releases

<div align="center">

<table>
<tr>
<td width="25%" align="center">

### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_zero-arc_0.39.0_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_zero-arc_0.39.0_x64_windows.exe)

</td>
<td width="25%" align="center">

### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_zero-arc_0.39.0_aarch64_darwin)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_zero-arc_0.39.0_x64_darwin.dmg)

</td>
<td width="25%" align="center">

### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_zero-arc_0.39.0_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_zero-arc_0.39.0_amd64_linux.deb)

</td>
<!--
 <td width="25%" align="center">

### **Android**

---

[APK](https://github.com/unytco/unyt-sandbox/releases/download/v0.0.1/app-universal-release.apk)

[AAB Bundle](https://github.com/unytco/unyt-sandbox/releases/download/v0.0.1/app-universal-release.aab)

</td> 
-->
</tr>
</table>

</div>

## Download Full Arc releases

<div align="center">

<table>
<tr>
<td width="25%" align="center">

### **Windows**

---

[MSI Installer (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_0.39.0_x64_windows.msi)

[EXE Setup (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_0.39.0_x64_windows.exe)

</td>
<td width="25%" align="center">

### **MacOS**

---

[Silicon (arm64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_0.39.0_aarch64_darwin)

[Intel (x64)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_0.39.0_x64_darwin.dmg)

</td>
<td width="25%" align="center">

### **Linux**

---

[AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_0.39.0_amd64_linux.AppImage)

[Debian (.deb)](https://github.com/unytco/unyt-sandbox/releases/download/v0.39.0/Unyt_0.39.0_amd64_linux.deb)

</tr>
</table>

</div>

All available versions can be found in the [Releases](https://github.com/unytco/unyt-sandbox/releases/)

Once installed, the Unyt software will run locally on your device and connect with others also running the software to operate as a peer-to-peer application.

## Setup

Note: The release for your operating system may not be code signed yet, so you may need to right click to open the file. In Mac, because you downloaded the software directly and not through Apple's App Store, you may need to open the System Settings and go to Privacy and Security, scroll down to Security and give Unyt permission to run.

When you open Unyt on your operating system for the first time, it will create a set of public and private keys for you that you can use to interact with others. These are stored in a private keystore (Lair) on your own machine and are used during future uses.

To get started, you can try sending, executing, and receiving transactions with friends that have also downloaded Unyt.

## Starting Fresh

Details on removal and reinstallation.

If you want to start fresh (for whatever reason), uninstall the old version and then reinstall again. On Mac, you may also need to delete your local data.

Here are the steps for Uninstalling, Deleting Local Data and Reinstalling the app on a Mac:

1. Close the app.

2. Delete the Unyt file from your applications folder.

3. Open the Terminal application
4. In Terminal, type the following two commands and hit enter after each:

```
cd ~/Library/Application\ Support
```

```
rm -rf co.unyt.unyt
```

That co.unyt.unyt file had your local data in it. The second command should delete it.

Now that it is deleted, you can again install Unyt and start fresh with a new account.

Next, dive into the [Test Plan](./1_0_testing_plan.md).

## Related docs

- [Test Plan](./testing_docs/1_0_testing_plan.md)
- [Unyt Setup](./README.md)
- [Testing Documentation, Phase 4](./testing_docs/4_0_phase_4_testing_details.md)
- [Unyt Dictionary](./testing_docs/4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](./testing_docs/4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)

## License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file.

Copyright (C) 2024 - 2025, unyt.co
