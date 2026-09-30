# Unyt on Windows: Data Locations & Full Wipe

Identifier: `co.unyt.unyt-app` · Product: `Unyt` · Version segment: `0.88` (major.minor of `CARGO_PKG_VERSION`).

## Where data lives on Windows

| # | Path | What's there | Removed by uninstaller |
|---|------|--------------|------------------------|
| 1 | `%LOCALAPPDATA%\Unyt\` | App binaries + `EBWebView\` (WebView2 cache) | Yes (NSIS) |
| 2 | `C:\Program Files\Unyt\` | App binaries (MSI install only) | Yes (MSI) |
| 3 | `%APPDATA%\co.unyt.unyt-app\` | `network_metadata.json`, `log-config.json`, Stronghold `.hold` | No |
| 4 | `%LOCALAPPDATA%\co.unyt.unyt-app\logs\` | Rotated `unyt.v*.log.*` | No |
| 5 | `%APPDATA%\zo-el <joelulahanna@gmail.com>\co.unyt.unyt-app\0.88\holochain\` | Conductor DBs, Lair keystore, happ bundles, UIs | No |
| 6 | `%LOCALAPPDATA%\Temp\co.unyt.unyt-app*` | Dev-mode temp dirs | No |
| 7 | Windows Credential Manager → target `co.unyt.unyt-app`, user `lair-salt` | Lair password salt | No |

Items 3–7 are what a factory reset must clear.

## Full wipe — steps

1. Quit the app. Kill `unyt-app.exe`, `lair-keystore.exe`, `holochain.exe` in Task Manager if still running.
2. Uninstall via *Settings → Apps → Unyt → Uninstall*.
3. Delete these folders in File Explorer:
   - `%APPDATA%\co.unyt.unyt-app\`
   - `%LOCALAPPDATA%\co.unyt.unyt-app\`
   - `%APPDATA%\zo-el <joelulahanna@gmail.com>\co.unyt.unyt-app\`
   - Any `co.unyt.unyt-app*` under `%LOCALAPPDATA%\Temp\`
   - `%LOCALAPPDATA%\Unyt\EBWebView\` if uninstall left it
4. Open *Control Panel → Credential Manager → Windows Credentials*, find the Generic Credential with target `co.unyt.unyt-app` (user `lair-salt`) → **Remove**.

## Full wipe — PowerShell one-shot

```powershell
Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessName -in @('unyt-app','lair-keystore','holochain') } |
  Stop-Process -Force

Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Unyt"             -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:APPDATA\co.unyt.unyt-app"       -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\co.unyt.unyt-app"  -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath "$env:APPDATA\zo-el <joelulahanna@gmail.com>\co.unyt.unyt-app" -ErrorAction SilentlyContinue

Get-ChildItem "$env:LOCALAPPDATA\Temp" -Directory -Filter 'co.unyt.unyt-app*' -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

cmdkey /delete:co.unyt.unyt-app 2>$null
```

## Verify

All four must print `False`, and `cmdkey /list` must say "not found":

```powershell
Test-Path "$env:LOCALAPPDATA\Unyt"
Test-Path "$env:APPDATA\co.unyt.unyt-app"
Test-Path "$env:LOCALAPPDATA\co.unyt.unyt-app"
Test-Path "$env:APPDATA\zo-el <joelulahanna@gmail.com>\co.unyt.unyt-app"
cmdkey /list:co.unyt.unyt-app
```

## Gotchas vs Linux

- Data split across `%APPDATA%` (Roaming) and `%LOCALAPPDATA%` — no single root.
- Holochain data lives under the **Cargo `authors`** folder (`zo-el <joelulahanna@gmail.com>\…`), not the identifier folder. Easy to miss.
- Lair salt is in **Windows Credential Manager**, not on disk. Skipping it causes unlock errors on the next install.
