# The app on Windows: data locations and a full wipe

The paths below use the names in this repo's `identity.json`: `<identifier>`, `<productName>` and `<mainBinaryName>`. `<major.minor>` is the major and minor version of the installed release, for example `0.110`.

## Where data lives on Windows

| # | Path | What's there | Removed by uninstaller |
|---|------|--------------|------------------------|
| 1 | `%LOCALAPPDATA%\<productName>\` | App binaries (NSIS install only) | Yes (NSIS) |
| 2 | `C:\Program Files\<productName>\` | App binaries (MSI install only) | Yes (MSI) |
| 3 | `%APPDATA%\<identifier>\` | `network_metadata.json`, `joining_agent_key.json`, `log-config.json` | Only if you tick **Delete the application data** (NSIS) |
| 4 | `%LOCALAPPDATA%\<identifier>\` | Rotated `unyt.v*.log.*` in `logs\`, WebView2 data in `EBWebView\`, and in `<major.minor>\holochain\` the conductor databases, Lair keystore, happ bundles and UIs | Only if you tick **Delete the application data** (NSIS) |
| 5 | `%LOCALAPPDATA%\Temp\<identifier>*` | Dev-mode temp dirs | No |

The NSIS uninstaller shows the **Delete the application data** box on its first page. It is off by default. The MSI uninstaller has no such box.

A factory reset must clear items 3 to 5.

## Full wipe, by hand

1. Quit the app. If it still runs, end `<mainBinaryName>.exe` in Task Manager.
2. Uninstall it in *Settings → Apps → `<productName>` → Uninstall*.
3. Delete these folders in File Explorer:
   - `%APPDATA%\<identifier>\`
   - `%LOCALAPPDATA%\<identifier>\`
   - Any `<identifier>*` under `%LOCALAPPDATA%\Temp\`
   - `%LOCALAPPDATA%\<productName>\`, if the uninstaller left it

## Full wipe, in PowerShell

From this repo's root, run:

```powershell
pwsh -File scripts\windows-wipe.ps1
```

The script reads `identifier` and `productName` from `identity.json`. It stops every process that runs from the app's install folders, removes items 1 and 3 to 5, and fails if a folder is still there. It touches nothing unless it can read both names and each is a plain name, so it cannot remove a parent folder that holds another app's data. Add `-WhatIf` to see what it would remove.

On a machine without this repo, copy `scripts\windows-wipe.ps1` to it and give it the two names from `identity.json`:

```powershell
pwsh -File windows-wipe.ps1 -Identifier '<identifier>' -ProductName '<productName>'
```

## Verify

The script fails if any of the app's folders is still there.

## Differences from Linux

- The data is split across `%APPDATA%` (Roaming) and `%LOCALAPPDATA%`. There is no single root.
