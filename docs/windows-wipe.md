# The app on Windows: data locations and a full wipe

The paths below use the names in this repo's `identity.json`: `<identifier>`, `<productName>` and `<mainBinaryName>`. `<major.minor>` is the major and minor version of the installed release, for example `0.110`.

## Where data lives on Windows

| # | Path | What's there | Removed by uninstaller |
|---|------|--------------|------------------------|
| 1 | `%LOCALAPPDATA%\<productName>\` | App binaries + `EBWebView\` (WebView2 cache) | Yes (NSIS) |
| 2 | `C:\Program Files\<productName>\` | App binaries (MSI install only) | Yes (MSI) |
| 3 | `%APPDATA%\<identifier>\` | `network_metadata.json`, `log-config.json`, Stronghold `.hold` | No |
| 4 | `%LOCALAPPDATA%\<identifier>\logs\` | Rotated `unyt.v*.log.*` | No |
| 5 | `%APPDATA%\zo-el <joelulahanna@gmail.com>\<identifier>\<major.minor>\holochain\` | Conductor DBs, Lair keystore, happ bundles, UIs | No |
| 6 | `%LOCALAPPDATA%\Temp\<identifier>*` | Dev-mode temp dirs | No |
| 7 | Windows Credential Manager, target `<identifier>`, user `lair-salt` | Lair password salt | No |

A factory reset must clear items 3 to 7.

## Full wipe, by hand

1. Quit the app. If they still run, end `<mainBinaryName>.exe`, `lair-keystore.exe` and `holochain.exe` in Task Manager.
2. Uninstall it in *Settings → Apps → `<productName>` → Uninstall*.
3. Delete these folders in File Explorer:
   - `%APPDATA%\<identifier>\`
   - `%LOCALAPPDATA%\<identifier>\`
   - `%APPDATA%\zo-el <joelulahanna@gmail.com>\<identifier>\`
   - Any `<identifier>*` under `%LOCALAPPDATA%\Temp\`
   - `%LOCALAPPDATA%\<productName>\EBWebView\`, if the uninstaller left it
4. Open *Control Panel → Credential Manager → Windows Credentials*. Find the Generic Credential with target `<identifier>` (user `lair-salt`) and click **Remove**.

## Full wipe, in PowerShell

From this repo's root, run:

```powershell
pwsh -File scripts\windows-wipe.ps1
```

The script reads `identifier` and `productName` from `identity.json`. It stops every process that runs from the app's install folders, removes items 1 and 3 to 7, and fails if a folder is still there. It touches nothing unless it can read both names and each is a plain name, so it cannot remove a parent folder that holds another app's data. Add `-WhatIf` to see what it would remove.

On a machine without this repo, copy `scripts\windows-wipe.ps1` to it and give it the two names from `identity.json`:

```powershell
pwsh -File windows-wipe.ps1 -Identifier '<identifier>' -ProductName '<productName>'
```

## Verify

The script fails if any of the app's folders is still there. Then `cmdkey /list:<identifier>` must say "not found".

## Differences from Linux

- The data is split across `%APPDATA%` (Roaming) and `%LOCALAPPDATA%`. There is no single root.
- The Holochain data lives under a folder named for the app's **Cargo `authors`** (`zo-el <joelulahanna@gmail.com>\…`), not under the identifier folder. It is easy to miss.
- The Lair salt is in **Windows Credential Manager**, not on disk. If you skip it, the next install fails to unlock.
