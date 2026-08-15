<#
.SYNOPSIS
  Does the released Windows build put a visible first screen on screen?

.DESCRIPTION
  prove-windows.ps1 -Artifact <installer.exe|installer.msi> -Shots <dir>
  prove-windows.ps1 -SelfTest

  TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.

  BOTH INSTALLERS, ONE LANE. The release ships an NSIS .exe and an .msi, and they
  install to different places under different registry hives — so proving one
  proves nothing about the other. The only thing that differs here is the command
  that installs it and where Windows records that; everything after the launch is
  the same code, because two copies of a capture path would drift.

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
  The NSIS installer (.exe) or the .msi.

.PARAMETER Shots
  Directory to write frames into; verdict\ is analysed, context\ is uploaded only.

.PARAMETER SelfTest
  Prove the decisions this lane makes about an installer can still come out
  wrong, and exit. Needs no artifact, installs nothing, and runs before anything
  that requires a window station.
#>
[CmdletBinding(DefaultParameterSetName = 'Prove')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Prove')][string]$Artifact,
  [Parameter(Mandatory, ParameterSetName = 'Prove')][string]$Shots,
  [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Note { param([string]$Message) [Console]::Error.WriteLine($Message) }

# ── which installer this is, and what that changes ────────────────────────────
# DEFINED ABOVE EVERYTHING PLATFORM-SPECIFIC so -SelfTest can drive the real
# functions: the Add-Type below needs .NET Framework, and the checks after it
# need a window station.

function Get-InstallerKind {
  param([Parameter(Mandatory)][string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.exe' { 'nsis' }
    '.msi' { 'msi' }
    default { 'unsupported' }
  }
}

# THE SAME COMMANDS check-windows.ps1 USES, and that agreement is the point: the
# smoke and this lane must install to the same place under the same product
# identity, or they are not talking about the same install.
#   NSIS — UPPERCASE /S. The switch is case-sensitive and /s runs the installer
#   interactively, hanging the job on a dialog. Per-user, under %LOCALAPPDATA%.
#   MSI — msiexec /i /quiet /norestart. Per-machine, under Program Files, which
#   needs the elevation a runner's account already has.
function Get-InstallInvocation {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateSet('nsis', 'msi')][string]$Kind
  )
  if ($Kind -eq 'msi') {
    return [PSCustomObject]@{
      FilePath  = 'msiexec.exe'
      Arguments = @('/i', $Path, '/quiet', '/norestart')
    }
  }
  return [PSCustomObject]@{ FilePath = $Path; Arguments = @('/S') }
}

# Start-Process joins -ArgumentList with spaces and quotes NOTHING, so an
# artifact path with a space in it is re-split before msiexec ever sees it. Its
# own function so -SelfTest can drive it: inline at the call site, the one
# argument that can carry a space is the one no fixture there has.
function Get-StartProcessArgv {
  param([string[]]$Arguments = @())
  return @($Arguments | ForEach-Object {
      if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ }
    })
}

# Only 0. msiexec's 3010 and 1641 mean it installed and wants a reboot, and this
# lane refuses them on purpose: a reboot-pending install is not a state any user
# is looking at. A policy, so it is asserted rather than left to a comment.
function Test-InstallSucceeded {
  param([Parameter(Mandatory)][int]$ExitCode)
  return ($ExitCode -eq 0)
}

# The registry value is not a clean path and the two installers disagree about
# how it is spelled: NSIS writes it QUOTED, the MSI bare with a trailing
# separator. Verbatim, the quoted form fails every Test-Path. Same normalisation
# as check-windows.ps1's Test-InstallDirectory, so both agree where the app is.
function Get-InstallLocation {
  param([AllowNull()][AllowEmptyString()][string]$Raw)
  if (-not $Raw) { return $null }
  $path = $Raw.Trim().Trim('"').TrimEnd('\', '/')
  if (-not $path) { return $null }
  return $path
}

# Which of the entries an install added is the app — the same rule as
# check-windows.ps1: prefer the one naming itself Unyt, and otherwise take the
# first rather than giving up, since something did just install.
function Select-InstallEntry {
  param([object[]]$New = @())
  $named = @($New | Where-Object { $_.DisplayName -like '*Unyt*' })
  if ($named.Count -gt 0) { return $named[0] }
  if ($New.Count -gt 0) { return $New[0] }
  return $null
}

# EVERY LINE TO STDERR, and only the exit code returned: a function that also
# emitted its narration would hand `exit` the whole collection instead of the
# number, and the step's colour would stop meaning anything.
function Invoke-SelfTest {
  $script:selfTestPassed = 0
  $script:selfTestFailed = 0
  # ARITY IS PART OF THE VALUE, so an array is rendered with its count and a
  # separator no argument can contain: joined on spaces, `@('/i','a b')` and
  # `@('/i a b')` read the same — and the second is one argument msiexec would
  # reject outright.
  function Format-Value {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [array]) { return "$($Value.Count):[$($Value -join '|')]" }
    return "$Value"
  }
  function Test-Case {
    param([string]$Name, [AllowNull()][object]$Want, [AllowNull()][object]$Got)
    $wantText = Format-Value -Value $Want
    $gotText = Format-Value -Value $Got
    # Case-SENSITIVE: /S and /s are two different installers' behaviour.
    if ($wantText -ceq $gotText) {
      $script:selfTestPassed++
      Write-Note ('pass  {0,-58} {1}' -f $Name, $gotText)
    }
    else {
      $script:selfTestFailed++
      Write-Note "FAIL  $Name — wanted '$wantText', got '$gotText'"
    }
  }

  Test-Case 'an .exe is the NSIS installer' 'nsis' (Get-InstallerKind -Path 'C:\a\unyt_1.0.0_x64_windows.exe')
  Test-Case 'an .msi is the MSI' 'msi' (Get-InstallerKind -Path 'C:\a\unyt_1.0.0_x64_windows.msi')
  # The release names its assets in lower case, but an extension is not a
  # promise: a case-sensitive match would read .MSI as unsupported.
  Test-Case 'the extension is matched without case' 'msi' (Get-InstallerKind -Path 'C:\a\UNYT.MSI')
  Test-Case 'anything else is refused rather than guessed' 'unsupported' (Get-InstallerKind -Path 'C:\a\unyt.zip')
  Test-Case 'and a name with dots in it is read by its last one' 'nsis' (Get-InstallerKind -Path 'C:\a\unyt_0.101.0-dev.0_x64.exe')

  $nsis = Get-InstallInvocation -Path 'C:\a\x.exe' -Kind 'nsis'
  Test-Case 'NSIS runs itself' 'C:\a\x.exe' $nsis.FilePath
  Test-Case 'NSIS is silenced with an uppercase /S' @('/S') $nsis.Arguments
  $msi = Get-InstallInvocation -Path 'C:\a\x.msi' -Kind 'msi'
  Test-Case 'an MSI is installed by msiexec' 'msiexec.exe' $msi.FilePath
  Test-Case 'an MSI is installed silently, and reboots nothing' `
    @('/i', 'C:\a\x.msi', '/quiet', '/norestart') $msi.Arguments

  # The one argument that can carry a space is the artifact path, and a runner's
  # temp directory is one Windows release away from having one.
  Test-Case 'a path with a space reaches msiexec as one argument' `
    @('/i', '"C:\Program Files\a b.msi"', '/quiet', '/norestart') `
    (Get-StartProcessArgv -Arguments (Get-InstallInvocation -Path 'C:\Program Files\a b.msi' -Kind 'msi').Arguments)
  # WRAPPED IN @() exactly as the caller wraps it: PowerShell unwraps a
  # one-element array on return, so an assertion that did not wrap would be
  # comparing a bare string and would not see the arity it is here to check.
  Test-Case 'a switch is passed through untouched' @('/S') @(Get-StartProcessArgv -Arguments @('/S'))
  Test-Case 'and an already-quoted argument is not quoted twice' `
    @('"a b"') @(Get-StartProcessArgv -Arguments @('"a b"'))

  Test-Case 'exit 0 is the only clean install' 'True' (Test-InstallSucceeded -ExitCode 0)
  # 3010/1641 installed and want a reboot; refusing them is the policy, and a
  # comment alone would not stop a well-meant relaxation.
  Test-Case 'a reboot-pending install is not one a user is looking at' 'False' (Test-InstallSucceeded -ExitCode 3010)
  Test-Case 'nor is the other reboot code' 'False' (Test-InstallSucceeded -ExitCode 1641)
  Test-Case 'and a fatal msiexec error is not either' 'False' (Test-InstallSucceeded -ExitCode 1603)

  # THE CLAIM THAT THE TWO LANES AGREE: NSIS records its directory quoted and the
  # MSI records it with a trailing separator, and both have to name one place.
  Test-Case 'NSIS quotes its install location' 'C:\Program Files\Unyt Sandbox' (Get-InstallLocation -Raw '"C:\Program Files\Unyt Sandbox"')
  Test-Case 'the MSI trails a separator on the same directory' 'C:\Program Files\Unyt Sandbox' (Get-InstallLocation -Raw 'C:\Program Files\Unyt Sandbox\')
  Test-Case 'an empty install location is unknown, not the current directory' $null (Get-InstallLocation -Raw '   ')
  Test-Case 'and so is a missing one' $null (Get-InstallLocation -Raw $null)

  $entries = @(
    [PSCustomObject]@{ KeyPath = 'k1'; DisplayName = 'WebView2 Runtime'; InstallLocation = 'c:\wv2' },
    [PSCustomObject]@{ KeyPath = 'k2'; DisplayName = 'Unyt Sandbox'; InstallLocation = 'c:\unyt' }
  )
  Test-Case 'the app is picked out of everything an install registered' 'k2' (Select-InstallEntry -New $entries).KeyPath
  Test-Case 'an unrecognised name is still what just installed' 'k1' (Select-InstallEntry -New @($entries[0])).KeyPath
  # Held in a variable rather than dotted into: a property read off $null is its
  # own error under StrictMode, and this case is about the $null itself.
  $none = Select-InstallEntry -New @()
  Test-Case 'and nothing registered is nothing to launch' $null $none

  Write-Note ''
  Write-Note "prove-windows regression: $($script:selfTestPassed) passed, $($script:selfTestFailed) failed"
  # A floor, so deleting cases fails as loudly as breaking one.
  if (($script:selfTestPassed + $script:selfTestFailed) -lt 23) {
    [Console]::Error.WriteLine('::error::assertions were deleted from prove-windows.ps1 -SelfTest')
    return 1
  }
  if ($script:selfTestFailed -gt 0) { return 1 }
  return 0
}

if ($SelfTest) { exit (Invoke-SelfTest) }

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

# ASKED BEFORE ANY OF THE RUNNER IS PROBED: an artifact this lane has no way to
# install is a wrong invocation, and it must not be reported as anything about a
# runner or a build.
$kind = Get-InstallerKind -Path $Artifact
if ($kind -eq 'unsupported') {
  Exit-With -Verdict 'CANNOT PROVE' -Why "'$([System.IO.Path]::GetFileName($Artifact))' is neither an .exe nor an .msi, so there is no way to install it" -Code 2
}
Write-Note "artifact: $([System.IO.Path]::GetFileName($Artifact)) ($kind)"

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
$run = Get-InstallInvocation -Path $Artifact -Kind $kind
$argv = @(Get-StartProcessArgv -Arguments $run.Arguments)
Write-Note "installing: $($run.FilePath) $($argv -join ' ')"
$installer = Start-Process -FilePath $run.FilePath -ArgumentList $argv -PassThru -Wait:$false
if (-not $installer.WaitForExit(300 * 1000)) {
  try { $installer.Kill() } catch { Write-Note "  (could not kill the installer: $($_.Exception.Message))" }
  Exit-With -Verdict 'NOT PROVEN' -Why "the $kind installer never finished, so it was waiting for input" -Code 1
}
# The message must not say "nothing was installed": 3010 means it did — see
# Test-InstallSucceeded for why that is still refused.
if (-not (Test-InstallSucceeded -ExitCode $installer.ExitCode)) {
  Exit-With -Verdict 'NOT PROVEN' -Why "the $kind installer exited $($installer.ExitCode), so this is not an install a user would be looking at (3010 would mean it installed and wants a reboot first)" -Code 1
}

# CANNOT PROVE, not NOT PROVEN: this is how THIS LANE finds the program, and an
# installer that registers no location has defeated the lookup rather than
# demonstrated anything about whether the app shows a screen. The release smoke
# owns the question of whether registering it is required — check-windows.ps1's
# 'registers' and 'executable' checks red the build for exactly this.
$entry = Select-InstallEntry -New @(Get-Entries | Where-Object { $before -notcontains $_.KeyPath })
if (-not $entry) {
  Exit-With -Verdict 'CANNOT PROVE' -Why "the $kind install registered no uninstall entry, so this lane has no way to find what it installed" -Code 2
}
$installDir = Get-InstallLocation -Raw $entry.InstallLocation
if (-not $installDir) {
  Exit-With -Verdict 'CANNOT PROVE' -Why "the $kind install registered '$($entry.DisplayName)' with no InstallLocation, so this lane has no way to find what it installed" -Code 2
}
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
  # Names no cause — see the same line in proving-common.sh.
  $screenNote = "no frame of its window carries enough to be a screen ($((Get-FirstLine 'FLAT') -replace '^FLAT\s*', ''))"
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
