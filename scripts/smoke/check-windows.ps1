<#
.SYNOPSIS
  Does the Windows build a release shipped actually install and run on an
  ordinary user's PC?

.DESCRIPTION
  check-windows.ps1 <artifact.exe|artifact.msi>   every check, then the summary
  check-windows.ps1 -Only <id> -Artifact <path>   exactly one check, one row
  check-windows.ps1 -PrintChecks                  the check list, id<TAB>name

  A CI step is its own process, so -Only persists state under UNYT_SMOKE_STATE
  and a check whose prerequisite state is absent FAILS rather than skipping.

  No UI automation: Windows Sandbox is unavailable on GitHub-hosted runners, so
  there is no pristine-machine equivalent of the Linux containers. A WebDriver
  test was built for this and deliberately discarded.

  The check carrying the most weight is the import table: every DLL the binaries
  load, minus what the installer ships, minus what Windows guarantees.

  DO NOT try to capture the app's stdout — release builds set
  windows_subsystem = "windows", so there is no console. Read the log under
  %LOCALAPPDATA%\co.unyt.unyt.sandbox\logs.

  DOES NOT COVER whether the app launches on a never-built-on machine: WebView2
  (loaded through COM, so no import check sees it), SmartScreen, and a runtime
  the build machine had. Checked by hand — docs/windows-clean-machine-check.md.

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

# Narration to stderr, table to stdout. UNYT_SMOKE_LOG collects it: one step per
# check means an uploaded log would otherwise carry only the last step's.
function Write-Note {
  param([string]$Message)
  [Console]::Error.WriteLine($Message)
  if ($env:UNYT_SMOKE_LOG) { Add-Content -LiteralPath $env:UNYT_SMOKE_LOG -Value $Message }
}

# ── what Windows itself guarantees ────────────────────────────────────────────
# THIS LIST IS THE CONTRACT: anything not here and not shipped beside the app is
# a dependency the user may not have. A lazy addition converts a finding into a
# pass. Deliberately absent: the VC++ redistributable (VCRUNTIME140/MSVCP140/
# CONCRT140) — Windows does not ship it — and WebView2Loader.dll, which Tauri
# links statically. ucrtbase and api-ms-win-crt-* ARE in-box and allowed.
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

# Returns $null when the name carries no version — "cannot answer", not a pass.
function Get-ArtifactVersion {
  param([Parameter(Mandatory)][string]$FileName)
  # The pre-release tail is PART of the version. Stopping at the `-` reads no version
  # at all out of unyt_0.101.0-dev.0_…, which every check that compares one then fails.
  $m = [regex]::Match([System.IO.Path]::GetFileName($FileName), '^unyt_([0-9][0-9.]*(?:-[0-9A-Za-z.]+)?)_')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

# What an MSI registers for a pre-release build. tauri's msi bundler cannot carry
# `0.101.0-dev.0`, so scripts/msi-version.sh gives it `0.101.0.0` and Windows writes
# THAT as the entry's DisplayVersion — while the asset keeps the tag's own name. Both
# spellings of one build; the mapping is duplicated from that script and pinned here.
function ConvertTo-MsiProductVersion {
  param([Parameter(Mandatory)][string]$Version)
  $m = [regex]::Match($Version, '^([0-9]+\.[0-9]+\.[0-9]+)-dev\.([0-9]+)$')
  if ($m.Success) { return "$($m.Groups[1].Value).$($m.Groups[2].Value)" }
  return $Version
}

function Get-InstallerKind {
  param([Parameter(Mandatory)][string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.exe' { 'nsis' }
    '.msi' { 'msi' }
    default { 'unsupported' }
  }
}

# Parsed here rather than via dumpbin, which needs a VS environment that may not
# be on PATH — and this way it is testable on any OS.
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

  # EVERY FAILURE PATH THROWS: an empty import list is indistinguishable from a
  # binary that imports nothing, and no real native PE imports nothing.
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

  # Delay-load imports are just as absent on the user's machine. The new format
  # (attribute bit 0) stores RVAs; the old one stores virtual addresses.
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
        # Refuse to guess rather than compute a nonsense RVA and report whatever
        # string lives there. A throw, not a break — a break drops the rest.
        throw "a delay-load descriptor's name field ($nameField) is below the image base ($imageBase): $Path"
      }
      $names.Add((Read-AsciiAt -Offset (Convert-RvaToOffset -Rva $nameRva)))
      $p += 32
    }
  }

  # Returned plainly; EVERY CALLER WRAPS IN @(). `return , @(...)` nests one
  # level deep, which coerced to [string[]] collapses to one space-joined name —
  # that shipped, and made the check report a finding whatever the binary imported.
  return @($names | Sort-Object -Unique)
}

# Case-insensitive throughout: import names are whatever the linker recorded, so
# a case-sensitive compare passes or fails the same DLL on spelling.
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

# The zero guard sits on the IMPORTS, not the binaries: counting files answers
# "was there anything to scan", never "did we read anything out of them".
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
# DELIBERATELY AMBER: we ship unsigned, and a permanently red check is one people
# scroll past. This is a declared-state tripwire — set it $true the day a
# certificate is wired in, and it goes red if reality and the declaration ever
# diverge in either direction. Not a skip: a skip could not see signed-but-broken.
$script:ExpectWindowsSigned = $false

# Separate from the tools that produce the status so both paths land on one rule,
# and the rule is testable off Windows. Signed+trusted -> pass; unsigned when
# expected -> warn; unsigned when not -> FAIL; signed but invalid -> always FAIL.
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

# A diff, not a lookup by key name, so "registered nothing" is distinguishable
# from "we looked in the wrong place".
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
    [AllowNull()][string]$ExpectedVersion,
    # Mandatory: defaulting to one installer would judge the other against a version
    # it never registers, and pass or fail it for the wrong reason.
    [Parameter(Mandatory)][ValidateSet('nsis', 'msi')][string]$Kind
  )
  if (-not $Entry) {
    return [PSCustomObject]@{ Ok = $false; Message = 'the install added no uninstall entry — the app cannot be removed from Settings' }
  }
  if (-not $ExpectedVersion) {
    # The artifact's name carried no version, so the check cannot answer its
    # question. Unknown is not a pass.
    return [PSCustomObject]@{ Ok = $false; Message = 'the artifact name carries no version, so nothing can be compared against it' }
  }
  $want = if ($Kind -eq 'msi') { ConvertTo-MsiProductVersion -Version $ExpectedVersion } else { $ExpectedVersion }
  if ($Entry.DisplayVersion -ne $want) {
    return [PSCustomObject]@{ Ok = $false; Message = "the artifact is named $ExpectedVersion, so the entry should read $want — it reads $($Entry.DisplayVersion)" }
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
  # The registry value is not a clean path and the installers disagree: NSIS
  # writes it QUOTED, the MSI bare with a trailing separator. Verbatim, the
  # quoted form fails every Test-Path and reported a good install as missing.
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

# Both halves matter: a leftover registration is an entry that removes nothing,
# and a leftover program is an app the user can run and can no longer uninstall.
function Test-RemovalComplete {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$EntryKeyPath,
    [object[]]$CurrentEntries = @(),
    [AllowNull()][string]$InstallDir
  )
  # Neither half may be SKIPPED for want of an input: InstallDir is a file an
  # earlier step writes, so it is absent whenever that step went red — and the
  # leftover-files half used to fall through as "uninstalls cleanly: pass".
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
  # UPPERCASE /S — NSIS's silent switch is case-sensitive, and /s runs the
  # installer INTERACTIVELY, hanging the job on a dialog.
  return "$raw /S"
}

# ── state that outlives the process ───────────────────────────────────────────
# A check IS a step and a step is its own process, so state reaches later checks
# over disk. When set, the disk is the ONLY source even within one process — so a
# serialisation defect cannot hide behind a live object still in scope.
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
  # Wrapped in an object so every state file has ONE shape and one `.Value`
  # reads it — stored bare, a list comes back through ConvertFrom-Json's pipeline
  # enumeration. Defence against a future bare caller, not a live bug: today's
  # `@(Get-SmokeState ...)` callers make the wrapper unobservable.
  # -Depth is generous because the default of 2 silently stringifies deeper data.
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

# Both installers are smoked on the same runner, so without this the .msi would
# find the .exe's entry and uninstall THAT, reporting it as its own.
function Clear-SmokeState {
  foreach ($name in $script:SmokeStateNames) {
    $script:SmokeState.Remove($name)
    $path = Get-SmokeStatePath -Name $name
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
  }
}

# ── the result table ──────────────────────────────────────────────────────────
# Above the LibraryOnly guard: the regression test has to drive Invoke-Check.
$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Result { param([string]$Name, [string]$Verdict) $script:Results.Add([PSCustomObject]@{ Name = $Name; Verdict = $Verdict }) }

# ONLY 'FAIL' is fatal — a warn must be visible without turning the lane red.
# Split from Write-SummaryAndExit (which ends in `exit`) so that claim is testable.
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
    # Must be a real boolean: `[bool](& $Body)` is true for ANY non-empty output,
    # so one unsilenced cmdlet line would turn a failing check green.
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
  # `-is [string]` FIRST: `$true -eq 'warn'` is TRUE in PowerShell, and without
  # the type test every passing check was recorded as a warn.
  Add-Result -Name $Name -Verdict $(
    if ($ok -is [string] -and $ok -eq 'warn') { 'warn' }
    elseif ($ok -is [bool] -and $ok) { 'pass' }
    else { 'FAIL' })
}

# The workflow matches these against -PrintChecks to prove every check reported,
# so the name comes from the registry rather than the call site.
function Write-CheckRow {
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Verdict)
  $row = "$Name|$Verdict"
  Write-Output $row
  if ($env:UNYT_SMOKE_RESULTS) { Add-Content -LiteralPath $env:UNYT_SMOKE_RESULTS -Value $row }
}

# A WARN HAS TO EXIT 0 here or the signing check turns the job red — the
# declared-state design failing in the one direction it exists to prevent. Above
# the LibraryOnly guard despite ending in `exit`, so the test can pin that.
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
  # Start-Process joins -ArgumentList with spaces and quotes NOTHING, so a path
  # with a space is re-split by the time the process sees it.
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
# The ONE place the sequence is written down — the run, -Only and -PrintChecks
# all read it. Above the LibraryOnly guard, bodies included, so the test can
# drive them off Windows: a scriptblock resolves its calls when it runs.
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
  # An unknown id is an error, never a no-op. Narrated as well as thrown:
  # PowerShell's error view truncates, and the id list is what gets cut.
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

# Which registered checks produced no row: a run that reported nothing otherwise
# prints an empty table and "All checks passed". Returned plainly; callers wrap.
function Get-UnreportedCheck {
  param([object[]]$Results = @())
  $seen = @{}
  foreach ($r in $Results) { if ($r) { $seen[$r.Name] = $true } }
  return @(foreach ($id in Get-CheckId) {
      $name = (Get-Check -Id $id).Name
      if (-not $seen.ContainsKey($name)) { $name }
    })
}

# -Ids exists so the guard below can be DRIVEN: with the list hard-coded the
# guard could never fire, and a guard no test can reach is already gone.
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
# An installer that registers nothing leaves an app the user cannot remove.
Register-Check -Id 'registers' -Name 'registers an uninstall entry for this version' -Body {
  # A missing prerequisite is a FAILURE, and it names the check that should have
  # left the state — otherwise it reads as an unexplained failure of this one.
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
  # Persisted BEFORE the version verdict: a wrong-version install still put
  # files down, and check 6 has to be able to remove them.
  Save-SmokeState -Name 'Entry' -Value $entry
  Write-Note "  $($entry.DisplayName) $($entry.DisplayVersion) -> $($entry.InstallLocation)"
  $v = Test-UninstallEntry -Entry $entry -ExpectedVersion $wantVersion -Kind $kind
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
# See $script:ExpectWindowsSigned: amber while we ship unsigned, red the day
# reality and that declaration diverge.
Register-Check -Id 'signed' -Name 'the installer is Authenticode-signed and trusted' -Body {
  # Get-AuthenticodeSignature is the status source: signtool's exit status
  # collapses "unsigned" and "signed but broken" into one non-zero.
  $sig = Get-AuthenticodeSignature -LiteralPath $Artifact
  $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
  $verdict = Test-SignatureVerdict -Status $sig.Status.ToString() -SignerSubject $signer `
    -ExpectSigned $script:ExpectWindowsSigned

  # /pa is MANDATORY: without it signtool applies the DRIVER signing policy and
  # rejects good application signatures. Absence is not a failure — the cmdlet
  # already asked the OS trust store.
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
# Every shipped binary's imports, minus what the installer put beside it, minus
# what Windows ships.
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
    # NOT wrapped in a try: an unparseable file is a failed sweep. Note a
    # non-PE file named *.dll reds the lane — a fixture problem, not a finding.
    $imports = @(Get-ImportedDll -Path $b.FullName)
    Write-Note "  $($b.Name): $($imports.Count) imports"
    foreach ($i in $imports) { $all.Add($i) }
    # Per DIRECTORY: the loader looks beside the importing binary, so a DLL in
    # resources\ does not satisfy the top-level .exe's import. Deliberately
    # STRICTER than the real loader — that direction is a false red, not green.
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
  # NOT $args — assigning to it inside a scriptblock shadows the invocation's own.
  # Quote-aware, not a whitespace split, which would undo the grouping.
  # DOES NOT COVER NSIS's unquoted `_?=C:\Program Files\...`; if our registry
  # entry ever carries a bare `_?=`, fix it here.
  $argList = @([regex]::Matches($rest, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
  $r = Invoke-Silently -FilePath $exe -Arguments $argList
  if ($r.TimedOut) { return $false }
  if ($r.ExitCode -ne 0) {
    Write-Note "::error::the uninstaller exited $($r.ExitCode)"
    return $false
  }
  # NSIS's uninstaller copies itself to %TEMP% and returns immediately, so the
  # entry can outlive exit 0. Poll, but keep the bound short.
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

# EXIT 2 IS "THE INVOCATION IS WRONG", not interchangeable with 1: a mistyped id
# exiting 1 reads as a failing artifact. Resolved before anything artifact-driven.
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

# Per-user (NSIS) and both views of per-machine (MSI), so nothing depends on
# knowing which the installer chose.
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
