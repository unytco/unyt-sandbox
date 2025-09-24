# Unyt Releases

![GitHub release (latest by date)](https://img.shields.io/github/v/release/unytco/unyt-sandbox?style=for-the-badge)
![GitHub All Releases](https://img.shields.io/github/downloads/unytco/unyt-sandbox/total?style=for-the-badge)

## Related docs

- [Test Plan](./testing_docs/1_0_testing_plan.md)
- [Unyt Setup](./README.md)
- [Testing Documentation, Phase 4](./testing_docs/4_0_phase_4_testing_details.md)
- [Unyt Dictionary](./testing_docs/4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](./testing_docs/4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)

## Intro

Unyt is a Holochain based application for creating agent-centric, peer-to-peer, Mutual Credit accounting systems with smart contract like functionality.

We are working with potential partner projects like yours as we build out this software to ensure that it meets the needs of your team as well as your community of users.

## Overview

This [Test Plan](./1_0_testing_plan.md) document gives a bit of a overview of the sorts of UX / UI feedback that we are seeking at present.

## Installation

Download the appropriate version for your system.

| Releases                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------- |
| [macOS x64 (Intel)](https://github.com/unytco/unyt-sandbox/releases/download/v0.36.0/Unyt_0.36.0_x64.dmg)                       |
| [macOS arm64 (Silicon)](https://github.com/unytco/unyt-sandbox/releases/download/v0.36.0/Unyt_0.36.0_aarch64.dmg)               |
| [Linux Debian](https://github.com/unytco/unyt-sandbox/releases/download/v0.36.0/Unyt_0.36.0_amd64.deb) (recommended)            |
| [Linux AppImage](https://github.com/unytco/unyt-sandbox/releases/download/v0.36.0/Unyt_0.36.0_amd64.AppImage) (read note below) |
| [Windows](https://github.com/unytco/unyt-sandbox/releases/download/v0.36.0/Unyt_0.36.0_x64-setup.exe)                           |
| [Android](#) (no release available)                                                                                             |
| [iOS](#) (no release available)                                                                                                 |

> [!IMPORTANT]
> If you encounter sandbox-related issues, you can try running the AppImage with:
>
> ```bash
> ELECTRON_DISABLE_SANDBOX=1 ./unyt.AppImage
> ```
>
> This is automatically configured in the latest version, but might be needed for manual execution in some cases.

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

## License

[![License: CAL 1.0](https://img.shields.io/badge/License-CAL%201.0-blue.svg)](https://github.com/holochain/cryptographic-autonomy-license)

Copyright (C) 2024 - 2025, unyt.co


# Unyt Sandbox

This repo is the packaging we use to create a release of the Unyt App.
It generates a release for Mac, Windows and Linux desktop app. It is also configured to generate Android releases

To generate your own unyt alliance, you can either clone this repo and generate your own release with your own branding and new hashspace.

## Create your own unyt alliance

- Fork this repo and rename it to the your alliance name (Eg: `Circulo`)
- Clone your fork locally
- Suggestion: Create a `develop` branch and set it to default on which you would make updates so that you can keep the other branch in sync with the original repo in case you want to keep your work in sync with root repo and all of your latest updates. (Follow any patter that suits your needs)
- Update the [tauri.config.json](./src-tauri/tauri.conf.json)
  - `version`: this will be the version for your release
  - `productName`: Name of your Alliance of the name of th app you have decided
  - `identifier`: This will be your app id
  - `plugins.updater.pubkey`: This is the pub-key that you will need to generate for tauri signing [read more](./docs/signing.md)
  - `plugins.updater.endpoints`: update the repo name
  - `deep-link`: scheme to your app name
- Update the [Cargo.toml](./src-tauri/Cargo.toml)
  - `package.version`: the same version as above
  - `package.name`: This would be the app name
- Update Icon
  - Delete the icon folder
  - you need to run `yarn tauri icon <PATH_TO_THE_ICON_PNG_FILE>` before running those commands
- Update the crates [app-config.rs](./src-tauri/src/app_config.rs)
  - Update the `IDENTIFIER_DIR` and `APP_ID_PREFIX`
- Update the release workflow
  - assetNamePattern: change the file name to the app name you'd like it to be
  - under `create-release`: change the name to the app name you'd like it to be
- Update Android release:
  - delete [this folder](./src-tauri/gen/android/)
  - enter nix: `nix develop .#andriodDev`
  - Follow these steps [in the darksoil docs here](https://darksoil.studio/p2p-shipyard/guides/android/project-setup.html)

## Test development

### Setup

- Enter `nix develop`
- install dependancies: `make install`
- setup: `make setup`

### Test desktop

`make launch`

### Test Andriod:

There are presetup steps for android that you can read about [here](https://darksoil.studio/p2p-shipyard/guides/android/device-setup.html)

You will need to launch the desktop app `make launch`
And in a different terminal run (This will setup the android build)
enter `nix develop .#androidDev`
then
`make launch-android`

## Self maintain shipyard

> Always refer to darksoil documentation

If you'd like to maintain your own release without needing to keep it in track with the root repo you can directly update shipyard

- For this you can just run `cargo update`
- There is a bug that this introduces for the andriod release so you would need to run `cargo update wasmer-middlewares --precise 6.0.1`
