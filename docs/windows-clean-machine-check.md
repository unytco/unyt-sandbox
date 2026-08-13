# Windows: the clean-machine check, once per release

Fifteen minutes by hand, per release, on a Windows VM that has never had a build on it.

## Why this is manual

CI covers most of the Windows question already — the `windows` job in [`../.github/workflows/release-smoke.yaml`](../.github/workflows/release-smoke.yaml) installs both artifacts silently, checks the registration, the signature, every DLL the binaries import, and a clean uninstall. [`../scripts/smoke/check-windows.ps1`](../scripts/smoke/check-windows.ps1) carries the reasoning for each check.

What it cannot answer is the question a user actually asks: **does the app start on a machine that has never had a build on it?** GitHub-hosted runners have no Windows Sandbox and do not support nested virtualization, so a pristine-machine check needs self-hosted infrastructure — not worth standing up for one check per release. And a runner is the wrong machine anyway: it is a build image with a decade of redistributables already on it, which is the same reason the Linux lane runs in containers rather than on the runner.

Three failure modes live only here, and all three end with a user seeing nothing at all:

- **The WebView2 runtime is missing.** Tauri loads it through COM, not as a linked import, so nothing in the import check can see it. Windows 11 ships it; a Windows 10 machine may not have it.
- **SmartScreen refuses the download.** Our builds are unsigned (see [`signing.md`](signing.md) — there is an Apple Developer ID and no Windows certificate), so a real user meets an "unknown publisher" block before any of our code runs.
- **A runtime the build machine had and the user does not** — the Visual C++ redistributable being the usual one.

## The procedure

Start from a VM snapshot taken before any Unyt build was ever installed, and roll back to it afterwards. If you are reusing a machine instead, reset it first with [`windows-wipe.md`](windows-wipe.md) — the uninstaller deliberately leaves app data, logs, the Holochain directory and the Lair salt behind, so an uninstall alone does not give you a clean machine.

1. **Copy the installer in.** Take `unyt_<version>_Unyt.Sandbox_default-arc_x64_windows.exe` from the release and copy it to the VM. Do not build on the VM — the artifact under test is the one users download.
2. **Note what SmartScreen does.** Record whether it warns, blocks, or stays quiet, and how many clicks it takes to proceed. This is the user's first impression and it changes the day the installer is signed.
3. **Install by double-clicking**, the way a user would — not with `/S`. CI already covers the silent path.
4. **Launch it.** Watch for a window, then for the window to paint. A window that opens black is a UI-bundle failure, not a slow start.
5. **Read the log.** There is no console — release builds set `windows_subsystem = "windows"`, so redirected output is empty. The log is at `%LOCALAPPDATA%\co.unyt.unyt.sandbox\logs\unyt.v*.log.*`:

   ```powershell
   Get-Content (Get-ChildItem "$env:LOCALAPPDATA\co.unyt.unyt.sandbox\logs\unyt.v*.log.*" |
     Sort-Object LastWriteTime | Select-Object -Last 1) -Tail 80
   ```

   A healthy first run reaches one of the states [`../scripts/smoke/common.sh`](../scripts/smoke/common.sh) accepts — that file is the authority on which states are healthy and why, and the Linux lane gates on the same set. Leave it running long enough to outlast a conductor-heartbeat retry.
6. **Uninstall** via *Settings → Apps → Unyt Sandbox*, and confirm the program is gone.
7. **Roll the VM back** to the snapshot.

## What to record

In the release thread: the Windows build tested, the OS version of the VM, what SmartScreen did, whether the app reached a healthy state, and anything that needed a click a user would not know to make. A pass is worth one line; a failure is worth the log.

If the same failure shows up twice, it belongs in CI instead — say so rather than repeating the ritual.
