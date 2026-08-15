<#
.SYNOPSIS
  Does the released Windows build put a visible first screen on screen?

.DESCRIPTION
  prove-windows.ps1 -Artifact <installer.exe> -Shots <dir>

  TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.

  WINDOWS POWERSHELL 5.1, not pwsh: System.Drawing belongs to the .NET Framework
  and is NOT in PowerShell 7's shared framework, so the capture below only exists
  under powershell.exe. Nothing here may use PS7-only syntax (`?:`, `??`).

  The negative control, the watch loop and the verdict are a second
  implementation of proving-common.sh — the same split the smoke already lives
  with between check-macos.sh and check-windows.ps1. THE LOG PATTERNS ARE NOT
  DUPLICATED: they are read out of the shell files at runtime, so a pattern that
  moves there turns this red instead of quietly matching nothing.

  Two captures per frame, because either can be the one that works on a runner.
  They are NOT equal evidence: PrintWindow with PW_RENDERFULLCONTENT asks the
  window to render ITSELF (the flag exists for DirectComposition content, which
  is what WebView2 draws into), so what it returns is the app whatever is in
  front of it — that one decides. CopyFromScreen reads the DESKTOP at the
  window's coordinates, so it is only evidence when PrintWindow gave us nothing,
  and context otherwise.

  Two pre-launch controls for the same reason: the whole desktop answers "is this
  runner's screen mistakable for the app", but the fallback frame is an 800x800
  sub-rect of that desktop, and a sub-rect can clear a threshold the whole screen
  does not. So the second control is the splash's own footprint.

  Exit: 0 proven · 1 not proven · 2 cannot prove · 3 the capture path cannot be
  trusted. Only 0 is a pass, and none of the others is a skip.

.PARAMETER Artifact
  The NSIS installer (.exe).

.PARAMETER Shots
  Directory to write frames into; verdict\ is analysed, context\ is uploaded only.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Artifact,
  [Parameter(Mandatory)][string]$Shots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Label = "windows/$([System.IO.Path]::GetFileName($Artifact))"
$Root = Split-Path -Parent $PSCommandPath
$Analyser = Join-Path $Root 'screenshot-stats.py'
$BundleId = 'co.unyt.unyt.sandbox'

# POLLED, NEVER SLEPT: WebView2 cold-start times vary several-fold between runs
# on the same runner, so any fixed wait is either a flake or a waste.
$PollSeconds = 2
$MaxShots = 24
# -Force skips the ordinary budget, not this: the frames from the moment the
# state is reached are the ones worth having, but a run that photographed forever
# would upload an artifact nobody opens.
$HardMaxShots = 40
$TimeoutSeconds = 240
$PostSeconds = 30

function Write-Note { param([string]$Message) [Console]::Error.WriteLine($Message) }

function Exit-With {
  param([string]$Verdict, [string]$Why, [int]$Code)
  Write-Output "VERDICT ${Label}: $Verdict — $Why"
  exit $Code
}

# EVERY PATH OUT OF THIS SCRIPT SAYS SOMETHING. $ErrorActionPreference is 'Stop'
# so a broken step cannot be walked past — but a bare stack trace on the run page
# is a job that answered nothing, and this lane exists because runs were passing
# without answering.
trap {
  Write-Note "::error::$($_.Exception.Message)"
  Write-Note ($_.ScriptStackTrace)
  Write-Output "VERDICT ${Label}: CANNOT PROVE — this lane failed before it could answer: $($_.Exception.Message)"
  exit 2
}

# ── the log patterns, read from their one home ────────────────────────────────
# `NAME='<ere>'` in the shell files. Bash EREs and .NET regexes agree on
# everything these use (alternation, `.*`, `\{`, `\b`), so they are applied
# verbatim rather than translated.
function Get-ShellPattern {
  param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Name)
  $line = Select-String -LiteralPath $File -Pattern "^$Name='(.*)'$" | Select-Object -First 1
  if (-not $line) {
    Write-Note "::error::$Name is not in $File — the log oracle moved and this lane would match nothing"
    Exit-With -Verdict 'CANNOT PROVE' -Why "the log pattern $Name could not be read from $File" -Code 2
  }
  return $line.Matches[0].Groups[1].Value
}

$smokeCommon = Join-Path (Split-Path -Parent $Root) 'common.sh'
$provingCommon = Join-Path $Root 'proving-common.sh'
$ReBackendReady = Get-ShellPattern -File $smokeCommon -Name 'UNYT_RE_BACKEND_READY'
$ReFailed = Get-ShellPattern -File $smokeCommon -Name 'UNYT_RE_FAILED'
$ReAwaiting = Get-ShellPattern -File $provingCommon -Name 'UNYT_RE_AWAITING_PASSWORD'

# ── capture ───────────────────────────────────────────────────────────────────
# Loaded first and referenced BY ITS ACTUAL LOCATION: a partial assembly name is
# resolved out of the GAC, which is one more thing that can be missing on a
# runner and would fail as an unexplained compile error.
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies ([System.Drawing.Bitmap].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class UnytShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] private static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder info, int len, out int needed);
  [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

  private delegate bool EnumProc(IntPtr h, IntPtr p);

  // Which window station this process runs on. "WinSta0" is the interactive one;
  // anything else has no visible desktop, so a GUI app can put nothing on screen.
  public static string WindowStation() {
    StringBuilder sb = new StringBuilder(256);
    int needed;
    if (!GetUserObjectInformationW(GetProcessWindowStation(), 2 /* UOI_NAME */, sb, sb.Capacity * 2, out needed)) {
      return "<unavailable>";
    }
    return sb.ToString();
  }

  // "<hwnd> <x> <y> <w> <h> <title>" per visible top-level window of one process.
  // The delegate is held in a local for the duration of the call: handed to
  // EnumWindows as a temporary, nothing roots it and a collection mid-enumeration
  // would take the callback with it.
  public static string[] Windows(int pid) {
    List<string> found = new List<string>();
    EnumProc callback = delegate(IntPtr h, IntPtr p) {
      uint owner;
      GetWindowThreadProcessId(h, out owner);
      if (owner != (uint)pid) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      StringBuilder sb = new StringBuilder(512);
      GetWindowTextW(h, sb, sb.Capacity);
      found.Add(string.Format("{0} {1} {2} {3} {4} {5}",
        h.ToInt64(), r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, sb.ToString()));
      return true;
    };
    EnumWindows(callback, IntPtr.Zero);
    GC.KeepAlive(callback);
    return found.ToArray();
  }

  // PW_RENDERFULLCONTENT (0x2): added for DirectComposition-rendered windows,
  // which is what a WebView2 surface is. Without it the webview area comes back
  // empty even when the app is painting perfectly.
  public static bool CapturePrintWindow(long hwnd, string path) {
    IntPtr h = new IntPtr(hwnd);
    RECT r;
    if (!GetWindowRect(h, out r)) return false;
    int w = r.Right - r.Left, ht = r.Bottom - r.Top;
    if (w <= 0 || ht <= 0) return false;
    using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        IntPtr hdc = g.GetHdc();
        bool ok = PrintWindow(h, hdc, 2);
        g.ReleaseHdc(hdc);
        if (!ok) return false;
      }
      bmp.Save(path, ImageFormat.Png);
    }
    return true;
  }

  public static bool CaptureWindowFromScreen(long hwnd, string path) {
    IntPtr h = new IntPtr(hwnd);
    RECT r;
    if (!GetWindowRect(h, out r)) return false;
    return CaptureRect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, path);
  }

  // SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN / SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN.
  public static bool CaptureVirtualScreen(string path) {
    return CaptureRect(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79), path);
  }

  // The footprint a centred window of this size would occupy, on the primary
  // screen (SM_CXSCREEN / SM_CYSCREEN). The second negative control: a sub-rect
  // of a desktop can pass thresholds the whole desktop does not.
  public static bool CaptureCentredRect(int w, int h, string path) {
    int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
    if (sw <= 0 || sh <= 0) return false;
    return CaptureRect(Math.Max(0, (sw - w) / 2), Math.Max(0, (sh - h) / 2), Math.Min(w, sw), Math.Min(h, sh), path);
  }

  private static bool CaptureRect(int x, int y, int w, int h, string path) {
    if (w <= 0 || h <= 0) return false;
    using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
      }
      bmp.Save(path, ImageFormat.Png);
    }
    return true;
  }
}
'@

# A native command's stderr becomes an ErrorRecord, which under 'Stop' would
# terminate the script instead of being read as output.
function Invoke-Analyser {
  param([string[]]$Paths, [switch]$Control)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $argv = @()
    if ($Control) { $argv += '--control' }
    $argv += $Paths
    $lines = @(& $python $Analyser @argv 2>&1 | ForEach-Object { "$_" })
    return [PSCustomObject]@{ Lines = $lines; Code = $LASTEXITCODE }
  }
  finally { $ErrorActionPreference = $previous }
}

# ── is there a desktop at all? ────────────────────────────────────────────────
# ASKED FIRST, and loudly. A runner whose agent sits on a non-interactive window
# station has no visible desktop, and every frame would be black for a reason
# that has nothing to do with the artifact.
$station = [UnytShot]::WindowStation()
Write-Note "window station: $station"
if ($station -ne 'WinSta0') {
  Write-Note "::error title=No interactive desktop on this runner::the process is on window station '$station', not WinSta0"
  Exit-With -Verdict 'CANNOT PROVE' -Why "this runner has no interactive window station ('$station'), so no application can put anything on a screen here" -Code 2
}

$python = $null
foreach ($candidate in @('python', 'python3', 'py')) {
  if (Get-Command $candidate -ErrorAction SilentlyContinue) { $python = $candidate; break }
}
if (-not $python) {
  Exit-With -Verdict 'CANNOT PROVE' -Why 'no python on PATH, so no frame could be analysed' -Code 2
}

$verdictDir = Join-Path $Shots 'verdict'
$contextDir = Join-Path $Shots 'context'
# CLEARED, not just created: the verdict passes if ANY frame is the app's, so a
# frame an earlier run left here would prove this artifact with the last one's
# screenshot. A GitHub runner is fresh; a re-run on a developer's box is not.
Remove-Item -Recurse -Force -LiteralPath $verdictDir, $contextDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $verdictDir -Force | Out-Null
New-Item -ItemType Directory -Path $contextDir -Force | Out-Null

# ── the negative control, before anything is installed ────────────────────────
# A capture that photographs the desktop while the app does not exist would
# photograph the desktop when it does, and every verdict after that would be
# void. Kept out of verdict\ on purpose: it is evidence about the RUNNER.
# TWO controls, not one. The whole desktop answers "is this runner's screen
# mistakable for the app", but the fallback frame is an 800x800 sub-rect of that
# desktop — and a sub-rect can clear the thresholds while the whole screen does
# not. So the second control is the splash's own footprint, centred where a
# centred window lands.
$controls = @(
  @{ Path = (Join-Path $contextDir '00-control-desktop.png'); Taken = [UnytShot]::CaptureVirtualScreen((Join-Path $contextDir '00-control-desktop.png')) },
  @{ Path = (Join-Path $contextDir '00-control-splash-rect.png'); Taken = [UnytShot]::CaptureCentredRect(800, 800, (Join-Path $contextDir '00-control-splash-rect.png')) }
)
if (-not ($controls | Where-Object { $_.Taken })) {
  Exit-With -Verdict 'CANNOT PROVE' -Why 'nothing could be captured on this runner even before the app was started' -Code 2
}
foreach ($c in $controls) {
  if (-not $c.Taken) { continue }
  $control = Invoke-Analyser -Paths @($c.Path) -Control
  $control.Lines | ForEach-Object { Write-Note $_ }
  if ($control.Code -eq 5) {
    Write-Note '::error title=The capture path cannot be trusted::a frame taken BEFORE the app was launched already passes for the app'
    Exit-With -Verdict 'UNTRUSTED' -Why "a frame captured before the app was even launched already scores as the app ($([System.IO.Path]::GetFileName($c.Path))), so this capture path cannot answer the question" -Code 3
  }
  if ($control.Code -ne 0) {
    Exit-With -Verdict 'CANNOT PROVE' -Why "a pre-launch control frame could not be read (analyser exit $($control.Code)), so the capture path is unusable" -Code 2
  }
}
Write-Note 'OK: neither pre-launch frame passes for the app, so a later one that does means the app'

# ── the data root ─────────────────────────────────────────────────────────────
# NOT REDIRECTED, because it cannot be: tauri resolves it through
# SHGetKnownFolderPath, which reads the user's profile and ignores %LOCALAPPDATA%.
# The throwaway runner is the sandbox instead — so its cleanliness is MEASURED
# here rather than assumed, since a warm start would exercise a different path
# than the one a user's first install takes.
$dataRoot = Join-Path $env:LOCALAPPDATA $BundleId
if (Test-Path -LiteralPath $dataRoot) {
  Write-Note "::error::$dataRoot already exists, so this runner has run the app before"
  Exit-With -Verdict 'CANNOT PROVE' -Why "the runner's app-data directory is not clean, so this would not be a first-install launch" -Code 2
}
$logDir = Join-Path $dataRoot 'logs'

# ── install the way a user would ──────────────────────────────────────────────
$uninstallRoots = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
function Get-Entries {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($root in $uninstallRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
      if (-not $p) { continue }
      $name = $null
      $loc = $null
      if ($p.PSObject.Properties.Name -contains 'DisplayName') { $name = $p.DisplayName }
      if ($p.PSObject.Properties.Name -contains 'InstallLocation') { $loc = $p.InstallLocation }
      $out.Add([PSCustomObject]@{ KeyPath = $key.PSPath; DisplayName = $name; InstallLocation = $loc })
    }
  }
  return $out.ToArray()
}

$before = @(Get-Entries | ForEach-Object { $_.KeyPath })
# UPPERCASE /S — NSIS's silent switch is case-sensitive, and /s runs the
# installer interactively and hangs on its dialog.
$installer = Start-Process -FilePath $Artifact -ArgumentList '/S' -PassThru -Wait:$false
if (-not $installer.WaitForExit(300 * 1000)) {
  try { $installer.Kill() } catch { Write-Note "  (could not kill the installer: $($_.Exception.Message))" }
  Exit-With -Verdict 'NOT PROVEN' -Why 'the installer never finished, so it was waiting for input' -Code 1
}
if ($installer.ExitCode -ne 0) {
  Exit-With -Verdict 'NOT PROVEN' -Why "the installer exited $($installer.ExitCode), so nothing was installed" -Code 1
}

$new = @(Get-Entries | Where-Object { $before -notcontains $_.KeyPath })
$entry = @($new | Where-Object { $_.DisplayName -like '*Unyt*' }) | Select-Object -First 1
if (-not $entry) { $entry = @($new) | Select-Object -First 1 }
if (-not $entry -or -not $entry.InstallLocation) {
  Exit-With -Verdict 'NOT PROVEN' -Why 'the install registered no uninstall entry with an install location, so the program could not be found' -Code 1
}
# NSIS writes the value quoted; verbatim it fails every Test-Path.
$installDir = $entry.InstallLocation.Trim().Trim('"').TrimEnd('\', '/')
Write-Note "installed $($entry.DisplayName) -> $installDir"

# The app, not the uninstaller: NSIS drops both under the same directory.
$exe = @(Get-ChildItem -LiteralPath $installDir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike 'uninstall*' } |
    Sort-Object Length -Descending) | Select-Object -First 1
if (-not $exe) {
  Exit-With -Verdict 'NOT PROVEN' -Why "the installer registered itself but put no program under $installDir" -Code 1
}
Write-Note "launching $($exe.FullName)"

# ── launch ────────────────────────────────────────────────────────────────────
$env:RUST_LOG = 'info'
# A runner has no GPU and WebView2's default compositing path draws nothing on
# one. The software rasterizer is deliberately left ENABLED — disabling it as
# well is what turns "no GPU" into "no pixels".
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--disable-gpu --disable-gpu-compositing'
# DELIBERATELY NOT SET: UNYT_BYPASS_PASSWORD. Parking at LairAwaitingPassword with
# the prompt on screen is exactly what this proves. Nor AGENT_ID, which the Linux
# lane sets only to keep the single-instance plugin out of the way — this runner
# has never run the app, so there is no first instance to be focused instead.
# CAPTURED EVEN THOUGH THE RELEASE BUILD HAS NO CONSOLE. windows_subsystem =
# "windows" means nothing reaches a terminal, but a Rust panic before tracing is
# initialised still writes to stderr — and redirected, that is the difference
# between a diagnosable crash and "the app never reached any state".
$appStdout = Join-Path $Shots 'app-stdout.log'
$appStderr = Join-Path $Shots 'app-stderr.log'

# An app that will not start is a finding about the artifact, not a broken lane,
# so it does not go to the trap's CANNOT PROVE.
try {
  $app = Start-Process -FilePath $exe.FullName -WorkingDirectory $installDir -PassThru `
    -RedirectStandardOutput $appStdout -RedirectStandardError $appStderr
}
catch {
  Exit-With -Verdict 'NOT PROVEN' -Why "the installed program would not start: $($_.Exception.Message)" -Code 1
}

# Both sinks, as the other two lanes do: the rolling log file is durable, and the
# redirected streams catch a crash that happens before the log dir exists.
function Get-AppLog {
  $parts = New-Object System.Collections.Generic.List[string]
  $files = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($appStdout, $appStderr)) { if (Test-Path -LiteralPath $p) { $files.Add($p) } }
  if (Test-Path -LiteralPath $logDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $logDir -Filter 'unyt.v*.log.*' -ErrorAction SilentlyContinue)) {
      $files.Add($f.FullName)
    }
  }
  foreach ($f in $files) {
    # NEVER an empty catch: an unreadable log is why this lane would then report
    # "the app never reached any state", which would be a false statement about
    # the artifact rather than about the file we could not open.
    try { $parts.Add((Get-Content -LiteralPath $f -Raw -ErrorAction Stop)) }
    catch { Write-Note "::warning::could not read $f — $($_.Exception.Message)" }
  }
  return ($parts -join "`n")
}

# The largest visible top-level window the app owns: a tooltip is also a window,
# and a frame of one would be a true picture of the wrong thing.
function Get-AppWindow {
  $best = $null
  $bestArea = 0
  foreach ($line in [UnytShot]::Windows($app.Id)) {
    $f = $line.Split(' ')
    if ($f.Count -lt 5) { continue }
    $area = [int]$f[3] * [int]$f[4]
    if ($area -gt $bestArea) { $bestArea = $area; $best = $line }
  }
  return $best
}

$shotCount = 0
$captureFailures = 0
$sawWindow = $false
$painted = ''

# Analysed as it is taken, so the loop stops the moment it has its answer rather
# than photographing a boot it has already proved.
function Save-Frame {
  param([string]$Suffix, [switch]$Force)
  if ($script:shotCount -ge $HardMaxShots) { return }
  if ($script:shotCount -ge $MaxShots -and -not $Force) { return }
  $script:shotCount++
  $slug = '{0:d2}-{1}' -f $script:shotCount, $Suffix
  # Context regardless: when the window frames come back wrong, the whole desktop
  # is what tells a human whether anything was there at all.
  try { [UnytShot]::CaptureVirtualScreen((Join-Path $contextDir "$slug-desktop.png")) | Out-Null }
  catch { Write-Note "  (desktop context frame failed: $($_.Exception.Message))" }

  $line = Get-AppWindow
  if (-not $line) {
    $script:captureFailures++
    Write-Note "  (pid $($app.Id) owns no visible window yet)"
    return
  }
  $script:sawWindow = $true
  $hwnd = [int64]($line.Split(' ')[0])
  $written = New-Object System.Collections.Generic.List[string]

  # PrintWindow asks the WINDOW to render itself, so what it returns is the app's
  # own content whatever is in front of it. That makes it the evidence.
  $printPath = Join-Path $verdictDir "$slug-print.png"
  $printed = $false
  try {
    if ([UnytShot]::CapturePrintWindow($hwnd, $printPath)) { $written.Add($printPath); $printed = $true }
    else { Remove-Item -LiteralPath $printPath -ErrorAction SilentlyContinue }
  }
  catch { Write-Note "  (PrintWindow failed: $($_.Exception.Message))" }

  # CopyFromScreen reads the DESKTOP at the window's coordinates, so it returns
  # whatever is there — the app if it is on top, somebody else's window if it is
  # not. It is only evidence when PrintWindow gave us nothing; otherwise it is
  # context, because a frame that can be the desktop must not decide anything.
  $screenPath = Join-Path (&{ if ($printed) { $contextDir } else { $verdictDir } }) "$slug-screen.png"
  try {
    if ([UnytShot]::CaptureWindowFromScreen($hwnd, $screenPath)) {
      if (-not $printed) { $written.Add($screenPath) }
    }
    else { Remove-Item -LiteralPath $screenPath -ErrorAction SilentlyContinue }
  }
  catch { Write-Note "  (CopyFromScreen failed: $($_.Exception.Message))" }

  if ($written.Count -eq 0) {
    $script:captureFailures++
    Write-Note "::warning::frame $script:shotCount could not be captured ($Suffix)"
    return
  }
  $result = Invoke-Analyser -Paths @($written)
  $result.Lines | ForEach-Object { Write-Note "  $_" }
  if ($result.Code -eq 0) { $script:painted = $slug }
}

# ── watch ─────────────────────────────────────────────────────────────────────
$reached = ''
$failedState = ''
$started = Get-Date
$reachedAt = $null
while ($true) {
  $elapsed = [int]((Get-Date) - $started).TotalSeconds
  $log = Get-AppLog

  if (-not $failedState) {
    $hit = [regex]::Match($log, $ReFailed)
    if ($hit.Success) {
      $failedState = $hit.Value
      Write-Note "::error::the app reached a FAILURE state: $failedState"
      Save-Frame -Suffix "t${elapsed}s-failed" -Force
      break
    }
  }
  if (-not $reached) {
    foreach ($pattern in @($ReBackendReady, $ReAwaiting)) {
      $hit = [regex]::Match($log, $pattern)
      if ($hit.Success) { $reached = $hit.Value; break }
    }
    if ($reached) {
      $reachedAt = Get-Date
      Write-Note "OK: the app reached -> $reached"
    }
  }

  # Forced once the state is reached: the frames from the window in which the
  # prompt is actually on screen are the ones worth the budget.
  if (-not $painted) {
    if ($reached) { Save-Frame -Suffix "t${elapsed}s" -Force } else { Save-Frame -Suffix "t${elapsed}s" }
  }

  if ($reached -and $painted) { break }
  if ($reached -and ([int]((Get-Date) - $reachedAt).TotalSeconds) -ge $PostSeconds) {
    Write-Note "::error::${PostSeconds}s after the app reached its state, no frame of its window is the app's own screen"
    break
  }

  $app.Refresh()
  if ($app.HasExited) {
    Write-Note '::error::the app process exited before reaching any state a user could see'
    Save-Frame -Suffix "t${elapsed}s-exited" -Force
    break
  }
  if ($elapsed -ge $TimeoutSeconds) {
    Write-Note "::error::no LairAwaitingPassword and no healthy state within ${TimeoutSeconds}s"
    Save-Frame -Suffix "t${elapsed}s-timeout" -Force
    break
  }
  Start-Sleep -Seconds $PollSeconds
}

# Said out loud: a lane that leaves the app running has left a process on the
# runner, and silence there is how that becomes somebody else's problem.
try { $app.Refresh(); if (-not $app.HasExited) { $app.Kill() } }
catch { Write-Note "::warning::could not stop the app (pid $($app.Id)): $($_.Exception.Message)" }

Write-Note '--- windows this process owned ---'
if ($sawWindow) { foreach ($line in [UnytShot]::Windows($app.Id)) { Write-Note "  $line" } }
else { Write-Note '  (none, at any point)' }
Write-Note '--- app log (tail) ---'
$log = Get-AppLog
if ($log) { Write-Note (($log -split "`n" | Select-Object -Last 40) -join "`n") }
else { Write-Note "  (no log file was written under $logDir)" }

# ── the verdict ───────────────────────────────────────────────────────────────
$frames = @(Get-ChildItem -LiteralPath $verdictDir -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($frames.Count -eq 0) {
  if (-not $sawWindow) {
    Exit-With -Verdict 'NOT PROVEN' -Why 'the app ran but never owned a visible window, so there was no first screen to photograph' -Code 1
  }
  Exit-With -Verdict 'CANNOT PROVE' -Why "the app had a window but not one frame of it could be captured ($captureFailures attempt(s) failed)" -Code 2
}

$analysis = Invoke-Analyser -Paths @($frames | ForEach-Object { $_.FullName })
$analysis.Lines | ForEach-Object { Write-Note $_ }
if ($analysis.Code -eq 4) {
  Exit-With -Verdict 'CANNOT PROVE' -Why "$($frames.Count) frame(s) were written but none could be read as an image" -Code 2
}
if ($analysis.Code -ne 0 -and $analysis.Code -ne 3) {
  Exit-With -Verdict 'CANNOT PROVE' -Why "the frame analyser itself failed (exit $($analysis.Code))" -Code 2
}

function Get-FirstLine {
  param([string]$Prefix)
  return (@($analysis.Lines | Where-Object { $_ -like "$Prefix*" }) | Select-Object -First 1)
}

$foreign = Get-FirstLine 'FOREIGN'
if ($analysis.Code -eq 0) {
  $screenNote = "a frame of its window is the app's own screen ($((Get-FirstLine 'PAINTED') -replace '^PAINTED\s*', ''))"
}
elseif ($foreign) {
  $screenNote = "every frame of its window shows something that is not the app ($($foreign -replace '^FOREIGN\s*', ''))"
}
else {
  $screenNote = "every frame of its window is a flat fill ($((Get-FirstLine 'FLAT') -replace '^FLAT\s*', ''))"
}
if ($failedState) { $stateNote = "the app reached a failure state ($failedState)" }
elseif ($reached) { $stateNote = "the app reached $reached" }
else { $stateNote = 'the app never reached LairAwaitingPassword or a healthy state' }

# Every frame uniform black, with a window that existed, is a desktop we were not
# shown rather than an app that drew nothing.
if ($analysis.Code -ne 0 -and
    @($analysis.Lines | Where-Object { $_ -match 'distinct=1 dominant=#000000' }).Count -eq $frames.Count) {
  Write-Note '::error title=Every Windows frame came back black::the window existed, so the desktop could not be read rather than the app being blank'
  Exit-With -Verdict 'CANNOT PROVE' -Why 'the app had a window but every capture of it is uniform black, which on a CI runner means the desktop could not be read rather than that the app was blank' -Code 2
}

if ($analysis.Code -eq 0 -and -not $failedState -and $reached) {
  Exit-With -Verdict 'PROVEN' -Why "$stateNote, and $screenNote" -Code 0
}
Exit-With -Verdict 'NOT PROVEN' -Why "$stateNote, and $screenNote" -Code 1
