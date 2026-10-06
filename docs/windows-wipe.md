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

Read the three names from `identity.json` first. On a machine without this repo, type the three values from it instead.

```powershell
$app = Get-Content .\identity.json -Raw | ConvertFrom-Json
$id, $product, $binary = $app.identifier, $app.productName, $app.mainBinaryName
```

Then run:

```powershell
Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessName -in @($binary, 'lair-keystore', 'holochain') } |
  Stop-Process -Force

Remove-Item -Recurse -Force -LiteralPath "$env:LOCALAPPDATA\$product" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath "$env:APPDATA\$id" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath "$env:LOCALAPPDATA\$id" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath "$env:APPDATA\zo-el <joelulahanna@gmail.com>\$id" -ErrorAction SilentlyContinue

Get-ChildItem "$env:LOCALAPPDATA\Temp" -Directory -Filter "$id*" -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

cmdkey /delete:$id 2>$null
```

## Verify

All four lines must print `False`, and `cmdkey /list` must say "not found":

```powershell
Test-Path -LiteralPath "$env:LOCALAPPDATA\$product"
Test-Path -LiteralPath "$env:APPDATA\$id"
Test-Path -LiteralPath "$env:LOCALAPPDATA\$id"
Test-Path -LiteralPath "$env:APPDATA\zo-el <joelulahanna@gmail.com>\$id"
cmdkey /list:$id
```

## Differences from Linux

- The data is split across `%APPDATA%` (Roaming) and `%LOCALAPPDATA%`. There is no single root.
- The Holochain data lives under a folder named for the app's **Cargo `authors`** (`zo-el <joelulahanna@gmail.com>\…`), not under the identifier folder. It is easy to miss.
- The Lair salt is in **Windows Credential Manager**, not on disk. If you skip it, the next install fails to unlock.
