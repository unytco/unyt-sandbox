<#
.SYNOPSIS
  Does the Windows build a release shipped actually install and run on an
  ordinary user's PC?

.DESCRIPTION
  check-windows.ps1 <artifact.exe|artifact.msi>   every check, then the summary
  check-windows.ps1 -Only <id> -Artifact <path>   exactly one check, one row
  check-windows.ps1 -PrintChecks                  the check list, id<TAB>name

  ONE CHECK PER CI STEP, so the job's step list reads like the summary table
  instead of hiding it inside one step's log. A GitHub Actions step is its own
  process, which is why the install/inspect/uninstall cycle cannot hand state
  along in a $script: variable any more: -Only persists what the later checks
  need under UNYT_SMOKE_STATE, and a check whose prerequisite state is absent
  FAILS rather than skipping. Run with neither flag and it is the single-process
  suite it has always been.

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

.PARAMETER Only
  Run exactly one check, by the id -PrintChecks lists, and print its single row
  as <display name>|<pass|FAIL|warn>. Exits 0 on pass AND on warn, 1 on FAIL: a
  step is a check, and the declared signing warning must not turn the job red.

.PARAMETER PrintChecks
  Print the check list — <id><TAB><display name>, one per line, in run order —
  and exit. Needs no artifact and runs nothing.

.PARAMETER LibraryOnly
  Define the functions and return without running anything, so the regression
  test can drive the real decision logic rather than a copy of it.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Artifact,
  [string]$Only,
  [switch]$PrintChecks,
  [switch]$LibraryOnly
)

Set-StrictMode -Version Latest

# Narration goes to stderr and the summary table to stdout, exactly as the bash
# scripts in this directory do, so whatever reads the log can tell a check's
# verdict from its commentary. UNYT_SMOKE_LOG additionally collects it into one
# file: one check per CI step, each step's stderr is its own, and an uploaded log
# artifact would otherwise carry only the last step's narration.
function Write-Note {
  param([string]$Message)
  [Console]::Error.WriteLine($Message)
  if ($env:UNYT_SMOKE_LOG) { Add-Content -LiteralPath $env:UNYT_SMOKE_LOG -Value $Message }
}

# ── what Windows itself guarantees ────────────────────────────────────────────
# DLLs present on every supported Windows 10/11 SKU. THIS LIST IS THE CONTRACT:
# an import that is not here and not shipped beside the app is a dependency on
# something the user's machine may not have, which is what check 5 gates on. Add
# to it deliberately and only for something Windows genuinely ships — a lazy
# addition here silently converts a real finding into a pass.
#
# Deliberately ABSENT, and kept absent even though the shipped build turned out
# not to need them:
#   VCRUNTIME140*.dll / MSVCP140*.dll / CONCRT140.dll — the Visual C++
#   redistributable. Windows does NOT ship it; it is present on most machines
#   only because other software installed it. This was PREDICTED to appear, on
#   the reasoning that a Rust MSVC build links it dynamically and unyt's
#   .cargo/config.toml sets no +crt-static — and the first real run DISPROVED
#   that: v0.100.0's installed binaries import none of them. The entries stay
#   out of the list so that a future build which does start needing one is
#   reported rather than waved through.
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
  'winspool.drv', 'mpr.dll', 'netapi32.dll', 'pdh.dll', 'wldap32.dll', 'normaliz.dll',
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

  # EVERY FAILURE PATH BELOW THROWS. A parser that gives up quietly returns an
  # empty import list, and an empty import list is indistinguishable from a
  # binary that imports nothing — so a truncated file, an RVA that maps nowhere,
  # or an unreadable name would each turn "could not read this" into "nothing to
  # find here", which is a pass. No real native PE imports nothing.
  $sections = @()
  $secOffset = $optOffset + $sizeOfOptional
  for ($i = 0; $i -lt $numberOfSections; $i++) {
    $s = $secOffset + ($i * 40)
    if (($s + 40) -gt $bytes.Length) {
      throw "section table is truncated at section $i of ${numberOfSections}: $Path"
    }
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
    if ($Offset -lt 0 -or $Offset -ge $bytes.Length) {
      throw "a DLL name points outside the file (offset $Offset): $Path"
    }
    $end = $Offset
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
    $s = [System.Text.Encoding]::ASCII.GetString($bytes, $Offset, $end - $Offset)
    # An empty name is not a name. Dropping it silently would lose exactly one
    # DLL from the sweep, and losing the single unsatisfied one turns the finding
    # into a pass.
    if (-not $s) { throw "an empty DLL name at offset ${Offset}: $Path" }
    return $s
  }

  $names = [System.Collections.Generic.List[string]]::new()

  # Data directory 1: the import table. 20-byte descriptors, terminated by an
  # all-zero one; the DLL name RVA sits at +12.
  $importRva = [BitConverter]::ToUInt32($bytes, $dirOffset + 8)
  if ($importRva -ne 0) {
    $p = Convert-RvaToOffset -Rva $importRva
    if ($p -lt 0) { throw "the import directory RVA $importRva maps into no section: $Path" }
    while (($p + 20) -le $bytes.Length) {
      $nameRva = [BitConverter]::ToUInt32($bytes, $p + 12)
      if ($nameRva -eq 0) { break }
      $names.Add((Read-AsciiAt -Offset (Convert-RvaToOffset -Rva $nameRva)))
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
    if ($p -lt 0) { throw "the delay-load directory RVA $delayRva maps into no section: $Path" }
    while (($p + 32) -le $bytes.Length) {
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
        # nonsense RVA and report whatever string happens to live there. A throw,
        # not a break: giving up here silently drops every remaining delay import.
        throw "a delay-load descriptor's name field ($nameField) is below the image base ($imageBase): $Path"
      }
      $names.Add((Read-AsciiAt -Offset (Convert-RvaToOffset -Rva $nameRva)))
      $p += 32
    }
  }

  # RETURNED PLAINLY, AND EVERY CALLER WRAPS IN @(). The obvious alternative —
  # `return , @(...)`, the unary comma, so an empty result stays a collection —
  # is a trap here: it emits the array as ONE object, so a caller writing the
  # idiomatic `@(Get-ImportedDll ...)` nests it one level deep, and a nested list
  # coerced into [string[]] collapses into a single space-joined "DLL name". That
  # shipped: the allowlist then matched nothing, every import list became one
  # unrecognised entry, and the check reported a finding no matter what the
  # binary imported. Wrapping at the call site cannot nest, and is the idiom.
  return @($names | Sort-Object -Unique)
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
  # Returned plainly; callers wrap. See Get-ImportedDll for why the unary comma
  # is wrong here.
  return @($unsatisfied | Sort-Object -Unique)
}

# The verdict on a whole import sweep, guards included.
#
# THE ZERO GUARD BELONGS HERE, ON THE POPULATION THE CHECK ACTUALLY INSPECTS.
# Counting binaries answers "was there anything to scan"; it does not answer
# "did we read any imports out of them". Zero imports across a set of native
# binaries is a parser failure, never a clean result — no real native PE imports
# nothing — and without this the sweep reports "every import either shipped or
# guaranteed by Windows" having examined none.
function Get-ImportSweepVerdict {
  param(
    [string[]]$Binaries = @(),
    [string[]]$Imports = @(),
    [string[]]$Unsatisfied = @()
  )
  if ($Binaries.Count -eq 0) {
    return [PSCustomObject]@{ Ok = $false; Message = 'no .exe or .dll found under the install directory — nothing was scanned' }
  }
  if ($Imports.Count -eq 0) {
    return [PSCustomObject]@{
      Ok      = $false
      Message = "$($Binaries.Count) binaries yielded ZERO imports between them — a native PE always imports something, so this is a failed parse, not a clean result"
    }
  }
  if ($Unsatisfied.Count -gt 0) {
    return [PSCustomObject]@{
      Ok      = $false
      Message = "$($Unsatisfied.Count) DLL(s) required from the machine that Windows does not ship"
    }
  }
  return [PSCustomObject]@{
    Ok      = $true
    Message = "$($Binaries.Count) binaries, $($Imports.Count) imports, every one either shipped or guaranteed by Windows"
  }
}

# Is an unsatisfied import the Visual C++ redistributable? Worth naming on its
# own because it has a specific, known fix, and because it is the one this build
# is expected to hit.
function Test-IsVcRuntime {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Dll)
  return ($Dll -match '^(vcruntime|msvcp|concrt|vcomp)\d*.*\.dll$')
}

# ── the signing declaration ───────────────────────────────────────────────────
# WHAT WE EXPECT TODAY, and the one line to change when it stops being true.
# Our Windows builds are NOT code-signed: docs/signing.md records an Apple
# Developer ID and no Windows certificate, and release-tauri-app.yaml passes no
# Windows signing credentials. That is a real, deferred, user-facing cost — every
# user meets a SmartScreen "unknown publisher" block — but it is a KNOWN state
# rather than a regression, and a check that is permanently red is a check people
# learn to scroll past.
#
# So it is a declared-state tripwire rather than a permanent failure: amber while
# reality matches the declaration, red the moment they diverge in either
# direction. Set this to $true the day a certificate is wired into the release
# workflow, and the check turns from warn to pass with nothing else to change —
# and if the signing then silently stops working, it goes red instead of quietly
# returning to amber.
#
# NOT A SKIP, deliberately. A skip would also throw away the case a skip cannot
# see: signed but with a broken or untrusted chain, which is a genuine defect and
# still fails below.
$script:ExpectWindowsSigned = $false

# The verdict on an Authenticode signature, from whatever the platform reported.
# Kept separate from the tools that produce it so both paths (signtool and
# Get-AuthenticodeSignature) land on one rule, and so the rule itself is
# testable off Windows.
#
# Four outcomes, and only one of them is silence:
#   signed and trusted                  -> pass
#   unsigned, and we expected unsigned  -> warn   (declared state, job stays green)
#   unsigned, but we expected signed    -> FAIL   (signing broke, or the cert lapsed)
#   signed but invalid / untrusted      -> FAIL   (always — this is never expected)
function Test-SignatureVerdict {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Status,
    [AllowEmptyString()][string]$SignerSubject = '',
    [bool]$ExpectSigned = $false
  )
  # `Valid` is the only status meaning a user's machine will trust it. Anything
  # that is neither Valid nor NotSigned — HashMismatch, NotTrusted, UnknownError
  # — is a broken signature, which no declaration excuses.
  if ($Status -eq 'Valid') {
    return [PSCustomObject]@{
      Result = 'pass'; Status = $Status; Signer = $SignerSubject
      Message = "signed by $SignerSubject"
    }
  }
  if ($Status -eq 'NotSigned') {
    if ($ExpectSigned) {
      return [PSCustomObject]@{
        Result = 'FAIL'; Status = $Status; Signer = $SignerSubject
        Message = 'NO Authenticode signature, but this build is declared as signed — signing has broken'
      }
    }
    return [PSCustomObject]@{
      Result = 'warn'; Status = $Status; Signer = $SignerSubject
      Message = 'no Authenticode signature — expected, and every user meets a SmartScreen "unknown publisher" block'
    }
  }
  return [PSCustomObject]@{
    Result = 'FAIL'; Status = $Status; Signer = $SignerSubject
    Message = "the Authenticode signature is $Status — signed, but a user's machine will not trust it"
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
  # Returned plainly; callers wrap. See Get-ImportedDll.
  return @($After | Where-Object { $_ -and -not $seen.ContainsKey($_.KeyPath) })
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
    return [PSCustomObject]@{ Ok = $false; Message = 'the uninstall entry records no InstallLocation'; Executables = @(); Path = $null }
  }
  # THE REGISTRY VALUE IS NOT A CLEAN PATH, and the two installers disagree about
  # how. Observed on a real runner: NSIS writes it QUOTED —
  #   "C:\Users\runneradmin\AppData\Local\Unyt Sandbox"
  # while the MSI writes it bare with a trailing separator —
  #   C:\Users\runneradmin\AppData\Local\Unyt Sandbox\
  # Taken verbatim, the quoted form fails every Test-Path and the check reported
  # a perfectly good install as missing, then cascaded into "nothing was scanned"
  # for the import sweep. Strip the quotes, and the trailing separator with them
  # so both installers produce the same string.
  $Path = $Path.Trim().Trim('"').TrimEnd('\', '/')
  if (-not $Path) {
    return [PSCustomObject]@{ Ok = $false; Message = 'the uninstall entry records an empty InstallLocation'; Executables = @(); Path = $null }
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    return [PSCustomObject]@{ Ok = $false; Message = "InstallLocation '$Path' does not exist"; Executables = @(); Path = $Path }
  }
  $exes = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue)
  if ($exes.Count -eq 0) {
    return [PSCustomObject]@{ Ok = $false; Message = "no .exe anywhere under $Path — the installer registered itself but shipped no program"; Executables = @(); Path = $Path }
  }
  return [PSCustomObject]@{ Ok = $true; Message = "$($exes.Count) executable(s) under $Path"; Executables = $exes; Path = $Path }
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
  # NEITHER HALF MAY BE SKIPPED FOR WANT OF AN INPUT. Both are answers to
  # "did it go away", and a half that cannot run has not answered — the same rule
  # Test-UninstallEntry states as "Unknown is not a pass". Split one check per
  # step this stopped being hypothetical: InstallDir is now a FILE written by an
  # earlier step, so it is simply absent whenever that step went red, and the
  # leftover-program-files half used to fall through leaving Problems empty and
  # Ok true — "uninstalls cleanly: pass" with the whole program still on disk.
  $problems = [System.Collections.Generic.List[string]]::new()
  if (-not $EntryKeyPath) {
    $problems.Add('no uninstall entry key was recorded, so whether the registration went away cannot be answered')
  }
  elseif (@($CurrentEntries | Where-Object { $_.KeyPath -eq $EntryKeyPath }).Count -gt 0) {
    $problems.Add('the uninstall entry is still registered')
  }
  if (-not $InstallDir) {
    $problems.Add('no install directory was recorded, so whether the program files went away cannot be answered')
  }
  # An install directory that is GONE is the good case — it is only an unknown
  # one that cannot be checked.
  elseif (Test-Path -LiteralPath $InstallDir) {
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

# ── state that outlives the process ───────────────────────────────────────────
# One check per CI step means a check IS a step, and a step is its own process:
# the snapshot check 1 takes before installing, the entry check 2 finds and the
# directory check 3 normalises all have to reach the later checks over disk
# rather than in a $script: variable. UNYT_SMOKE_STATE names that directory.
#
# With it unset the suite runs the way it always has — one process, state in
# memory — so the no-flag invocation is unchanged. With it SET the disk is the
# only source, even within one process: a value is then read back through the
# same JSON round trip the next step will read it through, so a serialisation
# defect cannot hide behind a live object that happens to still be in scope.
$script:SmokeState = @{}

# Everything one cycle hands forward, named once so a fifth value cannot be
# added without Clear-SmokeState learning about it — a value the reset does not
# know is a value that survives into the next artifact's cycle.
$script:SmokeStateNames = @('Before', 'Installed', 'Entry', 'InstallDir')

function Get-SmokeStatePath {
  param([Parameter(Mandatory)][string]$Name)
  if (-not $env:UNYT_SMOKE_STATE) { return $null }
  return (Join-Path $env:UNYT_SMOKE_STATE "$Name.json")
}

function Save-SmokeState {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][AllowNull()][object]$Value
  )
  if ($script:SmokeStateNames -notcontains $Name) {
    throw "'$Name' is not one of the state values a run hands forward ($($script:SmokeStateNames -join ', '))"
  }
  $path = Get-SmokeStatePath -Name $Name
  if (-not $path) { $script:SmokeState[$Name] = $Value; return }
  if (-not (Test-Path -LiteralPath $env:UNYT_SMOKE_STATE)) {
    New-Item -ItemType Directory -Path $env:UNYT_SMOKE_STATE -Force | Out-Null
  }
  # WRAPPED IN AN OBJECT rather than written at the top level, so every state
  # file has ONE shape whatever its payload — object, list, string or flag — and
  # one `.Value` reads it. Stored bare, a list payload comes back through
  # ConvertFrom-Json's pipeline enumeration: $null for an empty snapshot, a bare
  # object for a one-entry one, correct only because every caller happens to
  # write @(Get-SmokeState ...). Guarding that at the storage layer costs a
  # property and does not depend on the next caller remembering.
  #
  # WHAT IS AND IS NOT PROVEN, so the next reader does not over-trust this. The
  # regression test pins the stored SHAPE — remove the wrapper and its format
  # assertion goes red. It does NOT prove the array rationale above: `return`
  # unrolls a list at the function boundary whether or not the payload was
  # wrapped, so with today's `@(Get-SmokeState ...)` callers the wrapper changes
  # nothing observable through this API. It is defence against a future bare
  # caller, not a fix for a live bug.
  #
  # -Depth is far past anything an entry needs because the default of 2 does not
  # refuse deeper data, it silently stringifies it.
  ConvertTo-Json -InputObject @{ Value = $Value } -Depth 20 |
    Set-Content -LiteralPath $path -Encoding utf8
}

# $null when nothing was stored, which is what turns a missing prerequisite into
# a FAIL in the check that needed it instead of a silent skip.
# Returned plainly; callers wrap. See Get-ImportedDll.
function Get-SmokeState {
  param([Parameter(Mandatory)][string]$Name)
  $path = Get-SmokeStatePath -Name $Name
  if (-not $path) {
    if ($script:SmokeState.ContainsKey($Name)) { return $script:SmokeState[$Name] }
    return $null
  }
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  return (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)).Value
}

# Start of a cycle. BOTH INSTALLERS ARE SMOKED ON THE SAME RUNNER, so without
# this the .exe's state is still on disk when the .msi's checks run: an .msi whose
# own registration check failed would then find the .exe's entry, and check 6
# would uninstall THAT while reporting it as the .msi's clean uninstall.
function Clear-SmokeState {
  foreach ($name in $script:SmokeStateNames) {
    $script:SmokeState.Remove($name)
    $path = Get-SmokeStatePath -Name $name
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
  }
}

# ── the result table ──────────────────────────────────────────────────────────
# Above the LibraryOnly guard on purpose: Invoke-Check's rule that a check body
# must return a real verdict is itself one of the things the regression test has
# to be able to drive.
$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Result { param([string]$Name, [string]$Verdict) $script:Results.Add([PSCustomObject]@{ Name = $Name; Verdict = $Verdict }) }

# The job's exit status from the rows. ONLY 'FAIL' is fatal: 'warn' is a state we
# declared we expect, so it must be visible without turning the lane red — and
# 'pass' obviously is not fatal either. Separated from Write-SummaryAndExit,
# which ends in `exit` and therefore cannot be driven by the regression test,
# because "a warn does not fail the job" is the whole claim of the declared-state
# design and an untested claim is how it quietly becomes a skip.
function Get-OverallStatus {
  param([object[]]$Results = @())
  foreach ($r in $Results) { if ($r.Verdict -eq 'FAIL') { return 1 } }
  return 0
}
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
    $last = if ($emitted.Count) { $emitted[-1] } else { $null }
    # 'warn' is a THIRD verdict, not a pass: the row shows it and the job stays
    # green, which is only ever right for a state we have declared we expect.
    if ($last -is [string] -and $last -eq 'warn') { $ok = 'warn' }
    elseif ($last -is [bool]) { $ok = $last }
    else {
      Write-Note "::error::$Name returned no true/false/warn verdict — the check is broken, not passing"
      $ok = $false
    }
  }
  catch {
    # An exception is a FAILED check, never a skipped one. A check that threw
    # and was not recorded is indistinguishable from one that passed.
    Write-Note "::error::$Name threw: $($_.Exception.Message)"
    $ok = $false
  }
  # `-is [string]` FIRST, and it is not decoration: `$true -eq 'warn'` is TRUE in
  # PowerShell, because the string coerces to a boolean and any non-empty string
  # is $true. Without the type test every passing check was recorded as a warn.
  # Same family as the array-nesting defect — a silent coercion doing something
  # reasonable-looking and wrong.
  Add-Result -Name $Name -Verdict $(
    if ($ok -is [string] -and $ok -eq 'warn') { 'warn' }
    elseif ($ok -is [bool] -and $ok) { 'pass' }
    else { 'FAIL' })
}

# The single row -Only puts on stdout, and the only thing it puts there. The
# workflow matches these against -PrintChecks to prove every check reported, so
# the name has to come from the registry rather than be restated at the call
# site. UNYT_SMOKE_RESULTS collects the rows of every step into one file, for the
# same reason UNYT_SMOKE_LOG collects the narration.
function Write-CheckRow {
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Verdict)
  $row = "$Name|$Verdict"
  Write-Output $row
  if ($env:UNYT_SMOKE_RESULTS) { Add-Content -LiteralPath $env:UNYT_SMOKE_RESULTS -Value $row }
}

# -Only's counterpart to Write-SummaryAndExit: the one row, then the step's
# status, which for a step that IS a check is that check's verdict.
#
# ABOVE THE LibraryOnly GUARD DESPITE ENDING IN `exit`, unlike
# Write-SummaryAndExit. A WARN HAS TO EXIT 0 HERE or the signing check turns the
# step — and so the job — red, which is the declared-state design failing in the
# one direction it exists to prevent; and no artifact off Windows can produce a
# warn, so the only way to drive this at all is a child process that dot-sources
# the library, seeds the row and calls it. Testing the rule alone
# (Get-OverallStatus) leaves the exit itself unpinned, and an unpinned exit is
# how "amber, job green" quietly becomes "amber, job red".
function Write-RowAndExit {
  $row = $script:Results[-1]
  Write-CheckRow -Name $row.Name -Verdict $row.Verdict
  exit (Get-OverallStatus -Results @($script:Results))
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

# ── the check registry ────────────────────────────────────────────────────────
# id -> display name -> body, in run order, and the ONE place the sequence is
# written down: the whole-suite run walks it, -Only picks one out of it, and
# -PrintChecks prints it for the workflow to build a step per check from. A
# second copy of the list anywhere — in the workflow, in a summary — is a list
# that drifts, and a check that quietly stopped running is precisely the failure
# mode this suite exists to prevent.
#
# ABOVE THE LibraryOnly GUARD, bodies included, so the regression test can drive
# them off Windows. They call functions defined BELOW it (the registry read),
# which works because a scriptblock resolves its calls when it runs rather than
# when it is created — and the guards those bodies open with return before
# reaching anything that needs a real Windows.
$script:Checks = [ordered]@{}

function Register-Check {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Body
  )
  # A repeated id would silently REPLACE the first body, so one of the two checks
  # would never run while the list still promised both.
  if ($script:Checks.Contains($Id)) { throw "check id '$Id' is already registered" }
  $script:Checks[$Id] = [PSCustomObject]@{ Id = $Id; Name = $Name; Body = $Body }
}

# Returned plainly; callers wrap. See Get-ImportedDll.
function Get-CheckId { return @($script:Checks.Keys) }

function Get-Check {
  param([Parameter(Mandatory)][string]$Id)
  # An unknown id is an error, never a no-op: a step that ran no check and exited
  # 0 is a check that silently stopped existing.
  #
  # NARRATED AS WELL AS THROWN. PowerShell's error view wraps a long message to
  # the console width and truncates the rest with an ellipsis, and the list of
  # ids that would tell the reader what to write instead is the part that gets
  # cut. Write-Note reaches the log verbatim.
  if (-not $script:Checks.Contains($Id)) {
    Write-Note "::error::unknown check id '$Id' — the ids are: $((Get-CheckId) -join ', ')"
    throw "unknown check id '$Id'"
  }
  return $script:Checks[$Id]
}

# What -PrintChecks emits, as a function so the format has one definition and the
# regression test can assert it without starting a process.
# Returned plainly; callers wrap. See Get-ImportedDll.
function Get-CheckListing {
  return @(foreach ($id in Get-CheckId) { "$id`t$((Get-Check -Id $id).Name)" })
}

# Which registered checks produced no row. The six calls used to be six literal
# statements; driving them from a list is what makes it possible to walk a
# SHORTER list than the registry, and a run that reported nothing prints an empty
# table and "All checks passed" — nothing ran, and the lane is green, which is
# this suite's defining bug rather than an edge case. The workflow asks the same
# question of the split run by matching the reported rows against -PrintChecks.
# Returned plainly; callers wrap. See Get-ImportedDll.
function Get-UnreportedCheck {
  param([object[]]$Results = @())
  $seen = @{}
  foreach ($r in $Results) { if ($r) { $seen[$r.Name] = $true } }
  return @(foreach ($id in Get-CheckId) {
      $name = (Get-Check -Id $id).Name
      if (-not $seen.ContainsKey($name)) { $name }
    })
}

# The whole suite, in registry order. Above the LibraryOnly guard with the bodies
# it drives, so the regression test can prove the run reaches every one of them
# rather than only that the registry lists them.
#
# -Ids EXISTS SO THE GUARD BELOW CAN BE DRIVEN. Walking anything short of the
# registry is the very thing it catches, so with the list hard-coded the guard
# could never fire and deleting it would change nothing observable — a guard no
# test can reach is a guard that is already gone. The run passes nothing.
function Invoke-AllChecks {
  param([string[]]$Ids = @(Get-CheckId))
  foreach ($id in $Ids) {
    $check = Get-Check -Id $id
    Invoke-Check -Name $check.Name -Body $check.Body
  }
  # A row per missing check, not one summary line: the table is what gets read,
  # and "did not run" has to be as red in it as "failed".
  $unreported = @(Get-UnreportedCheck -Results @($script:Results))
  if ($unreported.Count -gt 0) {
    Write-Note "::error::$($unreported.Count) registered check(s) never reported — they did not run:"
    foreach ($name in $unreported) {
      Write-Note "  $name"
      Add-Result -Name $name -Verdict 'FAIL'
    }
  }
}

# ── 1. it installs without asking anything ────────────────────────────────────
Register-Check -Id 'install' -Name 'installs silently' -Body {
  # A cycle starts here, so whatever a previous one left goes first — see
  # Clear-SmokeState for what that costs if it does not.
  Clear-SmokeState
  # SNAPSHOTTED HERE, before the installer runs, and persisted: check 2 finds the
  # new entry by diffing against it, and one check per step this process is gone
  # long before check 2 starts.
  Save-SmokeState -Name 'Before' -Value @(Get-UninstallEntry)
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
  Save-SmokeState -Name 'Installed' -Value $true
  return $true
}

# ── 2. it registered itself, as the version on the tin ────────────────────────
# The Windows analogue of the Linux lane's "installed version matches the
# artifact": an installer that puts files down but registers nothing leaves an
# app the user cannot remove from Settings, and a version mismatch means the
# release packaged something other than what it is named after.
Register-Check -Id 'registers' -Name 'registers an uninstall entry for this version' -Body {
  # A MISSING PREREQUISITE IS A FAILURE, and it names the check that should have
  # left the state behind. Split one per step, "the earlier step did not run" and
  # "this check passed" must never be the same colour, and a red row that does
  # not say which earlier check is missing reads as an unexplained failure of
  # this one.
  if (-not (Get-SmokeState -Name 'Installed')) {
    Write-Note "::error::nothing was installed, so there is nothing to find — the '$((Get-Check -Id 'install').Name)' check did not pass"
    return $false
  }
  $new = @(Get-NewUninstallEntry -Before @(Get-SmokeState -Name 'Before') -After @(Get-UninstallEntry))
  if ($new.Count -eq 0) {
    Write-Note '::error::the install added no uninstall entry — the app cannot be removed from Settings'
    return $false
  }
  if ($new.Count -gt 1) {
    Write-Note "::warning::the install added $($new.Count) uninstall entries:"
    foreach ($e in $new) { Write-Note "  $($e.DisplayName) $($e.DisplayVersion)" }
  }
  $entry = $new | Where-Object { $_.DisplayName -like '*Unyt*' } | Select-Object -First 1
  if (-not $entry) { $entry = $new[0] }
  # PERSISTED BEFORE THE VERSION VERDICT, deliberately: an install that
  # registered the wrong version still put files on the machine, and checks 3 and
  # 6 have to be able to inspect and remove them rather than cascade into
  # "prerequisite missing" and leave the app installed on the runner.
  Save-SmokeState -Name 'Entry' -Value $entry
  Write-Note "  $($entry.DisplayName) $($entry.DisplayVersion) -> $($entry.InstallLocation)"
  $v = Test-UninstallEntry -Entry $entry -ExpectedVersion $wantVersion
  if (-not $v.Ok) { Write-Note "::error::$($v.Message)"; return $false }
  Write-Note "OK: $($v.Message)"
  return $true
}

# ── 3. the program is actually on disk ────────────────────────────────────────
Register-Check -Id 'executable' -Name 'installs the application executable' -Body {
  $entry = Get-SmokeState -Name 'Entry'
  if (-not $entry) {
    Write-Note "::error::no uninstall entry, so no install location to check — the '$((Get-Check -Id 'registers').Name)' check did not pass"
    return $false
  }
  $d = Test-InstallDirectory -Path $entry.InstallLocation
  if (-not $d.Ok) { Write-Note "::error::$($d.Message)"; return $false }
  # The NORMALISED path, not the raw registry value — see Test-InstallDirectory.
  Save-SmokeState -Name 'InstallDir' -Value $d.Path
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
Register-Check -Id 'signed' -Name 'the installer is Authenticode-signed and trusted' -Body {
  # Get-AuthenticodeSignature is the STATUS SOURCE, because it discriminates the
  # four outcomes this check now distinguishes — Valid / NotSigned / HashMismatch
  # / NotTrusted — while signtool's exit status collapses "unsigned" and "signed
  # but broken" into one non-zero. Losing that distinction is exactly what a
  # plain skip would have cost.
  $sig = Get-AuthenticodeSignature -LiteralPath $Artifact
  $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
  $verdict = Test-SignatureVerdict -Status $sig.Status.ToString() -SignerSubject $signer `
    -ExpectSigned $script:ExpectWindowsSigned

  # signtool with /pa CORROBORATES a signature the cmdlet accepted. /pa is
  # mandatory: without it signtool applies the DRIVER signing policy and rejects
  # perfectly good application signatures. It only lives under the Windows SDK,
  # so its absence is not a failure — the cmdlet already asked the OS trust
  # store the same question.
  if ($verdict.Result -eq 'pass') {
    $signtool = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
      Sort-Object -Property FullName | Select-Object -Last 1
    if ($signtool) {
      Write-Note "  $($signtool.FullName) verify /pa /v"
      $out = & $signtool.FullName verify /pa /v $Artifact 2>&1
      $rc = $LASTEXITCODE
      foreach ($line in $out) { Write-Note "  $line" }
      if ($rc -ne 0) {
        Write-Note "::error::the certificate chain verifies but signtool rejects it under the default"
        Write-Note "  application policy (exit $rc) — a user would still be blocked."
        return $false
      }
      Write-Note '  signtool agrees under the default application policy'
    }
    Write-Note "OK: $($verdict.Message)"
    return $true
  }

  if ($verdict.Result -eq 'warn') {
    # Amber, not red, and only because we said so. The job stays green; the row
    # and the annotation both say what is being tolerated and what it costs.
    Write-Note "::warning::$($verdict.Message)"
    Write-Note '  This is the DECLARED state (ExpectWindowsSigned = $false in this script), not a'
    Write-Note '  clean bill of health. Wire a Windows code-signing certificate into'
    Write-Note '  release-tauri-app.yaml and flip that declaration to $true.'
    return 'warn'
  }

  Write-Note "::error::$($verdict.Message)"
  Write-Note '  Fix: sign the installer in release-tauri-app.yaml (a Windows code-signing certificate),'
  Write-Note '  or correct ExpectWindowsSigned in this script if the expectation is what changed.'
  return $false
}

# ── 5. what it needs from the machine ─────────────────────────────────────────
# The closest thing Windows has to the .deb's dependency gate, and the same
# question: does this artifact require something the user's machine is not
# guaranteed to have? Every shipped binary's imports, minus what the installer
# put beside it, minus what Windows ships.
Register-Check -Id 'imports' -Name 'imports nothing the machine is not guaranteed to have' -Body {
  $installDir = Get-SmokeState -Name 'InstallDir'
  if (-not $installDir) {
    Write-Note "::error::no install directory, so nothing was scanned — the '$((Get-Check -Id 'executable').Name)' check did not pass"
    return $false
  }
  $binaries = @(Get-ChildItem -LiteralPath $installDir -Recurse -Include '*.exe', '*.dll' -ErrorAction SilentlyContinue)
  $all = [System.Collections.Generic.List[string]]::new()
  $unsat = [System.Collections.Generic.List[string]]::new()
  foreach ($b in $binaries) {
    # NOT wrapped in a try: a file that cannot be parsed is a failed sweep, and
    # Get-ImportedDll throws rather than returning empty precisely so that it
    # cannot be mistaken for a binary with no imports. Invoke-Check records the
    # throw as a FAIL.
    #
    # FIRST-RUN NOTE: anything named *.dll or *.exe that is not a PE image — a
    # renamed data file, a placeholder — throws here and reds the lane. That is
    # a fixture problem, not a finding about the build. Diagnose the file before
    # treating a first red as a real dependency result.
    $imports = @(Get-ImportedDll -Path $b.FullName)
    Write-Note "  $($b.Name): $($imports.Count) imports"
    foreach ($i in $imports) { $all.Add($i) }
    # RESOLVED PER DIRECTORY, not against every file under the install root. The
    # loader looks beside the importing binary, not in a sibling subfolder, so a
    # DLL in resources\ does not satisfy an import made by the .exe at the top —
    # counting it as shipped would excuse exactly the dependency that breaks on
    # the user's machine.
    #
    # STRICTER THAN THE REAL LOADER, deliberately: the search order starts with
    # the directory of the PROCESS executable, so a DLL beside the .exe does
    # satisfy an import made by a DLL in a subfolder, which this will report.
    # That direction is a false RED — visible, and diagnosed by the path in the
    # message — rather than a false green, which is the trade this suite makes
    # everywhere else too.
    $beside = @(Get-ChildItem -LiteralPath $b.DirectoryName -Filter '*.dll' -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Name })
    foreach ($m in @(Get-UnsatisfiedImport -Imports $imports -ShippedFiles $beside)) { $unsat.Add($m) }
  }
  $missing = @($unsat | Sort-Object -Unique)
  $verdict = Get-ImportSweepVerdict -Binaries @($binaries | ForEach-Object { $_.Name }) `
    -Imports $all -Unsatisfied $missing
  if ($verdict.Ok) {
    Write-Note "OK: $($verdict.Message)"
    return $true
  }
  Write-Note "::error::$($verdict.Message)"
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
Register-Check -Id 'uninstall' -Name 'uninstalls cleanly' -Body {
  $entry = Get-SmokeState -Name 'Entry'
  if (-not $entry) {
    Write-Note "::error::no uninstall entry, so nothing can be removed — the '$((Get-Check -Id 'registers').Name)' check did not pass"
    return $false
  }
  $cmd = Get-UninstallCommand -Entry $entry
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
  #
  # Quote-aware, NOT a plain whitespace split: splitting on whitespace undoes
  # exactly the grouping Invoke-Silently exists to preserve. A quoted span stays
  # one token, quotes included, which Invoke-Silently then leaves alone as
  # already-quoted.
  #
  # WHAT THIS DOES NOT COVER, stated so the next person finishes it rather than
  # assuming it is done: NSIS writes `_?=C:\Program Files\Unyt Sandbox`
  # UNQUOTED, and an unquoted path with a space still splits here. Handling that
  # needs knowledge this tokeniser does not have — that everything after `_?=` is
  # one path, to end of string. It is not fixed now because our uninstall entry
  # is read from the registry rather than constructed, so the form we actually
  # run is whatever the installer recorded; if that turns out to carry a bare
  # `_?=`, this is the place to fix.
  $argList = @([regex]::Matches($rest, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
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
    $verdict = Test-RemovalComplete -EntryKeyPath $entry.KeyPath `
      -CurrentEntries @(Get-UninstallEntry) -InstallDir (Get-SmokeState -Name 'InstallDir')
  } while (-not $verdict.Ok -and (Get-Date) -lt $deadline)
  if (-not $verdict.Ok) {
    Write-Note '::error::60s after the uninstaller exited 0, it has not finished removing the app:'
    foreach ($p in $verdict.Problems) { Write-Note "  $p" }
    return $false
  }
  Write-Note 'OK: the uninstaller removed the program and its registration'
  return $true
}

# ABOVE the LibraryOnly guard: the list is what the workflow builds its steps
# from, so it has to be answerable without an artifact and without running
# anything at all.
if ($PrintChecks) {
  Get-CheckListing
  exit 0
}

if ($LibraryOnly) { return }

# ── from here down: the real run ──────────────────────────────────────────────

# EXIT 2 IS "THE INVOCATION IS WRONG", the code check-macos.sh and common.sh
# reserve for it across the suite, and it is not interchangeable with 1: a
# mistyped id or a missing file exiting 1 reads as an artifact that failed a
# check, and the next person debugs the build instead of the command line.
#
# The id is resolved BEFORE anything the artifact drives, so a typo is diagnosed
# as a typo rather than as whatever the artifact handling below would have
# reported first.
$script:Requested = $null
if ($Only) {
  # Get-Check narrates the id and the valid list before it throws.
  try { $script:Requested = Get-Check -Id $Only } catch { exit 2 }
}

if (-not $Artifact) {
  Write-Note '::error::usage: check-windows.ps1 [-Only <id>] <artifact.exe|artifact.msi>'
  exit 2
}
$resolved = Resolve-Path -LiteralPath $Artifact -ErrorAction SilentlyContinue
if (-not $resolved) {
  Write-Note "::error::no such artifact: $Artifact"
  exit 2
}
$Artifact = $resolved.Path

function Write-SummaryAndExit {
  $arch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE }
  else { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture }
  $label = "windows-$([System.Environment]::OSVersion.Version.Build)/$arch"
  $overall = Get-OverallStatus -Results @($script:Results)
  Write-Output ''
  Write-Output '############################################################'
  Write-Output '# summary'
  Write-Output '############################################################'
  Write-Output ('{0,-18} {1,-52} {2}' -f 'IMAGE', 'CHECK', 'RESULT')
  foreach ($r in $script:Results) {
    Write-Output ('{0,-18} {1,-52} {2}' -f $label, $r.Name, $r.Verdict)
  }
  if ($overall -eq 0) {
    Write-Output ''
    $warned = @($script:Results | Where-Object { $_.Verdict -eq 'warn' }).Count
    if ($warned) { Write-Output "All checks passed ($warned declared warning(s))." }
    else { Write-Output 'All checks passed.' }
  }
  exit $overall
}

$kind = Get-InstallerKind -Path $Artifact
$wantVersion = Get-ArtifactVersion -FileName $Artifact

Write-Note '===== runner ====='
Write-Note "  Windows $([System.Environment]::OSVersion.Version) ($env:PROCESSOR_ARCHITECTURE)"
Write-Note "  artifact: $([System.IO.Path]::GetFileName($Artifact)) ($kind)"

if ($kind -eq 'unsupported') {
  # The row carries the REQUESTED check's name. One check per step, a step that
  # reported some other check's name would leave its own unaccounted for by the
  # guard that matches the rows against -PrintChecks.
  $failed = if ($script:Requested) { $script:Requested } else { Get-Check -Id 'install' }
  Add-Result -Name $failed.Name -Verdict 'FAIL'
  Write-Note "::error::unsupported artifact '$Artifact' (expected .exe or .msi)"
  if ($script:Requested) { Write-RowAndExit }
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
  # Returned plainly; callers wrap. See Get-ImportedDll.
  return $out.ToArray()
}

# ONE DEFINITION OF THE SEQUENCE, driven two ways: one check per CI step, or the
# whole suite in this process. The bodies live in the registry above, so neither
# path can quietly run a different set from the one -PrintChecks advertises.
if ($script:Requested) {
  Invoke-Check -Name $script:Requested.Name -Body $script:Requested.Body
  Write-RowAndExit
}

Invoke-AllChecks
Write-SummaryAndExit
