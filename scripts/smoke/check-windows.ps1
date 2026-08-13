<#
.SYNOPSIS
  Does the Windows build a release shipped actually install and run on an
  ordinary user's PC?

.DESCRIPTION
  check-windows.ps1 <artifact.exe|artifact.msi>

  STATIC CHECKS PLUS A REAL INSTALL, and no UI automation. This suite asks "will
  this build work on a user's machine", so scaffolding may change the app's
  SURROUNDINGS but never the artifact or its dependency set — and on Windows the
  dynamic options break that rule: Windows Sandbox is not available on
  GitHub-hosted runners, so there is no pristine-machine equivalent of the Linux
  lane's containers, and a WebDriver UI test was built for this suite and
  deliberately discarded. What is left is an install/uninstall cycle plus what
  the artifact itself declares.

  THIS IS A SEPARATE LANE from the Linux one on purpose: Windows has no
  equivalent of dpkg's dependency metadata, so nothing can be diffed against a
  declared list and it needs its own answer rather than a matrix row. The
  closest equivalent, and the check that carries the most weight here, is the
  import table: every DLL the shipped binaries load, minus what the installer
  ships, minus what Windows itself guarantees. Whatever is left is a dependency
  on something a user may simply not have — the Windows shape of the exact bug
  the .deb dependency gate exists to catch.

  DO NOT try to capture the app's stdout. Release builds set
  windows_subsystem = "windows", so there is no console attached and redirected
  output is empty; the app's log file under
  %LOCALAPPDATA%\co.unyt.unyt.sandbox\logs is the only readable record.

  WHAT THIS DELIBERATELY DOES NOT COVER: whether the app LAUNCHES on a machine
  that has never had a build on it. A runner is a build image with years of
  redistributables already on it, and the three failure modes that only a clean
  machine shows — a missing WebView2 runtime (loaded through COM, so no import
  check can see it), SmartScreen, and a runtime the build machine had — are
  checked by hand once per release instead. The procedure is
  docs/windows-clean-machine-check.md.

  Every check must be ABLE to fail — test-windows-checks.ps1 drives the decision
  functions below against fixtures, including deliberately broken ones. Nine
  defects in this suite made a check silently pass, and all nine were found that
  way rather than by reading the code.

.PARAMETER Artifact
  Path to the NSIS installer (a plain .exe, not -setup.exe) or the .msi.

.PARAMETER LibraryOnly
  Define the functions and return without running anything, so the regression
  test can drive the real decision logic rather than a copy of it.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Artifact,
  [switch]$LibraryOnly
)

Set-StrictMode -Version Latest

# Narration goes to stderr and the summary table to stdout, exactly as the bash
# scripts in this directory do, so whatever reads the log can tell a check's
# verdict from its commentary.
function Write-Note { param([string]$Message) [Console]::Error.WriteLine($Message) }

# ── what Windows itself guarantees ────────────────────────────────────────────
# DLLs present on every supported Windows 10/11 SKU. THIS LIST IS THE CONTRACT:
# an import that is not here and not shipped beside the app is a dependency on
# something the user's machine may not have, which is what check 5 gates on. Add
# to it deliberately and only for something Windows genuinely ships — a lazy
# addition here silently converts a real finding into a pass.
#
# Deliberately ABSENT, though they are the ones most likely to show up:
#   VCRUNTIME140*.dll / MSVCP140*.dll / CONCRT140.dll — the Visual C++
#   redistributable. Windows does NOT ship it; it is present on most machines
#   only because other software installed it. A Rust MSVC build links it
#   dynamically by default, and this repo's unyt/.cargo/config.toml sets no
#   +crt-static, so the shipped binaries are expected to import it.
#   WebView2Loader.dll — Tauri normally links it statically; if it turns up as
#   an import and is not shipped, that is a real packaging break.
# ucrtbase.dll and the api-ms-win-crt-* forwarders ARE Windows components
# (the Universal CRT has shipped in-box since Windows 10) and are allowed.
$script:WindowsGuaranteedDlls = @(
  'ntdll.dll', 'kernel32.dll', 'kernelbase.dll', 'kernel.appcore.dll',
  'user32.dll', 'gdi32.dll', 'gdi32full.dll', 'advapi32.dll', 'sechost.dll',
  'msvcrt.dll', 'ucrtbase.dll', 'rpcrt4.dll', 'combase.dll', 'ole32.dll',
  'oleaut32.dll', 'oleacc.dll', 'shell32.dll', 'shlwapi.dll', 'shcore.dll',
  'windows.storage.dll', 'comctl32.dll', 'comdlg32.dll', 'propsys.dll',
  'ws2_32.dll', 'wsock32.dll', 'mswsock.dll', 'nsi.dll', 'iphlpapi.dll',
  'dnsapi.dll', 'winhttp.dll', 'wininet.dll', 'urlmon.dll', 'webservices.dll',
  'crypt32.dll', 'cryptbase.dll', 'cryptsp.dll', 'bcrypt.dll',
  'bcryptprimitives.dll', 'ncrypt.dll', 'msasn1.dll', 'wintrust.dll',
  'secur32.dll', 'sspicli.dll', 'authz.dll', 'userenv.dll', 'profapi.dll',
  'ntmarta.dll', 'version.dll', 'winmm.dll', 'imm32.dll', 'uxtheme.dll',
  'dwmapi.dll', 'dcomp.dll', 'd3d9.dll', 'd3d11.dll', 'd3d12.dll', 'dxgi.dll',
  'dxva2.dll', 'opengl32.dll', 'gdiplus.dll', 'msimg32.dll', 'setupapi.dll',
  'cfgmgr32.dll', 'powrprof.dll', 'psapi.dll', 'dbghelp.dll', 'wtsapi32.dll',
  'winspool.drv', 'mpr.dll', 'netapi32.dll', 'wldap32.dll', 'normaliz.dll',
  'clbcatq.dll', 'hid.dll', 'avrt.dll', 'apphelp.dll', 'winsta.dll',
  'credui.dll', 'dsound.dll', 'msctf.dll', 'twinapi.appcore.dll'
)

# ── pure decision logic (driven by test-windows-checks.ps1) ───────────────────

# The version a release asset's own name claims. Assets are named
# unyt_<version>_Unyt.Sandbox_<...>_x64_windows.<ext>. Returns $null when the
# name carries no version, which the caller treats as "cannot answer" rather
# than as a pass.
function Get-ArtifactVersion {
  param([Parameter(Mandatory)][string]$FileName)
  $m = [regex]::Match([System.IO.Path]::GetFileName($FileName), '^unyt_([0-9][0-9.]*)_')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-InstallerKind {
  param([Parameter(Mandatory)][string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.exe' { 'nsis' }
    '.msi' { 'msi' }
    default { 'unsupported' }
  }
}

# Every DLL a PE image will load: its import table AND its delay-load table.
# Parsed here rather than shelled out to dumpbin, which needs a Visual Studio
# environment that may or may not be on PATH — a check that silently does not
# run because a tool was missing is the failure mode this suite exists to
# prevent, and a parser this small is testable on any OS.
function Get-ImportedDll {
  param([Parameter(Mandatory)][string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 64) { throw "not a PE image (too short): $Path" }
  if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw "not a PE image (no MZ): $Path" }

  $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
  if ($peOffset -le 0 -or ($peOffset + 24) -ge $bytes.Length) { throw "not a PE image (bad e_lfanew): $Path" }
  if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) { throw "not a PE image (no PE signature): $Path" }

  $numberOfSections = [BitConverter]::ToUInt16($bytes, $peOffset + 6)
  $sizeOfOptional = [BitConverter]::ToUInt16($bytes, $peOffset + 20)
  $optOffset = $peOffset + 24
  $magic = [BitConverter]::ToUInt16($bytes, $optOffset)
  # 0x10b = PE32, 0x20b = PE32+. They differ by the 8-byte-wide ImageBase, which
  # moves the data directories — get this wrong and the import RVA is garbage.
  switch ($magic) {
    0x10B { $dirOffset = $optOffset + 96; $imageBase = [BitConverter]::ToUInt32($bytes, $optOffset + 28) }
    0x20B { $dirOffset = $optOffset + 112; $imageBase = [BitConverter]::ToUInt64($bytes, $optOffset + 24) }
    default { throw "unknown PE optional header magic 0x$('{0:X}' -f $magic): $Path" }
  }

  $sections = @()
  $secOffset = $optOffset + $sizeOfOptional
  for ($i = 0; $i -lt $numberOfSections; $i++) {
    $s = $secOffset + ($i * 40)
    if (($s + 40) -gt $bytes.Length) { break }
    $sections += [PSCustomObject]@{
      VirtualSize    = [BitConverter]::ToUInt32($bytes, $s + 8)
      VirtualAddress = [BitConverter]::ToUInt32($bytes, $s + 12)
      SizeOfRawData  = [BitConverter]::ToUInt32($bytes, $s + 16)
      RawOffset      = [BitConverter]::ToUInt32($bytes, $s + 20)
    }
  }

  # An RVA lands in whichever section covers it; the on-disk offset is its
  # distance into that section's raw data. A section's virtual size can exceed
  # its raw size (bss-like padding), so the span is the larger of the two.
  function Convert-RvaToOffset {
    param([uint32]$Rva)
    foreach ($sec in $sections) {
      $span = [Math]::Max($sec.VirtualSize, $sec.SizeOfRawData)
      if ($Rva -ge $sec.VirtualAddress -and $Rva -lt ($sec.VirtualAddress + $span)) {
        return [int]($Rva - $sec.VirtualAddress + $sec.RawOffset)
      }
    }
    return -1
  }
  function Read-AsciiAt {
    param([int]$Offset)
    if ($Offset -lt 0 -or $Offset -ge $bytes.Length) { return $null }
    $end = $Offset
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
    return [System.Text.Encoding]::ASCII.GetString($bytes, $Offset, $end - $Offset)
  }

  $names = [System.Collections.Generic.List[string]]::new()

  # Data directory 1: the import table. 20-byte descriptors, terminated by an
  # all-zero one; the DLL name RVA sits at +12.
  $importRva = [BitConverter]::ToUInt32($bytes, $dirOffset + 8)
  if ($importRva -ne 0) {
    $p = Convert-RvaToOffset -Rva $importRva
    while ($p -ge 0 -and ($p + 20) -le $bytes.Length) {
      $nameRva = [BitConverter]::ToUInt32($bytes, $p + 12)
      if ($nameRva -eq 0) { break }
      $n = Read-AsciiAt -Offset (Convert-RvaToOffset -Rva $nameRva)
      if ($n) { $names.Add($n) }
      $p += 20
    }
  }

  # Data directory 13: delay-load imports. Loaded on first use rather than at
  # start, but just as absent from the user's machine if they are missing — the
  # app dies the moment it touches that code path. The "new" format (attribute
  # bit 0) stores RVAs; the old one stores virtual addresses, which have to have
  # the image base taken off them first.
  $delayRva = [BitConverter]::ToUInt32($bytes, $dirOffset + (13 * 8))
  if ($delayRva -ne 0) {
    $p = Convert-RvaToOffset -Rva $delayRva
    while ($p -ge 0 -and ($p + 32) -le $bytes.Length) {
      $attrs = [BitConverter]::ToUInt32($bytes, $p)
      $nameField = [BitConverter]::ToUInt32($bytes, $p + 4)
      if ($nameField -eq 0) { break }
      $nameRva = 0
      if ($attrs -band 1) { $nameRva = $nameField }
      elseif ($nameField -gt $imageBase) { $nameRva = [uint32]($nameField - $imageBase) }
      else {
        # The old format's field is a virtual address, so it cannot be below the
        # image base. It is a 32-bit field, which is why the format only ever
        # appears in 32-bit images — refuse to guess rather than compute a
        # nonsense RVA and report whatever string happens to live there.
        break
      }
      $n = Read-AsciiAt -Offset (Convert-RvaToOffset -Rva $nameRva)
      if ($n) { $names.Add($n) }
      $p += 32
    }
  }

  # `,@(...)` — the unary comma. PowerShell UNROLLS a collection on return, so
  # an empty result comes back as $null and the caller's `.Count` throws under
  # StrictMode (or, worse, reads as "no imports" when the truth is "nothing was
  # parsed"). The comma returns the array itself, so every caller gets a real
  # collection whatever the contents.
  return , @($names | Sort-Object -Unique)
}

# What the machine has to provide that neither the installer nor Windows does.
# Case-insensitive throughout: PE import names are whatever the linker recorded
# (VCRUNTIME140.dll, api-ms-win-crt-runtime-l1-1-0.dll), and a case-sensitive
# comparison would let the same DLL pass or fail depending on how it was spelled.
function Get-UnsatisfiedImport {
  param(
    [string[]]$Imports = @(),
    [string[]]$ShippedFiles = @()
  )
  $shipped = @{}
  foreach ($f in $ShippedFiles) {
    if ($f) { $shipped[[System.IO.Path]::GetFileName($f).ToLowerInvariant()] = $true }
  }
  $guaranteed = @{}
  foreach ($d in $script:WindowsGuaranteedDlls) { $guaranteed[$d.ToLowerInvariant()] = $true }

  $unsatisfied = [System.Collections.Generic.List[string]]::new()
  foreach ($imp in $Imports) {
    if (-not $imp) { continue }
    $key = $imp.ToLowerInvariant()
    if ($shipped.ContainsKey($key)) { continue }
    if ($guaranteed.ContainsKey($key)) { continue }
    # api-ms-win-* / ext-ms-win-* are the API-set forwarders Windows resolves
    # internally; they are never real files on disk and never shipped.
    if ($key -like 'api-ms-win-*' -or $key -like 'ext-ms-win-*') { continue }
    $unsatisfied.Add($imp)
  }
  # Unary comma — see Get-ImportedDll: an empty result must stay a collection.
  return , @($unsatisfied | Sort-Object -Unique)
}

# Is an unsatisfied import the Visual C++ redistributable? Worth naming on its
# own because it has a specific, known fix, and because it is the one this build
# is expected to hit.
function Test-IsVcRuntime {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Dll)
  return ($Dll -match '^(vcruntime|msvcp|concrt|vcomp)\d*.*\.dll$')
}

# The verdict on an Authenticode signature, from whatever the platform reported.
# Kept separate from the tools that produce it so both paths (signtool and
# Get-AuthenticodeSignature) land on one rule, and so the rule itself is
# testable off Windows.
function Test-SignatureVerdict {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Status,
    [AllowEmptyString()][string]$SignerSubject = ''
  )
  # `Valid` is the only status that means a user's machine will trust it.
  # NotSigned is our current state; HashMismatch/NotTrusted are worse.
  $ok = ($Status -eq 'Valid')
  return [PSCustomObject]@{
    Ok      = $ok
    Status  = $Status
    Signer  = $SignerSubject
    Message = if ($ok) {
      "signed by $SignerSubject"
    }
    elseif ($Status -eq 'NotSigned') {
      'the installer carries NO Authenticode signature'
    }
    else {
      "the Authenticode signature is $Status"
    }
  }
}

# The uninstall entry an install added: whatever is in After and not in Before.
# A diff, not a lookup by a hard-coded key name, so nothing has to know how the
# NSIS template or WiX names its key — and so "the install registered nothing"
# is distinguishable from "we looked in the wrong place".
function Get-NewUninstallEntry {
  param(
    [object[]]$Before = @(),
    [object[]]$After = @()
  )
  $seen = @{}
  foreach ($b in $Before) { if ($b) { $seen[$b.KeyPath] = $true } }
  # Unary comma — see Get-ImportedDll: an empty result must stay a collection.
  return , @($After | Where-Object { $_ -and -not $seen.ContainsKey($_.KeyPath) })
}

# Is the entry an install of the version the artifact claims? Separated from the
# registry read so the verdict — not just the lookup — is exercised by the
# regression test, the same reason common.sh owns the Linux matchers.
function Test-UninstallEntry {
  param(
    [object]$Entry,
    [AllowNull()][string]$ExpectedVersion
  )
  if (-not $Entry) {
    return [PSCustomObject]@{ Ok = $false; Message = 'the install added no uninstall entry — the app cannot be removed from Settings' }
  }
  if (-not $ExpectedVersion) {
    # The artifact's name carried no version, so the check cannot answer its
    # question. Unknown is not a pass.
    return [PSCustomObject]@{ Ok = $false; Message = 'the artifact name carries no version, so nothing can be compared against it' }
  }
  if ($Entry.DisplayVersion -ne $ExpectedVersion) {
    return [PSCustomObject]@{ Ok = $false; Message = "the artifact is named $ExpectedVersion but registered version $($Entry.DisplayVersion)" }
  }
  return [PSCustomObject]@{ Ok = $true; Message = "registered $($Entry.DisplayName) $($Entry.DisplayVersion)" }
}

# Did the install actually put a program on disk? An installer can register
# itself perfectly and ship nothing.
function Test-InstallDirectory {
  param([AllowNull()][string]$Path)
  if (-not $Path) {
    return [PSCustomObject]@{ Ok = $false; Message = 'the uninstall entry records no InstallLocation'; Executables = @() }
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    return [PSCustomObject]@{ Ok = $false; Message = "InstallLocation '$Path' does not exist"; Executables = @() }
  }
  $exes = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue)
  if ($exes.Count -eq 0) {
    return [PSCustomObject]@{ Ok = $false; Message = "no .exe anywhere under $Path — the installer registered itself but shipped no program"; Executables = @() }
  }
  return [PSCustomObject]@{ Ok = $true; Message = "$($exes.Count) executable(s) under $Path"; Executables = $exes }
}

# Did the uninstall actually remove it? Both halves matter: an uninstaller that
# exits 0 while leaving the registration behind leaves an entry in Settings that
# removes nothing, and one that deregisters while leaving the program behind
# leaves an app the user can still run and can no longer uninstall.
function Test-RemovalComplete {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$EntryKeyPath,
    [object[]]$CurrentEntries = @(),
    [AllowNull()][string]$InstallDir
  )
  $problems = [System.Collections.Generic.List[string]]::new()
  if (@($CurrentEntries | Where-Object { $_.KeyPath -eq $EntryKeyPath }).Count -gt 0) {
    $problems.Add('the uninstall entry is still registered')
  }
  if ($InstallDir -and (Test-Path -LiteralPath $InstallDir)) {
    $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Include '*.exe', '*.dll' -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
      $problems.Add("$($left.Count) program file(s) left behind in $InstallDir")
    }
  }
  return [PSCustomObject]@{ Ok = ($problems.Count -eq 0); Problems = @($problems) }
}

# The command that removes it again. NSIS wants an uninstaller run with /S;
# an MSI is removed by product code. QuietUninstallString, when the installer
# provides one, is authoritative over anything constructed here.
function Get-UninstallCommand {
  param([Parameter(Mandatory)][object]$Entry)
  $quiet = $null
  if ($Entry.PSObject.Properties.Name -contains 'QuietUninstallString') { $quiet = $Entry.QuietUninstallString }
  if ($quiet) { return $quiet }
  $raw = $null
  if ($Entry.PSObject.Properties.Name -contains 'UninstallString') { $raw = $Entry.UninstallString }
  if (-not $raw) { return $null }
  if ($raw -match 'msiexec') {
    # /I in an MSI's own UninstallString means "modify"; the removal switch is
    # /X. Reusing the string unchanged pops the maintenance UI and hangs.
    $code = [regex]::Match($raw, '\{[0-9A-Fa-f-]{36}\}').Value
    if (-not $code) { return $null }
    return "msiexec.exe /x $code /quiet /norestart"
  }
  # UPPERCASE /S. NSIS's silent switch is case-sensitive, and a lowercase /s is
  # simply an unrecognised argument: the installer then runs INTERACTIVELY and
  # the job waits on a dialog nobody will ever click.
  return "$raw /S"
}

# ── the result table ──────────────────────────────────────────────────────────
# Above the LibraryOnly guard on purpose: Invoke-Check's rule that a check body
# must return a real verdict is itself one of the things the regression test has
# to be able to drive.
$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Result { param([string]$Name, [string]$Verdict) $script:Results.Add([PSCustomObject]@{ Name = $Name; Verdict = $Verdict }) }
function Invoke-Check {
  param([string]$Name, [scriptblock]$Body)
  Write-Note ''
  Write-Note "===== $Name ====="
  $ok = $false
  try {
    # The LAST value the body emits, and it must be a real boolean. `[bool](&
    # $Body)` would be true for any non-empty output at all, so one stray line
    # from a cmdlet that was not silenced would turn a failing check green —
    # which is this suite's defining bug class. A body that returns no verdict
    # is a broken check, and a broken check is a failure, not a pass.
    $emitted = @(& $Body)
    if ($emitted.Count -eq 0 -or -not ($emitted[-1] -is [bool])) {
      Write-Note "::error::$Name returned no true/false verdict — the check is broken, not passing"
      $ok = $false
    }
    else { $ok = $emitted[-1] }
  }
  catch {
    # An exception is a FAILED check, never a skipped one. A check that threw
    # and was not recorded is indistinguishable from one that passed.
    Write-Note "::error::$Name threw: $($_.Exception.Message)"
    $ok = $false
  }
  Add-Result -Name $Name -Verdict $(if ($ok) { 'pass' } else { 'FAIL' })
}

# Run a command and REFUSE TO WAIT FOREVER. An installer that puts a dialog up —
# which is precisely what a wrong silent switch does — would otherwise hang the
# job until the runner's own timeout, six hours later, with no diagnosis.
function Invoke-Silently {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 300
  )
  # Start-Process joins -ArgumentList with spaces and quotes NOTHING, so an
  # argument containing one is re-split into two by the time the process sees
  # it: `msiexec /i C:\dir with space\x.msi` then installs nothing and reports a
  # usage error. Quote here, once, rather than at each call site.
  $quoted = @($Arguments | ForEach-Object {
      if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ }
    })
  Write-Note "  running: $FilePath $($quoted -join ' ')"
  # An empty -ArgumentList is rejected outright, so an uninstaller that takes no
  # arguments has to be started without the parameter at all.
  $p = if ($quoted.Count -gt 0) {
    Start-Process -FilePath $FilePath -ArgumentList $quoted -PassThru -Wait:$false
  }
  else {
    Start-Process -FilePath $FilePath -PassThru -Wait:$false
  }
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    Write-Note "::error::$FilePath did not finish within ${TimeoutSeconds}s — it is waiting for input,"
    Write-Note '  which means the silent switch was not accepted.'
    try { $p.Kill($true) } catch { Write-Note "  (could not kill pid $($p.Id): $($_.Exception.Message))" }
    return [PSCustomObject]@{ ExitCode = -1; TimedOut = $true }
  }
  Write-Note "  exit code $($p.ExitCode)"
  return [PSCustomObject]@{ ExitCode = $p.ExitCode; TimedOut = $false }
}

if ($LibraryOnly) { return }

# ── from here down: the real run ──────────────────────────────────────────────

if (-not $Artifact) { throw 'usage: check-windows.ps1 <artifact.exe|artifact.msi>' }
$Artifact = (Resolve-Path -LiteralPath $Artifact -ErrorAction Stop).Path

function Write-SummaryAndExit {
  $arch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE }
  else { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture }
  $label = "windows-$([System.Environment]::OSVersion.Version.Build)/$arch"
  $overall = 0
  Write-Output ''
  Write-Output '############################################################'
  Write-Output '# summary'
  Write-Output '############################################################'
  Write-Output ('{0,-18} {1,-52} {2}' -f 'IMAGE', 'CHECK', 'RESULT')
  foreach ($r in $script:Results) {
    Write-Output ('{0,-18} {1,-52} {2}' -f $label, $r.Name, $r.Verdict)
    if ($r.Verdict -ne 'pass') { $overall = 1 }
  }
  if ($overall -eq 0) { Write-Output ''; Write-Output 'All checks passed.' }
  exit $overall
}

$kind = Get-InstallerKind -Path $Artifact
$wantVersion = Get-ArtifactVersion -FileName $Artifact

Write-Note '===== runner ====='
Write-Note "  Windows $([System.Environment]::OSVersion.Version) ($env:PROCESSOR_ARCHITECTURE)"
Write-Note "  artifact: $([System.IO.Path]::GetFileName($Artifact)) ($kind)"

if ($kind -eq 'unsupported') {
  Add-Result -Name 'installs silently' -Verdict 'FAIL'
  Write-Note "::error::unsupported artifact '$Artifact' (expected .exe or .msi)"
  Write-SummaryAndExit
}

# Registry roots an installer can register an uninstall entry under: per-user
# (where an NSIS currentUser install lands), and both views of per-machine
# (where an MSI lands). All three are read, so nothing depends on knowing which
# the installer chose.
$script:UninstallRoots = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
function Get-UninstallEntry {
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($root in $script:UninstallRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
      if (-not $p) { continue }
      $out.Add([PSCustomObject]@{
          KeyPath              = $key.PSPath
          DisplayName          = $p.PSObject.Properties.Name -contains 'DisplayName' ? $p.DisplayName : $null
          DisplayVersion       = $p.PSObject.Properties.Name -contains 'DisplayVersion' ? $p.DisplayVersion : $null
          InstallLocation      = $p.PSObject.Properties.Name -contains 'InstallLocation' ? $p.InstallLocation : $null
          UninstallString      = $p.PSObject.Properties.Name -contains 'UninstallString' ? $p.UninstallString : $null
          QuietUninstallString = $p.PSObject.Properties.Name -contains 'QuietUninstallString' ? $p.QuietUninstallString : $null
        })
    }
  }
  # Unary comma — see Get-ImportedDll: a machine with no uninstall entries at
  # all must come back as an empty list, not as $null.
  return , $out.ToArray()
}

$script:Before = Get-UninstallEntry
$script:Entry = $null
$script:InstallDir = $null
$script:Installed = $false

# ── 1. it installs without asking anything ────────────────────────────────────
Invoke-Check 'installs silently' {
  $r = if ($kind -eq 'nsis') {
    # UPPERCASE /S — see Get-UninstallCommand. NSIS defaults to a per-user
    # install under %LOCALAPPDATA%, which needs no elevation.
    Invoke-Silently -FilePath $Artifact -Arguments @('/S')
  }
  else {
    Invoke-Silently -FilePath 'msiexec.exe' -Arguments @('/i', $Artifact, '/quiet', '/norestart')
  }
  if ($r.TimedOut) { return $false }
  if ($r.ExitCode -ne 0) {
    Write-Note "::error::the installer exited $($r.ExitCode) — it did not install"
    return $false
  }
  $script:Installed = $true
  return $true
}

# ── 2. it registered itself, as the version on the tin ────────────────────────
# The Windows analogue of the Linux lane's "installed version matches the
# artifact": an installer that puts files down but registers nothing leaves an
# app the user cannot remove from Settings, and a version mismatch means the
# release packaged something other than what it is named after.
Invoke-Check 'registers an uninstall entry for this version' {
  if (-not $script:Installed) { Write-Note '::error::nothing was installed, so there is nothing to find'; return $false }
  $new = Get-NewUninstallEntry -Before $script:Before -After (Get-UninstallEntry)
  if ($new.Count -eq 0) {
    Write-Note '::error::the install added no uninstall entry — the app cannot be removed from Settings'
    return $false
  }
  if ($new.Count -gt 1) {
    Write-Note "::warning::the install added $($new.Count) uninstall entries:"
    foreach ($e in $new) { Write-Note "  $($e.DisplayName) $($e.DisplayVersion)" }
  }
  $script:Entry = $new | Where-Object { $_.DisplayName -like '*Unyt*' } | Select-Object -First 1
  if (-not $script:Entry) { $script:Entry = $new[0] }
  Write-Note "  $($script:Entry.DisplayName) $($script:Entry.DisplayVersion) -> $($script:Entry.InstallLocation)"
  $v = Test-UninstallEntry -Entry $script:Entry -ExpectedVersion $wantVersion
  if (-not $v.Ok) { Write-Note "::error::$($v.Message)"; return $false }
  Write-Note "OK: $($v.Message)"
  return $true
}

# ── 3. the program is actually on disk ────────────────────────────────────────
Invoke-Check 'installs the application executable' {
  if (-not $script:Entry) { Write-Note '::error::no uninstall entry, so no install location to check'; return $false }
  $d = Test-InstallDirectory -Path $script:Entry.InstallLocation
  if (-not $d.Ok) { Write-Note "::error::$($d.Message)"; return $false }
  $script:InstallDir = $script:Entry.InstallLocation
  foreach ($e in $d.Executables) { Write-Note "  $($e.FullName)" }
  return $true
}

# ── 4. Authenticode ───────────────────────────────────────────────────────────
# EXPECTED RED, AND DELIBERATELY GATED. Our Windows builds are not code-signed:
# release-tauri-app.yaml passes Apple credentials for macOS and nothing for
# Windows. That is a real, user-facing defect — an unsigned installer gives
# every user a SmartScreen "unknown publisher" block — so it is reported the way
# the Linux lane reports its dependency finding: as a check that goes red until
# it is fixed, not as a note nobody reads. The job is non-blocking by structure
# (nothing `needs` it), so a red row costs visibility and nothing else, and the
# day a signing certificate is wired in this turns green with no edit here.
Invoke-Check 'the installer is Authenticode-signed and trusted' {
  # signtool with /pa — MANDATORY: without it signtool applies the DRIVER
  # signing policy, which rejects perfectly good application signatures and
  # produces a failure that has nothing to do with the artifact. It lives under
  # the Windows SDK, so take the newest one present and fall back to the
  # built-in cmdlet, which asks the same question of the same OS trust store.
  $signtool = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
    Sort-Object -Property FullName | Select-Object -Last 1
  if ($signtool) {
    Write-Note "  $($signtool.FullName) verify /pa /v"
    $out = & $signtool.FullName verify /pa /v $Artifact 2>&1
    $rc = $LASTEXITCODE
    foreach ($line in $out) { Write-Note "  $line" }
    if ($rc -eq 0) { Write-Note 'OK: signtool accepts the signature under the default application policy'; return $true }
    Write-Note "::error::signtool rejected the signature (exit $rc) — a user gets a SmartScreen block"
    Write-Note '  Fix: sign the installer in release-tauri-app.yaml (a Windows code-signing certificate).'
    return $false
  }
  $sig = Get-AuthenticodeSignature -LiteralPath $Artifact
  $verdict = Test-SignatureVerdict -Status $sig.Status.ToString() -SignerSubject $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' })
  Write-Note "  Get-AuthenticodeSignature: $($verdict.Message)"
  if ($verdict.Ok) { return $true }
  Write-Note "::error::$($verdict.Message) — a user gets a SmartScreen 'unknown publisher' block"
  Write-Note '  Fix: sign the installer in release-tauri-app.yaml (a Windows code-signing certificate).'
  return $false
}

# ── 5. what it needs from the machine ─────────────────────────────────────────
# The closest thing Windows has to the .deb's dependency gate, and the same
# question: does this artifact require something the user's machine is not
# guaranteed to have? Every shipped binary's imports, minus what the installer
# put beside it, minus what Windows ships.
Invoke-Check 'imports nothing the machine is not guaranteed to have' {
  if (-not $script:InstallDir) { Write-Note '::error::no install directory, so nothing was scanned'; return $false }
  $binaries = @(Get-ChildItem -LiteralPath $script:InstallDir -Recurse -Include '*.exe', '*.dll' -ErrorAction SilentlyContinue)
  if ($binaries.Count -eq 0) {
    # An empty sweep finds no violations. That must not read the same as a clean
    # one — it is the shape in which this check quietly stops checking.
    Write-Note '::error::no .exe or .dll found under the install directory — nothing was scanned'
    return $false
  }
  $shipped = $binaries | ForEach-Object { $_.Name }
  $all = [System.Collections.Generic.List[string]]::new()
  foreach ($b in $binaries) {
    $imports = Get-ImportedDll -Path $b.FullName
    Write-Note "  $($b.Name): $($imports.Count) imports"
    foreach ($i in $imports) { $all.Add($i) }
  }
  $missing = Get-UnsatisfiedImport -Imports $all -ShippedFiles $shipped
  if ($missing.Count -eq 0) {
    Write-Note "OK: $($binaries.Count) binaries, every import either shipped or guaranteed by Windows"
    return $true
  }
  Write-Note "::error::$($missing.Count) DLL(s) required from the machine that Windows does not ship:"
  foreach ($m in $missing) { Write-Note "  $m" }
  if (@($missing | Where-Object { Test-IsVcRuntime -Dll $_ }).Count -gt 0) {
    Write-Note '  This is the Visual C++ redistributable. Windows does not include it; it is on most'
    Write-Note '  machines only because other software installed it, and on a clean one the app fails'
    Write-Note '  to start with "VCRUNTIME140.dll was not found". Fix: build with static_vcruntime /'
    Write-Note '  +crt-static, or chain the redistributable from the NSIS installer.'
  }
  return $false
}

# ── 6. and it goes away again ─────────────────────────────────────────────────
# One install/uninstall cycle catches real installer bugs — an uninstaller that
# does not remove the program, or one that cannot run unattended at all.
Invoke-Check 'uninstalls cleanly' {
  if (-not $script:Entry) { Write-Note '::error::no uninstall entry, so nothing can be removed'; return $false }
  $cmd = Get-UninstallCommand -Entry $script:Entry
  if (-not $cmd) {
    Write-Note '::error::the uninstall entry carries no usable UninstallString'
    return $false
  }
  # Split "C:\path with spaces\uninstall.exe" /S into program and arguments.
  $m = [regex]::Match($cmd, '^\s*"([^"]+)"\s*(.*)$')
  if ($m.Success) { $exe = $m.Groups[1].Value; $rest = $m.Groups[2].Value }
  else { $parts = $cmd -split '\s+', 2; $exe = $parts[0]; $rest = if ($parts.Count -gt 1) { $parts[1] } else { '' } }
  # NOT $args: that is an automatic variable, and assigning to it inside a
  # scriptblock silently shadows the invocation's own arguments.
  $argList = @($rest -split '\s+' | Where-Object { $_ })
  $r = Invoke-Silently -FilePath $exe -Arguments $argList
  if ($r.TimedOut) { return $false }
  if ($r.ExitCode -ne 0) {
    Write-Note "::error::the uninstaller exited $($r.ExitCode)"
    return $false
  }
  # NSIS's uninstaller copies itself to %TEMP% and returns immediately, so the
  # registry can still hold the entry for a moment after exit 0. Poll rather
  # than assert once — and keep the bound short enough that a real failure to
  # remove anything is still a failure.
  $deadline = (Get-Date).AddSeconds(60)
  do {
    Start-Sleep -Seconds 2
    $verdict = Test-RemovalComplete -EntryKeyPath $script:Entry.KeyPath `
      -CurrentEntries (Get-UninstallEntry) -InstallDir $script:InstallDir
  } while (-not $verdict.Ok -and (Get-Date) -lt $deadline)
  if (-not $verdict.Ok) {
    Write-Note '::error::60s after the uninstaller exited 0, it has not finished removing the app:'
    foreach ($p in $verdict.Problems) { Write-Note "  $p" }
    return $false
  }
  Write-Note 'OK: the uninstaller removed the program and its registration'
  return $true
}

Write-SummaryAndExit
