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
