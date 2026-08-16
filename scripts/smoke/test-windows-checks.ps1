<#
.SYNOPSIS
  Can every Windows check actually FAIL?

.DESCRIPTION
  pwsh -File scripts/smoke/test-windows-checks.ps1

  Drives the REAL functions out of check-windows.ps1 (dot-sourced -LibraryOnly),
  never a copy: every defect so far has been in the call site.

  ASSERT THROUGH THE CALL SITE'S ACTUAL SHAPE. This file drove the real functions
  and still let a defect reach a runner: assertions called them BARE while
  check 5 wraps in `@(...)`, and with `return , @(...)` the wrapped shape nests
  the array — coerced to [string[]] it became one space-joined "DLL name", and
  the check reported a finding whatever the binary imported. Assertions marked
  "wrapped:" go through `@(...)` as production does. Add one whenever production
  wraps, coerces, splits or re-types a result.

  The workflow is a SECOND call site and it is a PROCESS — it consumes stdout and
  exit status, not the functions — so those assertions start a real child pwsh.

  It runs on ANY platform, which is what makes it worth having: this repo has no
  Windows machine. The import parser is fed synthetic PE images assembled byte by
  byte here — both PE32 and PE32+, with normal and delay-load imports — and its
  output on the real shipped installer was cross-checked against GNU objdump,
  name for name.

  WHAT THIS DOES NOT PROVE. Anything that needs a real Windows: the actual
  install and uninstall, the registry, signtool, and whether an NSIS silent
  install really lands where this expects. Those are verified the first time the
  lane runs on a Windows runner.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'check-windows.ps1') -LibraryOnly

$script:Pass = 0
$script:Fail = 0
$script:Completed = $false
function Assert-That {
  param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][AllowNull()][object]$Got, [AllowNull()][object]$Want)
  $g = if ($null -eq $Got) { '<null>' } else { ($Got -join ',') }
  $w = if ($null -eq $Want) { '<null>' } else { ($Want -join ',') }
  # `-ceq`, NOT `-eq`: PowerShell's default string compare is CASE-BLIND, so this
  # could not tell NSIS's `/S` from `/s` — and `/s` hangs the job on a dialog.
  if ($g -ceq $w) { $script:Pass++ ; return }
  $script:Fail++
  [Console]::Error.WriteLine(("FAIL  {0,-62} expected [{1}], got [{2}]" -f $What, $w, $g))
}
function Assert-True { param([string]$What, [object]$Got) Assert-That -What $What -Got ([bool]$Got) -Want $true }
function Assert-False { param([string]$What, [object]$Got) Assert-That -What $What -Got ([bool]$Got) -Want $false }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("unyt-smoke-win-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {

  # A real PE, not a mocked return. Both optional-header magics, because they
  # place the data directories at different offsets — reading PE32+ with PE32's
  # layout yields a garbage RVA, and so a silent "no imports".
  function Build-TestPe {
    param(
      [Parameter(Mandatory)][string]$Path,
      [string[]]$Imports = @(),
      [string[]]$DelayImports = @(),
      [ValidateSet('PE32', 'PE32+')][string]$Format = 'PE32+',
      # The delay-load descriptor's "old" format stores virtual addresses rather
      # than RVAs; the parser has to take the image base off them.
      [switch]$OldFormatDelay
    )
    $peOffset = 0x80
    $secRva = 0x1000
    $secRaw = 0x400
    if ($Format -eq 'PE32+') { $magic = 0x20B; $optSize = 240; $imageBase = [uint64]0x140000000 }
    else { $magic = 0x10B; $optSize = 224; $imageBase = [uint64]0x400000 }

    # Section payload: import descriptors, then delay descriptors, then the name
    # strings they point at.
    $impTable = if ($Imports.Count) { ($Imports.Count + 1) * 20 } else { 0 }
    $delTable = if ($DelayImports.Count) { ($DelayImports.Count + 1) * 32 } else { 0 }
    $namesAt = $impTable + $delTable
    $sec = [System.Collections.Generic.List[byte]]::new()
    $sec.AddRange([byte[]]::new($namesAt))
    $nameRva = @{}
    foreach ($n in ($Imports + $DelayImports)) {
      if ($nameRva.ContainsKey($n)) { continue }
      $nameRva[$n] = $secRva + $sec.Count
      $sec.AddRange([System.Text.Encoding]::ASCII.GetBytes($n))
      $sec.Add(0)
    }
    $secBytes = $sec.ToArray()
    for ($i = 0; $i -lt $Imports.Count; $i++) {
      # IMAGE_IMPORT_DESCRIPTOR: the DLL name RVA sits at +12.
      [BitConverter]::GetBytes([uint32]$nameRva[$Imports[$i]]).CopyTo($secBytes, ($i * 20) + 12)
    }
    for ($i = 0; $i -lt $DelayImports.Count; $i++) {
      # IMAGE_DELAYLOAD_DESCRIPTOR: attributes at +0, name at +4.
      $base = $impTable + ($i * 32)
      $attrs = if ($OldFormatDelay) { [uint32]0 } else { [uint32]1 }
      $field = if ($OldFormatDelay) { [uint32]($imageBase + $nameRva[$DelayImports[$i]]) } else { [uint32]$nameRva[$DelayImports[$i]] }
      [BitConverter]::GetBytes($attrs).CopyTo($secBytes, $base)
      [BitConverter]::GetBytes($field).CopyTo($secBytes, $base + 4)
    }

    $file = [byte[]]::new($secRaw + $secBytes.Length)
    $file[0] = 0x4D; $file[1] = 0x5A                                   # MZ
    [BitConverter]::GetBytes([int32]$peOffset).CopyTo($file, 0x3C)     # e_lfanew
    $file[$peOffset] = 0x50; $file[$peOffset + 1] = 0x45               # PE\0\0
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($file, $peOffset + 4)   # Machine
    [BitConverter]::GetBytes([uint16]1).CopyTo($file, $peOffset + 6)        # NumberOfSections
    [BitConverter]::GetBytes([uint16]$optSize).CopyTo($file, $peOffset + 20)
    [BitConverter]::GetBytes([uint16]0x2022).CopyTo($file, $peOffset + 22)  # Characteristics

    $opt = $peOffset + 24
    [BitConverter]::GetBytes([uint16]$magic).CopyTo($file, $opt)
    if ($Format -eq 'PE32+') {
      [BitConverter]::GetBytes([uint64]$imageBase).CopyTo($file, $opt + 24)
      $dir = $opt + 112
    }
    else {
      [BitConverter]::GetBytes([uint32]$imageBase).CopyTo($file, $opt + 28)
      $dir = $opt + 96
    }
    if ($Imports.Count) {
      [BitConverter]::GetBytes([uint32]$secRva).CopyTo($file, $dir + 8)           # dir[1] import
      [BitConverter]::GetBytes([uint32]$impTable).CopyTo($file, $dir + 12)
    }
    if ($DelayImports.Count) {
      [BitConverter]::GetBytes([uint32]($secRva + $impTable)).CopyTo($file, $dir + (13 * 8))
      [BitConverter]::GetBytes([uint32]$delTable).CopyTo($file, $dir + (13 * 8) + 4)
    }

    $s = $opt + $optSize
    [System.Text.Encoding]::ASCII.GetBytes('.text').CopyTo($file, $s)
    [BitConverter]::GetBytes([uint32]$secBytes.Length).CopyTo($file, $s + 8)   # VirtualSize
    [BitConverter]::GetBytes([uint32]$secRva).CopyTo($file, $s + 12)           # VirtualAddress
    [BitConverter]::GetBytes([uint32]$secBytes.Length).CopyTo($file, $s + 16)  # SizeOfRawData
    [BitConverter]::GetBytes([uint32]$secRaw).CopyTo($file, $s + 20)           # PointerToRawData
    $secBytes.CopyTo($file, $secRaw)

    [System.IO.File]::WriteAllBytes($Path, $file)
    return $Path
  }

  $pe64 = Build-TestPe -Path (Join-Path $root 'app64.exe') -Format 'PE32+' -Imports @('KERNEL32.dll', 'VCRUNTIME140.dll')
  Assert-That 'PE32+ imports are read' (Get-ImportedDll -Path $pe64) @('KERNEL32.dll', 'VCRUNTIME140.dll')

  $pe32 = Build-TestPe -Path (Join-Path $root 'app32.exe') -Format 'PE32' -Imports @('ADVAPI32.dll', 'USER32.dll')
  Assert-That 'PE32 imports are read (the directories move)' (Get-ImportedDll -Path $pe32) @('ADVAPI32.dll', 'USER32.dll')

  # A delay-loaded DLL is just as absent from the user's machine; the app dies
  # the moment it touches that code path rather than at startup.
  $peDelay = Build-TestPe -Path (Join-Path $root 'delay.exe') -Imports @('KERNEL32.dll') -DelayImports @('WebView2Loader.dll')
  Assert-That 'delay-load imports are read too' (Get-ImportedDll -Path $peDelay) @('KERNEL32.dll', 'WebView2Loader.dll')

  # PE32 for this one: the old format's name field is a 32-bit VIRTUAL ADDRESS,
  # so it only ever occurs in 32-bit images.
  $peOld = Build-TestPe -Path (Join-Path $root 'delayold.exe') -Format 'PE32' -Imports @('KERNEL32.dll') -DelayImports @('MSVCP140.dll') -OldFormatDelay
  Assert-That 'old-format delay descriptors (VA, not RVA)' (Get-ImportedDll -Path $peOld) @('KERNEL32.dll', 'MSVCP140.dll')

  $peNone = Build-TestPe -Path (Join-Path $root 'none.exe')
  Assert-That 'a PE with no imports reports none' @(Get-ImportedDll -Path $peNone).Count 0

  Set-Content -LiteralPath (Join-Path $root 'notpe.exe') -Value 'this is not a PE image at all' -NoNewline
  $threw = $false
  try { Get-ImportedDll -Path (Join-Path $root 'notpe.exe') | Out-Null } catch { $threw = $true }
  Assert-True 'a non-PE file throws rather than reporting no imports' $threw

  [System.IO.File]::WriteAllBytes((Join-Path $root 'trunc.exe'), [byte[]]@(0x4D, 0x5A, 0, 0))
  $threw = $false
  try { Get-ImportedDll -Path (Join-Path $root 'trunc.exe') | Out-Null } catch { $threw = $true }
  Assert-True 'a truncated PE throws' $threw

  # ── THE SHAPE THE PRODUCTION CALL SITE ACTUALLY USES ────────────────────────
  # Everything above calls these BARE; production wraps in @(), which is not the
  # same thing. These test the wrapped shape.
  $wrapped = @(Get-ImportedDll -Path $pe64)
  Assert-That 'wrapped: the caller gets one element PER DLL' $wrapped.Count 2
  Assert-That 'wrapped: elements are strings, not a nested array' $wrapped[0].GetType().Name 'String'
  $wrappedUnsat = @(Get-UnsatisfiedImport -Imports $wrapped -ShippedFiles @('app64.exe'))
  Assert-That 'wrapped: the allowlist still filters' $wrappedUnsat.Count 1
  Assert-That 'wrapped: and names the real DLL' $wrappedUnsat[0] 'VCRUNTIME140.dll'
  $wrappedClean = @(Get-UnsatisfiedImport -Imports @('KERNEL32.dll', 'USER32.dll') -ShippedFiles @())
  Assert-That 'wrapped: a clean set yields nothing, not one blob' $wrappedClean.Count 0

  $bad = Join-Path $root 'badrva.exe'
  [System.IO.File]::Copy($pe64, $bad, $true)
  $b = [System.IO.File]::ReadAllBytes($bad)
  # Point the import directory at an RVA no section covers.
  [BitConverter]::GetBytes([uint32]0x7F000000).CopyTo($b, 0x80 + 24 + 112 + 8)
  [System.IO.File]::WriteAllBytes($bad, $b)
  $threw = $false
  try { Get-ImportedDll -Path $bad | Out-Null } catch { $threw = $true }
  Assert-True 'an import RVA mapping into no section throws' $threw

  $bad2 = Join-Path $root 'badsections.exe'
  [System.IO.File]::Copy($pe64, $bad2, $true)
  $b2 = [System.IO.File]::ReadAllBytes($bad2)
  # Claim more sections than the file can hold.
  [BitConverter]::GetBytes([uint16]40).CopyTo($b2, 0x80 + 6)
  [System.IO.File]::WriteAllBytes($bad2, $b2)
  $threw = $false
  try { Get-ImportedDll -Path $bad2 | Out-Null } catch { $threw = $true }
  Assert-True 'a truncated section table throws' $threw

  # An empty name drops exactly ONE DLL from the sweep, and if that one is the
  # only unsatisfied import the finding vanishes. The first descriptor's name RVA
  # points at the zero-filled start of the section, so the name reads as "".
  $bad3 = Join-Path $root 'emptyname.exe'
  [System.IO.File]::Copy($pe64, $bad3, $true)
  $b3 = [System.IO.File]::ReadAllBytes($bad3)
  [BitConverter]::GetBytes([uint32]0x1000).CopyTo($b3, 0x400 + 12)
  [System.IO.File]::WriteAllBytes($bad3, $b3)
  $threw = $false
  try { Get-ImportedDll -Path $bad3 | Out-Null } catch { $threw = $true }
  Assert-True 'an empty DLL name throws rather than being dropped' $threw

  Assert-True 'a clean sweep passes' `
  (Get-ImportSweepVerdict -Binaries @('app.exe') -Imports @('KERNEL32.dll') -Unsatisfied @()).Ok
  Assert-False 'no binaries at all fails' `
  (Get-ImportSweepVerdict -Binaries @() -Imports @() -Unsatisfied @()).Ok
  Assert-False 'binaries that yielded ZERO imports fails' `
  (Get-ImportSweepVerdict -Binaries @('app.exe', 'x.dll') -Imports @() -Unsatisfied @()).Ok
  Assert-True 'and says it is a failed parse, not a clean result' `
  ((Get-ImportSweepVerdict -Binaries @('app.exe') -Imports @() -Unsatisfied @()).Message -match 'failed parse')
  Assert-False 'an unsatisfied import fails' `
  (Get-ImportSweepVerdict -Binaries @('app.exe') -Imports @('VCRUNTIME140.dll') -Unsatisfied @('VCRUNTIME140.dll')).Ok

  Assert-That 'the VC++ runtime is NOT guaranteed by Windows' `
  (Get-UnsatisfiedImport -Imports @('KERNEL32.dll', 'VCRUNTIME140.dll') -ShippedFiles @('app.exe')) @('VCRUNTIME140.dll')
  Assert-That 'shipping the DLL beside the app satisfies it' `
  @(Get-UnsatisfiedImport -Imports @('KERNEL32.dll', 'VCRUNTIME140.dll') -ShippedFiles @('app.exe', 'VCRUNTIME140.dll')).Count 0
  # PE import names are whatever the linker recorded, so a case-sensitive
  # comparison would let the same DLL pass or fail depending on its spelling.
  Assert-That 'the check is case-insensitive on the import' `
  (Get-UnsatisfiedImport -Imports @('vcruntime140.DLL') -ShippedFiles @()) @('vcruntime140.DLL')
  Assert-That 'the check is case-insensitive on what is shipped' `
  @(Get-UnsatisfiedImport -Imports @('VCRUNTIME140.dll') -ShippedFiles @('vcruntime140.dll')).Count 0
  Assert-That 'kernel32 in any case is guaranteed' `
  @(Get-UnsatisfiedImport -Imports @('KERNEL32.DLL', 'kernel32.dll') -ShippedFiles @()).Count 0
  Assert-That 'the UCRT and its api-set forwarders are Windows components' `
  @(Get-UnsatisfiedImport -Imports @('ucrtbase.dll', 'api-ms-win-crt-runtime-l1-1-0.dll', 'ext-ms-win-foo-l1-1-0.dll') -ShippedFiles @()).Count 0
  # Tauri normally links this statically; if it is imported and not shipped,
  # that is a real packaging break, so it must not be on the allowlist.
  Assert-That 'WebView2Loader is not quietly allowlisted' `
  (Get-UnsatisfiedImport -Imports @('WebView2Loader.dll') -ShippedFiles @()) @('WebView2Loader.dll')
  Assert-That 'a clean import set produces no finding' `
  @(Get-UnsatisfiedImport -Imports @('KERNEL32.dll', 'USER32.dll', 'ole32.dll') -ShippedFiles @()).Count 0

  Assert-That 'PE bytes through to the finding' `
  (Get-UnsatisfiedImport -Imports (Get-ImportedDll -Path $pe64) -ShippedFiles @('app64.exe')) @('VCRUNTIME140.dll')

  Assert-True 'VCRUNTIME140.dll is named as the VC++ redistributable' (Test-IsVcRuntime -Dll 'VCRUNTIME140.dll')
  Assert-True 'VCRUNTIME140_1.dll too' (Test-IsVcRuntime -Dll 'VCRUNTIME140_1.dll')
  Assert-True 'MSVCP140.dll too' (Test-IsVcRuntime -Dll 'msvcp140.dll')
  Assert-True 'CONCRT140.dll too' (Test-IsVcRuntime -Dll 'CONCRT140.dll')
  Assert-False 'kernel32 is not the VC++ redistributable' (Test-IsVcRuntime -Dll 'kernel32.dll')
  Assert-False 'WebView2Loader is not either' (Test-IsVcRuntime -Dll 'WebView2Loader.dll')

  # All four outcomes pinned. The one that matters most is signed-but-invalid:
  # a plain skip would have lost it, and no declaration excuses it.
  Assert-That 'signed and trusted -> pass' `
  (Test-SignatureVerdict -Status 'Valid' -SignerSubject 'CN=Unyt').Result 'pass'
  Assert-That 'unsigned + we expect unsigned -> warn (today)' `
  (Test-SignatureVerdict -Status 'NotSigned' -ExpectSigned $false).Result 'warn'
  Assert-That 'unsigned + we expect SIGNED -> FAIL (signing broke)' `
  (Test-SignatureVerdict -Status 'NotSigned' -ExpectSigned $true).Result 'FAIL'
  Assert-That 'signed but tampered -> FAIL even when we expect unsigned' `
  (Test-SignatureVerdict -Status 'HashMismatch' -ExpectSigned $false).Result 'FAIL'
  Assert-That 'signed but untrusted -> FAIL even when we expect unsigned' `
  (Test-SignatureVerdict -Status 'NotTrusted' -ExpectSigned $false).Result 'FAIL'
  Assert-That 'an unknown status -> FAIL' `
  (Test-SignatureVerdict -Status 'UnknownError' -ExpectSigned $false).Result 'FAIL'
  Assert-That 'an empty status -> FAIL' (Test-SignatureVerdict -Status '').Result 'FAIL'
  Assert-That 'signed while expecting unsigned is still a pass' `
  (Test-SignatureVerdict -Status 'Valid' -SignerSubject 'CN=Unyt' -ExpectSigned $false).Result 'pass'
  Assert-True 'the warn says what it costs the user' `
  ((Test-SignatureVerdict -Status 'NotSigned').Message -match 'SmartScreen')
  Assert-True 'the broken-chain message says it is signed but untrusted' `
  ((Test-SignatureVerdict -Status 'NotTrusted').Message -match 'will not trust')
  # The diagnosis, not just the colour: this row and the broken-chain row are both
  # FAIL, and the actionable difference is that one means "signing broke" while
  # the other means "signing works but produces something users reject".
  Assert-True 'the expect-signed failure says signing has broken' `
  ((Test-SignatureVerdict -Status 'NotSigned' -ExpectSigned $true).Message -match 'signing has broken')

  Assert-False 'the shipped declaration expects unsigned' $script:ExpectWindowsSigned

  $script:Results.Clear()
  Invoke-Check 'warns' { 'warn' }
  Invoke-Check 'passes' { $true }
  Invoke-Check 'fails' { $false }
  Invoke-Check 'returns some other string' { 'probably-fine' }
  Assert-That "a 'warn' body records warn" $script:Results[0].Verdict 'warn'
  Assert-That 'a true body still passes' $script:Results[1].Verdict 'pass'
  Assert-That 'a false body still fails' $script:Results[2].Verdict 'FAIL'
  Assert-That 'any other string is still broken, not a warn' $script:Results[3].Verdict 'FAIL'
  $script:Results.Clear()

  $rowP = [PSCustomObject]@{ Name = 'p'; Verdict = 'pass' }
  $rowW = [PSCustomObject]@{ Name = 'w'; Verdict = 'warn' }
  $rowF = [PSCustomObject]@{ Name = 'f'; Verdict = 'FAIL' }
  Assert-That 'all passing -> exit 0' (Get-OverallStatus -Results @($rowP, $rowP)) 0
  Assert-That 'a warn alone -> exit 0 (the job stays green)' (Get-OverallStatus -Results @($rowP, $rowW)) 0
  Assert-That 'warns only -> exit 0' (Get-OverallStatus -Results @($rowW, $rowW)) 0
  Assert-That 'a FAIL -> exit 1' (Get-OverallStatus -Results @($rowP, $rowF)) 1
  Assert-That 'a warn does not mask a FAIL' (Get-OverallStatus -Results @($rowW, $rowF)) 1
  Assert-That 'no rows at all -> exit 0' (Get-OverallStatus -Results @()) 0

  Assert-That 'the version comes out of a release asset name' `
  (Get-ArtifactVersion -FileName 'unyt_0.100.0_Unyt.Sandbox_default-arc_x64_windows.exe') '0.100.0'
  Assert-That 'and out of the .msi name' `
  (Get-ArtifactVersion -FileName 'unyt_1.2.3_Unyt.Sandbox_default-arc_x64_windows.msi') '1.2.3'
  Assert-That 'a hand-built file has no version to read' (Get-ArtifactVersion -FileName 'handbuilt.exe') $null
  # THE PRE-RELEASE CHANNEL: read as far as the `-` and this returns $null, which
  # reds every check that compares a version.
  Assert-That 'a -dev asset carries its whole version, tail included' `
  (Get-ArtifactVersion -FileName 'unyt_0.101.0-dev.0_Unyt.Sandbox_default-arc_x64_windows.exe') '0.101.0-dev.0'
  Assert-That 'and so does its .msi' `
  (Get-ArtifactVersion -FileName 'unyt_0.101.0-dev.12_Unyt.Sandbox_default-arc_x64_windows.msi') '0.101.0-dev.12'
  # NSIS artifacts here are a plain .exe, never -setup.exe; a name that does not
  # match must be unknown rather than silently accepted.
  Assert-That 'a non-release name is unknown' (Get-ArtifactVersion -FileName 'unyt-setup.exe') $null
  Assert-That 'an .exe is the NSIS installer' (Get-InstallerKind -Path 'a\b\x.exe') 'nsis'
  Assert-That 'case does not matter' (Get-InstallerKind -Path 'X.EXE') 'nsis'
  Assert-That 'an .msi is the MSI' (Get-InstallerKind -Path 'x.msi') 'msi'
  Assert-That 'anything else is refused' (Get-InstallerKind -Path 'x.zip') 'unsupported'

  $a = [PSCustomObject]@{ KeyPath = 'HKCU:\...\A'; DisplayName = 'A'; DisplayVersion = '1' }
  $b = [PSCustomObject]@{ KeyPath = 'HKCU:\...\B'; DisplayName = 'B'; DisplayVersion = '1' }
  $c = [PSCustomObject]@{ KeyPath = 'HKCU:\...\Unyt'; DisplayName = 'Unyt Sandbox'; DisplayVersion = '0.100.0' }
  Assert-That 'the entry the install added is the one found' `
  (Get-NewUninstallEntry -Before @($a, $b) -After @($a, $b, $c)).KeyPath 'HKCU:\...\Unyt'
  Assert-That 'an install that registered nothing is detected' `
  @(Get-NewUninstallEntry -Before @($a, $b) -After @($a, $b)).Count 0
  Assert-That 'a first-ever entry is found on an empty machine' `
  @(Get-NewUninstallEntry -Before @() -After @($c)).Count 1

  Assert-True 'the registered version matching the artifact passes' (Test-UninstallEntry -Entry $c -ExpectedVersion '0.100.0' -Kind nsis).Ok
  Assert-False 'a version mismatch fails' (Test-UninstallEntry -Entry $c -ExpectedVersion '0.99.0' -Kind nsis).Ok
  Assert-False 'no entry at all fails' (Test-UninstallEntry -Entry $null -ExpectedVersion '0.100.0' -Kind nsis).Ok
  # Cannot answer is not a pass, and it must fail FOR THAT REASON: both verdicts
  # are red, so only the message distinguishes "no version to compare" from "the
  # versions differ".
  Assert-False 'an unknown expected version fails' (Test-UninstallEntry -Entry $c -ExpectedVersion $null -Kind nsis).Ok
  Assert-True 'and fails as unanswerable, not as a mismatch' `
  ((Test-UninstallEntry -Entry $c -ExpectedVersion $null -Kind nsis).Message -match 'carries no version')

  # ── the two installers register a -dev build under different versions ───────
  # The .msi cannot carry `0.101.0-dev.0`, so it registers the four-field form the
  # bundler was handed.
  Assert-That 'the msi form of a -dev version is the four-field one' `
  (ConvertTo-MsiProductVersion -Version '0.101.0-dev.3') '0.101.0.3'
  Assert-That 'a stable version is its own msi form' `
  (ConvertTo-MsiProductVersion -Version '0.101.0') '0.101.0'
  Assert-That 'and a channel the bundler never sees is left alone' `
  (ConvertTo-MsiProductVersion -Version '0.101.0-rc.3') '0.101.0-rc.3'
  $devMsi = [PSCustomObject]@{ KeyPath = 'HKLM:\...\Unyt'; DisplayName = 'Unyt Sandbox'; DisplayVersion = '0.101.0.0' }
  $devNsis = [PSCustomObject]@{ KeyPath = 'HKCU:\...\Unyt'; DisplayName = 'Unyt Sandbox'; DisplayVersion = '0.101.0-dev.0' }
  Assert-True 'the msi registering 0.101.0.0 for a -dev.0 artifact passes' `
  (Test-UninstallEntry -Entry $devMsi -ExpectedVersion '0.101.0-dev.0' -Kind msi).Ok
  Assert-True 'while the .exe registering the tag itself passes too' `
  (Test-UninstallEntry -Entry $devNsis -ExpectedVersion '0.101.0-dev.0' -Kind nsis).Ok
  Assert-False 'and neither is accepted under the other installer' `
  ((Test-UninstallEntry -Entry $devMsi -ExpectedVersion '0.101.0-dev.0' -Kind nsis).Ok -or
    (Test-UninstallEntry -Entry $devNsis -ExpectedVersion '0.101.0-dev.0' -Kind msi).Ok)
  Assert-False 'an msi off by one in the fourth field still fails' `
  (Test-UninstallEntry -Entry $devMsi -ExpectedVersion '0.101.0-dev.1' -Kind msi).Ok

  Assert-That 'a QuietUninstallString is used as given' `
  (Get-UninstallCommand -Entry ([PSCustomObject]@{ QuietUninstallString = '"C:\P\uninstall.exe" /S'; UninstallString = '"C:\P\uninstall.exe"' })) `
    '"C:\P\uninstall.exe" /S'
  # UPPERCASE /S. A lowercase /s is not a switch NSIS knows, so the installer
  # runs INTERACTIVELY and the job waits on a dialog nobody will click.
  Assert-That 'an NSIS uninstaller gets an uppercase /S' `
  (Get-UninstallCommand -Entry ([PSCustomObject]@{ UninstallString = '"C:\P\uninstall.exe"' })) '"C:\P\uninstall.exe" /S'
  # /I means "modify" — reusing the MSI string unchanged pops the maintenance UI.
  Assert-That 'an MSI string becomes a quiet /x by product code' `
  (Get-UninstallCommand -Entry ([PSCustomObject]@{ UninstallString = 'MsiExec.exe /I{3F2504E0-4F89-11D3-9A0C-0305E82C3301}' })) `
    'msiexec.exe /x {3F2504E0-4F89-11D3-9A0C-0305E82C3301} /quiet /norestart'
  Assert-That 'an entry with no uninstall string yields nothing' `
  (Get-UninstallCommand -Entry ([PSCustomObject]@{ DisplayName = 'X' })) $null
  Assert-That 'an msiexec string with no product code yields nothing' `
  (Get-UninstallCommand -Entry ([PSCustomObject]@{ UninstallString = 'msiexec.exe /I' })) $null

  $good = Join-Path $root 'installed'; New-Item -ItemType Directory -Path $good -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $good 'unyt-sandbox.exe') -Value 'x'
  Assert-True 'a directory holding the program passes' (Test-InstallDirectory -Path $good).Ok
  $empty = Join-Path $root 'empty'; New-Item -ItemType Directory -Path $empty -Force | Out-Null
  Assert-False 'a registered install that shipped no program fails' (Test-InstallDirectory -Path $empty).Ok
  Assert-False 'a missing install directory fails' (Test-InstallDirectory -Path (Join-Path $root 'nope')).Ok
  Assert-False 'no recorded location fails' (Test-InstallDirectory -Path $null).Ok
  # THE TWO SHAPES A REAL REGISTRY RETURNS, observed on a runner: NSIS writes
  # InstallLocation QUOTED, the MSI bare with a trailing separator. Taken
  # verbatim the quoted one fails every Test-Path.
  Assert-True 'a QUOTED InstallLocation (NSIS) is accepted' (Test-InstallDirectory -Path "`"$good`"").Ok
  Assert-True 'a trailing-separator InstallLocation (MSI) is accepted' (Test-InstallDirectory -Path "$good\").Ok
  Assert-That 'and the normalised path comes back for the caller to reuse' `
  (Test-InstallDirectory -Path "`"$good`"").Path $good
  Assert-False 'a value that is nothing but quotes fails' (Test-InstallDirectory -Path '""').Ok

  Assert-True 'a clean removal passes' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir (Join-Path $root 'nope')).Ok
  Assert-False 'an uninstaller that leaves its registration fails' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $c) -InstallDir (Join-Path $root 'nope')).Ok
  Assert-False 'an uninstaller that leaves the program behind fails' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir $good).Ok
  Assert-That 'and both problems are reported at once' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($c) -InstallDir $good).Problems.Count 2
  # A half that could not RUN has not passed: the leftover-program half used to
  # fall through as "uninstalls cleanly: pass" with the program still on disk.
  Assert-False 'no recorded install directory fails rather than skipping that half' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir $null).Ok
  # This and "left the program behind" are both red, and the actionable
  # difference is that one means nobody could tell either way.
  Assert-True 'and says the question could not be answered' `
  (((Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir $null).Problems -join ' ') `
      -match 'no install directory was recorded')
  # Same rule on the other half: an empty key matches no entry, so it would
  # report a clean deregistration having compared against nothing.
  Assert-False 'an empty entry key fails rather than matching nothing' `
  (Test-RemovalComplete -EntryKeyPath '' -CurrentEntries @($a, $c) -InstallDir (Join-Path $root 'nope')).Ok
  Assert-That 'and that is the only problem it reports' `
  (Test-RemovalComplete -EntryKeyPath '' -CurrentEntries @($a, $c) -InstallDir (Join-Path $root 'nope')).Problems.Count 1
  Assert-That 'neither half answerable reports both, and never Ok' `
  (Test-RemovalComplete -EntryKeyPath '' -CurrentEntries @() -InstallDir $null).Problems.Count 2
  Assert-False 'verifying nothing is not a clean removal' `
  (Test-RemovalComplete -EntryKeyPath '' -CurrentEntries @() -InstallDir $null).Ok
  # An install directory that is GONE is still the good case — only an unknown
  # one is unanswerable, or a successful uninstall could never report clean.
  Assert-True 'a recorded directory that the uninstaller removed still passes' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir (Join-Path $root 'nope')).Ok

  # `[bool](& $Body)` would call any non-empty output true, so one unsilenced
  # cmdlet line would turn a failing check green.
  $script:Results.Clear()
  Invoke-Check 'returns true' { $true }
  Invoke-Check 'returns false' { $false }
  Invoke-Check 'returns nothing' { }
  Invoke-Check 'throws' { throw 'boom' }
  Invoke-Check 'emits a stray line and no verdict' { 'some output nobody silenced' }
  Invoke-Check 'emits a stray line then false' { 'chatter'; $false }
  Assert-That 'a true body passes' $script:Results[0].Verdict 'pass'
  Assert-That 'a false body fails' $script:Results[1].Verdict 'FAIL'
  Assert-That 'a body returning nothing fails' $script:Results[2].Verdict 'FAIL'
  Assert-That 'a throwing body fails, never skips' $script:Results[3].Verdict 'FAIL'
  Assert-That 'stray output is not a verdict' $script:Results[4].Verdict 'FAIL'
  Assert-That 'stray output does not mask a false verdict' $script:Results[5].Verdict 'FAIL'
  $script:Results.Clear()

  if ($IsWindows) { $sh = 'cmd.exe'; $ok = @('/c', 'exit 0'); $bad = @('/c', 'exit 3'); $hang = @('/c', 'pause') }
  else { $sh = '/bin/sh'; $ok = @('-c', 'exit 0'); $bad = @('-c', 'exit 3'); $hang = @('-c', 'sleep 60') }
  $r = Invoke-Silently -FilePath $sh -Arguments $ok -TimeoutSeconds 30
  Assert-That 'a clean run reports exit 0' $r.ExitCode 0
  Assert-False 'and did not time out' $r.TimedOut
  $r = Invoke-Silently -FilePath $sh -Arguments $bad -TimeoutSeconds 30
  Assert-That 'a failing installer reports its exit code' $r.ExitCode 3
  $started = Get-Date
  $r = Invoke-Silently -FilePath $sh -Arguments $hang -TimeoutSeconds 3
  Assert-True 'a process that never finishes is reported as a timeout' $r.TimedOut
  Assert-True 'and is given up on promptly rather than hanging the job' (((Get-Date) - $started).TotalSeconds -lt 30)

  # Counts the arguments the CHILD received, because `cmd /c exit 7` and
  # `cmd /c "exit 7"` both yield 7 on Windows.
  $argCounter = Join-Path $root 'argcount.ps1'
  Set-Content -LiteralPath $argCounter -Value 'exit $args.Count'
  $pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $spacedPath = Join-Path $root 'dir with space\pkg.msi'
  $r = Invoke-Silently -FilePath $pwshExe -Arguments @('-NoProfile', '-File', $argCounter, $spacedPath) -TimeoutSeconds 60
  Assert-That 'a path containing a space arrives as ONE argument' $r.ExitCode 1

  # Pinned against LITERALS, never the registry itself: an assertion that reads
  # the ids out of the thing it checks agrees with whatever it finds.
  $expectedIds = @('install', 'registers', 'executable', 'signed', 'imports', 'uninstall')
  $expectedChecks = @(
    "install`tinstalls silently"
    "registers`tregisters an uninstall entry for this version"
    "executable`tinstalls the application executable"
    "signed`tthe installer is Authenticode-signed and trusted"
    "imports`timports nothing the machine is not guaranteed to have"
    "uninstall`tuninstalls cleanly"
  )
  $expectedNames = @($expectedChecks | ForEach-Object { ($_ -split "`t", 2)[1] })
  Assert-That 'the registry is exactly the six checks, in run order' (Get-CheckId) $expectedIds
  Assert-That 'and no id is registered twice' @(Get-CheckId | Sort-Object -Unique).Count 6
  Assert-That 'each id carries its display name' (Get-CheckListing) $expectedChecks
  foreach ($id in $expectedIds) {
    Assert-True "'$id' resolves to a runnable body" ((Get-Check -Id $id).Body -is [scriptblock])
    Assert-True "'$id' resolves to a display name" ([bool](Get-Check -Id $id).Name)
  }
  # An unknown id must be an error: a step that ran no check and exited 0 is a
  # check that silently stopped existing.
  $threw = $false
  try { Get-Check -Id 'installs' | Out-Null } catch { $threw = $true }
  Assert-True 'an unknown id is refused rather than resolving to nothing' $threw
  # A repeated id would REPLACE the first body, so one of the two checks would
  # never run while the printed list still promised both.
  $threw = $false
  try { Register-Check -Id 'install' -Name 'a second installs silently' -Body { $true } } catch { $threw = $true }
  Assert-True 'a duplicate id is refused' $threw
  Assert-That 'and the registry is left as it was' @(Get-CheckId).Count 6

  $checkScript = Join-Path $here 'check-windows.ps1'
  function Invoke-CheckScript {
    param([string[]]$ScriptArgs = @())
    # 'Continue' locally: under this file's 'Stop' a failing native command is
    # itself a terminating error on PowerShell 7.4+, so the status could never
    # be read.
    $ErrorActionPreference = 'Continue'
    $out = & $pwshExe -NoProfile -File $checkScript @ScriptArgs 2>&1
    # A lone trailing CR is the line terminator a Windows runner's child writes,
    # which is transport rather than output.
    return [PSCustomObject]@{
      ExitCode = $LASTEXITCODE
      Output   = @($out | ForEach-Object { $_.ToString().TrimEnd("`r") })
    }
  }

  $printed = Invoke-CheckScript -ScriptArgs @('-PrintChecks')
  Assert-That '-PrintChecks needs no artifact and exits 0' $printed.ExitCode 0
  Assert-That '-PrintChecks prints one line per check' $printed.Output.Count 6
  Assert-That '-PrintChecks prints <id><TAB><name>, in run order' $printed.Output $expectedChecks

  # An artifact that is neither installer: nothing is executed down this path,
  # which is what makes it safe to drive the real script on a Windows runner.
  $notInstaller = Join-Path $root 'artifact.zip'
  Set-Content -LiteralPath $notInstaller -Value 'not an installer'

  # EXIT 2, not merely non-zero: "non-zero" would hold for 1, 2, 255 or a crash.
  # Read off the ::error:: line, since PowerShell's error view truncates.
  $unknown = Invoke-CheckScript -ScriptArgs @('-Only', 'not-a-check', '-Artifact', $notInstaller)
  $unknownSaid = @($unknown.Output | Where-Object { $_ -like '::error::*' }) -join "`n"
  Assert-That '-Only with an unknown id exits 2, the bad-invocation code' $unknown.ExitCode 2
  Assert-True 'and names the id it did not recognise' ($unknownSaid -match [regex]::Escape('not-a-check'))
  Assert-True 'and lists every id it does know, in full' `
  ($unknownSaid -match [regex]::Escape(($expectedIds -join ', ')))

  # The rest of the bad-invocation class, so none of it can read as a checked
  # artifact that failed.
  $noArtifact = Invoke-CheckScript -ScriptArgs @('-Only', 'signed')
  Assert-That 'no artifact at all is a bad invocation' $noArtifact.ExitCode 2
  Assert-True 'and says how to invoke it' `
  ((@($noArtifact.Output | Where-Object { $_ -like '::error::*' }) -join "`n") -match 'usage:')
  $missingFile = Invoke-CheckScript -ScriptArgs @((Join-Path $root 'no-such-artifact.exe'))
  Assert-That 'an artifact path that resolves to nothing is a bad invocation' $missingFile.ExitCode 2
  Assert-True 'and names the path it could not find' `
  ((@($missingFile.Output | Where-Object { $_ -like '::error::*' }) -join "`n") -match 'no such artifact')

  # ONE ROW, AND IT IS THE REQUESTED CHECK'S: a step reporting some other check's
  # name leaves its own unaccounted for by the did-it-run guard, and makes the
  # check it named look reported.
  $unsupported = Invoke-CheckScript -ScriptArgs @('-Only', 'uninstall', '-Artifact', $notInstaller)
  Assert-That '-Only reports the requested check, whatever went wrong' `
  @($unsupported.Output | Where-Object { $_ -match '\|(pass|FAIL|warn)$' }) 'uninstalls cleanly|FAIL'
  Assert-That 'and exits 1 on it' $unsupported.ExitCode 1
  Assert-False '-Only prints no summary table' (($unsupported.Output -join "`n") -match '# summary')

  # The no-flag invocation is unchanged: every check, then the table.
  $whole = Invoke-CheckScript -ScriptArgs @($notInstaller)
  Assert-That 'the whole-suite path still refuses an unsupported artifact' $whole.ExitCode 1
  Assert-True 'and still prints its summary table' `
  (($whole.Output -join "`n") -match 'installs silently\s+FAIL')

  # Under StrictMode a dropped field does not read back as $null, it THROWS —
  # so a lossy serialisation reports a perfectly good install as broken.
  $stateRound = Join-Path $root 'state-roundtrip'
  # The shape a real registry read produces: every field present, some of them
  # $null, and a path with a space in it (%LOCALAPPDATA%\Unyt Sandbox).
  $spaced = [PSCustomObject]@{
    KeyPath              = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Unyt Sandbox'
    DisplayName          = 'Unyt Sandbox'
    DisplayVersion       = '0.100.0'
    InstallLocation      = 'C:\Users\runneradmin\AppData\Local\Unyt Sandbox'
    UninstallString      = '"C:\Users\runneradmin\AppData\Local\Unyt Sandbox\uninstall.exe"'
    QuietUninstallString = $null
  }
  $touched = @('KeyPath', 'DisplayName', 'DisplayVersion', 'InstallLocation', 'UninstallString', 'QuietUninstallString')
  $env:UNYT_SMOKE_STATE = $stateRound
  try {
    Save-SmokeState -Name 'Entry' -Value $spaced
    # The disk must be the ONLY source, or every round-trip assertion below reads
    # the original object. Proven by rewriting the file underneath.
    Assert-True 'a state directory makes the value a file on disk' `
    (Test-Path -LiteralPath (Join-Path $stateRound 'Entry.json'))
    # The stored SHAPE, asserted before anything reads through it: the tamper
    # fixture below is written in that shape, so a change to it would otherwise
    # surface as an exception downstream rather than as "the format moved".
    Assert-True 'and it is stored under the {"Value": ...} wrapper' `
    ((Get-Content -LiteralPath (Join-Path $stateRound 'Entry.json') -Raw) -match '"Value"\s*:')
    Set-Content -LiteralPath (Join-Path $stateRound 'Entry.json') `
      -Value '{"Value":{"KeyPath":"rewritten underneath"}}'
    # Read defensively so a moved format is a named assertion failure rather than
    # a StrictMode throw that aborts the whole run.
    $tampered = Get-SmokeState -Name 'Entry'
    $tamperedKey = if ($tampered -and $tampered.PSObject.Properties.Name -contains 'KeyPath') {
      $tampered.KeyPath
    }
    else { '<unreadable — the stored shape moved>' }
    Assert-That 'and every read goes back to that file' $tamperedKey 'rewritten underneath'

    Save-SmokeState -Name 'Entry' -Value $spaced
    $back = Get-SmokeState -Name 'Entry'
    foreach ($p in $touched) {
      Assert-True "the round trip keeps $p, $null-valued or not" ($back.PSObject.Properties.Name -contains $p)
    }
    # Read the way the checks read them, under this file's own StrictMode.
    $threw = $false
    try { foreach ($p in $touched) { $null = $back.$p } } catch { $threw = $true }
    Assert-False 'every property the checks touch reads back without throwing' $threw
    Assert-That 'a path with a space survives verbatim' $back.InstallLocation $spaced.InstallLocation
    Assert-That 'a $null property comes back $null rather than missing' $back.QuietUninstallString $null
    # THE REAL CONSUMERS, not just the fields: a lost property bites here.
    Assert-That 'the round-tripped entry yields the same uninstall command' `
    (Get-UninstallCommand -Entry $back) (Get-UninstallCommand -Entry $spaced)
    Assert-That 'and it is still the uppercase NSIS silent switch' `
    (Get-UninstallCommand -Entry $back) '"C:\Users\runneradmin\AppData\Local\Unyt Sandbox\uninstall.exe" /S'
    Assert-That 'the round-tripped entry gives the same version verdict' `
    (Test-UninstallEntry -Entry $back -ExpectedVersion '0.100.0' -Kind nsis).Ok `
    (Test-UninstallEntry -Entry $spaced -ExpectedVersion '0.100.0' -Kind nsis).Ok
    Assert-True 'and that verdict is still the passing one' (Test-UninstallEntry -Entry $back -ExpectedVersion '0.100.0' -Kind nsis).Ok
    Assert-False 'while a mismatch still fails after a round trip' (Test-UninstallEntry -Entry $back -ExpectedVersion '0.99.0' -Kind nsis).Ok

    # These do NOT pin the storage wrapper — `return` unrolls a list either way;
    # the stored-shape assertion above is what pins it.
    Save-SmokeState -Name 'Before' -Value @()
    Assert-That 'wrapped: an EMPTY snapshot comes back empty, not missing' @(Get-SmokeState -Name 'Before').Count 0
    Save-SmokeState -Name 'Before' -Value @($spaced)
    Assert-That 'wrapped: a ONE-entry snapshot stays a list of one' @(Get-SmokeState -Name 'Before').Count 1
    $other = [PSCustomObject]@{ KeyPath = 'HKCU:\...\Other'; DisplayName = 'Other'; DisplayVersion = '1' }
    Assert-That 'wrapped: nothing looks new against a round-tripped snapshot' `
    @(Get-NewUninstallEntry -Before @(Get-SmokeState -Name 'Before') -After @($spaced)).Count 0
    Assert-That 'wrapped: and a new entry is still spotted against it' `
    @(Get-NewUninstallEntry -Before @(Get-SmokeState -Name 'Before') -After @($spaced, $other)).Count 1

    Save-SmokeState -Name 'Installed' -Value $true
    Assert-True 'the installed flag survives the round trip' (Get-SmokeState -Name 'Installed')
    Assert-That 'and comes back a boolean, not the string "True"' `
    (Get-SmokeState -Name 'Installed').GetType().Name 'Boolean'
    # $null, and not an error — this is what makes a missing prerequisite a FAIL
    # in the check that needed it rather than a crash or a skip.
    Assert-That 'a value that was never stored is absent' (Get-SmokeState -Name 'InstallDir') $null

    # BOTH INSTALLERS ARE SMOKED ON THE SAME RUNNER: an .msi whose own
    # registration failed would find the .exe's entry, and check 6 would
    # uninstall THAT while reporting it as the .msi's clean uninstall.
    Save-SmokeState -Name 'InstallDir' -Value 'C:\Users\runneradmin\AppData\Local\Unyt Sandbox'
    Clear-SmokeState
    foreach ($name in @('Before', 'Installed', 'Entry', 'InstallDir')) {
      Assert-That "starting a cycle drops the previous $name" (Get-SmokeState -Name $name) $null
    }
    Assert-That 'and leaves no state file behind to be read back' `
    @(Get-ChildItem -LiteralPath $stateRound -Filter '*.json' -ErrorAction SilentlyContinue).Count 0
    # The reset walks a list, so a value the list does not know about would
    # survive it. Refusing an unlisted name is what keeps the two in step.
    $threw = $false
    try { Save-SmokeState -Name 'SomethingNew' -Value 'x' } catch { $threw = $true }
    Assert-True 'a state value the reset does not know about is refused' $threw

    # At the CALL SITE: the reset must be the first thing the install check
    # does, so a cycle cannot read the previous one's state when this one fails.
    Save-SmokeState -Name 'Installed' -Value $true
    Save-SmokeState -Name 'Entry' -Value $spaced
    Save-SmokeState -Name 'InstallDir' -Value 'C:\Users\runneradmin\AppData\Local\Unyt Sandbox'
    $script:Results.Clear()
    $install = Get-Check -Id 'install'
    Invoke-Check -Name $install.Name -Body $install.Body
    Assert-That 'the install check fails with no real run behind it' $script:Results[0].Verdict 'FAIL'
    foreach ($name in @('Installed', 'Entry', 'InstallDir')) {
      Assert-That "and it dropped the previous cycle's $name before failing" (Get-SmokeState -Name $name) $null
    }
    $script:Results.Clear()
  }
  finally { $env:UNYT_SMOKE_STATE = $null }

  # The real call site is TWO processes: what check 3 writes, check 5 reads
  # having never seen it. The whole handoff minus the install itself.
  $installed = Join-Path $root 'handoff/Unyt Sandbox'
  New-Item -ItemType Directory -Path $installed -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $installed 'unyt-sandbox.exe') -Value 'x'
  # Named like a release asset and never executed: -Only executable reads the
  # state and inspects that directory, and touches the artifact only to name it.
  $fakeExe = Join-Path $root 'unyt_0.100.0_Unyt.Sandbox_default-arc_x64_windows.exe'
  Set-Content -LiteralPath $fakeExe -Value 'x'
  $env:UNYT_SMOKE_STATE = Join-Path $root 'handoff/state'
  try {
    # QUOTED, the way NSIS really writes InstallLocation, so the normalisation
    # check 3 does is what the next step inherits rather than the raw value.
    Save-SmokeState -Name 'Entry' -Value ([PSCustomObject]@{
        KeyPath              = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Unyt Sandbox'
        DisplayName          = 'Unyt Sandbox'
        DisplayVersion       = '0.100.0'
        InstallLocation      = "`"$installed`""
        UninstallString      = $null
        QuietUninstallString = $null
      })
    $step = Invoke-CheckScript -ScriptArgs @('-Only', 'executable', '-Artifact', $fakeExe)
    Assert-That 'a step reads the entry a previous PROCESS left behind' `
    @($step.Output | Where-Object { $_ -match '\|(pass|FAIL|warn)$' }) 'installs the application executable|pass'
    Assert-That 'and a passing step exits 0' $step.ExitCode 0
    Assert-That 'and hands the NORMALISED directory on to the next step' `
    (Get-SmokeState -Name 'InstallDir') $installed
  }
  finally { $env:UNYT_SMOKE_STATE = $null }

  # With no state directory the suite is one process and state stays in memory, so
  # the reset has to reach that copy too.
  Save-SmokeState -Name 'InstallDir' -Value 'C:\Program Files\Unyt Sandbox'
  Assert-That 'with no state directory a value is kept in memory' `
  (Get-SmokeState -Name 'InstallDir') 'C:\Program Files\Unyt Sandbox'
  Clear-SmokeState
  Assert-That 'and the reset clears the in-memory copy as well' (Get-SmokeState -Name 'InstallDir') $null

  # -Only puts exactly one line on stdout, and the workflow matches it against
  # -PrintChecks to prove the check reported at all.
  $rowsFile = Join-Path $root 'rows.txt'
  $env:UNYT_SMOKE_RESULTS = $rowsFile
  try {
    Assert-That 'the row is <display name>|<verdict>' `
    (Write-CheckRow -Name 'installs silently' -Verdict 'pass') 'installs silently|pass'
    Assert-That 'a warn row says warn, not pass' `
    (Write-CheckRow -Name 'the installer is Authenticode-signed and trusted' -Verdict 'warn') `
      'the installer is Authenticode-signed and trusted|warn'
    Assert-That 'every row also lands in UNYT_SMOKE_RESULTS' @(Get-Content -LiteralPath $rowsFile).Count 2
    Assert-That 'appended in the order they were produced' `
    @(Get-Content -LiteralPath $rowsFile)[0] 'installs silently|pass'
  }
  finally { $env:UNYT_SMOKE_RESULTS = $null }
  Assert-That 'the row still prints with no results file configured' `
  (Write-CheckRow -Name 'uninstalls cleanly' -Verdict 'FAIL') 'uninstalls cleanly|FAIL'

  # The signing check is a step of its own, so its warn has to exit 0 or the
  # amber row turns the job red after all.
  foreach ($case in @(
      @{ Body = { $true }; Verdict = 'pass'; Status = 0 },
      @{ Body = { 'warn' }; Verdict = 'warn'; Status = 0 },
      @{ Body = { $false }; Verdict = 'FAIL'; Status = 1 }
    )) {
    $script:Results.Clear()
    Invoke-Check 'one check, one step' $case.Body
    Assert-That "-Only: a $($case.Verdict) body records $($case.Verdict)" $script:Results[0].Verdict $case.Verdict
    Assert-That "-Only: and the rule maps it to $($case.Status)" `
    (Get-OverallStatus -Results @($script:Results)) $case.Status
  }
  $script:Results.Clear()

  # The same rule at the ACTUAL exit: rewriting Write-RowAndExit to
  # `if pass 0 else 1` leaves every assertion above green while reddening the
  # signing step on every Windows run.
  function Invoke-RowExit {
    param([Parameter(Mandatory)][string]$Verdict)
    $ErrorActionPreference = 'Continue'
    $quoted = $checkScript.Replace("'", "''")
    $cmd = ". '$quoted' -LibraryOnly; " +
    "Add-Result -Name 'the installer is Authenticode-signed and trusted' -Verdict '$Verdict'; " +
    'Write-RowAndExit'
    $out = & $pwshExe -NoProfile -Command $cmd 2>&1
    return [PSCustomObject]@{
      ExitCode = $LASTEXITCODE
      Output   = @($out | ForEach-Object { $_.ToString().TrimEnd("`r") })
    }
  }
  $warnExit = Invoke-RowExit -Verdict 'warn'
  Assert-That 'a warn step really exits 0 — the amber row keeps the job green' $warnExit.ExitCode 0
  Assert-That 'while its row still says warn, not pass' `
  @($warnExit.Output | Where-Object { $_ -match '\|' }) 'the installer is Authenticode-signed and trusted|warn'
  Assert-That 'a passing step really exits 0' (Invoke-RowExit -Verdict 'pass').ExitCode 0
  Assert-That 'a FAIL step really exits 1' (Invoke-RowExit -Verdict 'FAIL').ExitCode 1

  # ── a missing prerequisite is a FAILURE, and it says which ──────────────────
  # Missing state must be red AND must name the check that should have produced
  # it. Only ::error:: lines are matched, so Invoke-Check's banner cannot satisfy
  # the assertion by accident, and each case pins its own sentence.
  $stateEmpty = Join-Path $root 'state-empty'
  New-Item -ItemType Directory -Path $stateEmpty -Force | Out-Null
  $noteLog = Join-Path $root 'notes.log'
  $env:UNYT_SMOKE_STATE = $stateEmpty
  $env:UNYT_SMOKE_LOG = $noteLog
  try {
    foreach ($case in @(
        @{ Id = 'registers'; Needs = 'installs silently'
          Says = 'nothing was installed, so there is nothing to find'
        },
        @{ Id = 'executable'; Needs = 'registers an uninstall entry for this version'
          Says = 'no uninstall entry, so no install location to check'
        },
        @{ Id = 'imports'; Needs = 'installs the application executable'
          Says = 'no install directory, so nothing was scanned'
        },
        @{ Id = 'uninstall'; Needs = 'registers an uninstall entry for this version'
          Says = 'no uninstall entry, so nothing can be removed'
        }
      )) {
      Remove-Item -LiteralPath $noteLog -Force -ErrorAction SilentlyContinue
      $script:Results.Clear()
      $check = Get-Check -Id $case.Id
      Invoke-Check -Name $check.Name -Body $check.Body
      Assert-That "'$($case.Id)' with no state FAILS rather than passing" $script:Results[0].Verdict 'FAIL'
      $said = @(Get-Content -LiteralPath $noteLog -ErrorAction SilentlyContinue |
          Where-Object { $_ -like '::error::*' }) -join "`n"
      Assert-True "'$($case.Id)' names '$($case.Needs)' as the check that is missing" `
      ($said -match [regex]::Escape($case.Needs))
      Assert-True "'$($case.Id)' gives its OWN diagnosis, not a sibling's" `
      ($said -match [regex]::Escape($case.Says))
    }
  }
  finally {
    $env:UNYT_SMOKE_STATE = $null
    $env:UNYT_SMOKE_LOG = $null
  }
  $script:Results.Clear()

  # ── uninstall demands its directory BEFORE it removes anything ──────────────
  # Entry present, InstallDir absent — the one combination the loop above cannot
  # reach, since with no state at all the entry guard fires first.
  # A REAL PROGRAM behind UninstallString: aimed at a path no runner has, the run
  # throws first and "never started the uninstaller" becomes unable to fail.
  if ($IsWindows) {
    $stub = Join-Path $root 'uninstall-stub.cmd'
    Set-Content -LiteralPath $stub -Value '@exit /b 0' -Encoding ascii
  }
  else {
    $stub = Join-Path $root 'uninstall-stub.sh'
    Set-Content -LiteralPath $stub -Value "#!/bin/sh`nexit 0" -Encoding ascii
    & chmod +x $stub
  }
  $stateNoDir = Join-Path $root 'state-entry-only'
  New-Item -ItemType Directory -Path $stateNoDir -Force | Out-Null
  $env:UNYT_SMOKE_STATE = $stateNoDir
  $env:UNYT_SMOKE_LOG = $noteLog
  try {
    Assert-That 'the stub is a program the check really would have run' `
    (Invoke-Silently -FilePath $stub -Arguments @('/S')).ExitCode 0
    Remove-Item -LiteralPath $noteLog -Force -ErrorAction SilentlyContinue
    $script:Results.Clear()
    Save-SmokeState -Name 'Entry' -Value ([PSCustomObject]@{
        KeyPath              = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Unyt Sandbox'
        DisplayName          = 'Unyt Sandbox'
        DisplayVersion       = '0.101.0-dev.0'
        InstallLocation      = 'C:\Users\runneradmin\AppData\Local\Unyt Sandbox'
        UninstallString      = "`"$stub`""
        QuietUninstallString = $null
      })
    $check = Get-Check -Id 'uninstall'
    Invoke-Check -Name $check.Name -Body $check.Body
    Assert-That 'uninstall with no recorded directory FAILS' $script:Results[0].Verdict 'FAIL'
    $log = @(Get-Content -LiteralPath $noteLog -ErrorAction SilentlyContinue)
    $said = @($log | Where-Object { $_ -like '::error::*' }) -join "`n"
    Assert-True "'uninstall' names the check that should have recorded the directory" `
    ($said -match [regex]::Escape('installs the application executable'))
    Assert-True "'uninstall' says the directory is what is missing" `
    ($said -match [regex]::Escape('no install directory was recorded'))
    # Invoke-Silently narrates every start, so the stub's absence from the log is
    # the uninstaller having never been launched.
    Assert-False "'uninstall' never started the uninstaller" `
    (($log -join "`n") -match [regex]::Escape($stub))
  }
  finally {
    $env:UNYT_SMOKE_STATE = $null
    $env:UNYT_SMOKE_LOG = $null
  }
  $script:Results.Clear()

  # ── the whole-suite run reaches every check ─────────────────────────────────
  # Asserted from the NARRATION, not the row count: Invoke-AllChecks adds a FAIL
  # row for any check that did not report, so counting rows would be satisfied by
  # the very guard being tested.
  Remove-Item -LiteralPath $noteLog -Force -ErrorAction SilentlyContinue
  $script:Results.Clear()
  $env:UNYT_SMOKE_STATE = $stateEmpty
  $env:UNYT_SMOKE_LOG = $noteLog
  try { Invoke-AllChecks }
  finally {
    $env:UNYT_SMOKE_STATE = $null
    $env:UNYT_SMOKE_LOG = $null
  }
  $ran = (Get-Content -LiteralPath $noteLog -Raw)
  foreach ($name in $expectedNames) {
    Assert-True "the whole-suite run actually entered '$name'" `
    ($ran -match "===== $([regex]::Escape($name)) =====")
  }
  Assert-That 'and reported a row per check, in registry order' `
  @($script:Results | ForEach-Object { $_.Name }) $expectedNames
  Assert-False 'with nothing left unreported' ($ran -match 'never reported')
  Assert-That 'and every one went red rather than passing on nothing' `
  @($script:Results | Where-Object { $_.Verdict -eq 'FAIL' }).Count 6

  # THE GUARD AT ITS CALL SITE, driven with a short list. Asserting only the
  # healthy run checks for the ABSENCE of the message, which deleting the
  # producer would satisfy.
  Remove-Item -LiteralPath $noteLog -Force -ErrorAction SilentlyContinue
  $script:Results.Clear()
  $env:UNYT_SMOKE_STATE = $stateEmpty
  $env:UNYT_SMOKE_LOG = $noteLog
  try { Invoke-AllChecks -Ids @('registers') }
  finally {
    $env:UNYT_SMOKE_STATE = $null
    $env:UNYT_SMOKE_LOG = $null
  }
  $short = Get-Content -LiteralPath $noteLog -Raw
  Assert-That 'a run that walked a short list still reports a row per check' @($script:Results).Count 6
  Assert-That 'and nothing is left unreported once the guard has run' `
  @(Get-UnreportedCheck -Results @($script:Results)).Count 0
  Assert-True 'the log says checks never reported' ($short -match 'never reported')
  Assert-True 'and names one that did not run' ($short -match [regex]::Escape('uninstalls cleanly'))
  Assert-That 'a check that never ran is recorded FAIL, never pass' `
  @($script:Results | Where-Object { $_.Name -eq 'uninstalls cleanly' -and $_.Verdict -eq 'FAIL' }).Count 1
  $script:Results.Clear()

  $rows = @($expectedNames | ForEach-Object { [PSCustomObject]@{ Name = $_; Verdict = 'pass' } })
  Assert-That 'a run that reported every check has nothing unreported' `
  @(Get-UnreportedCheck -Results $rows).Count 0
  Assert-That 'a run missing one names it' `
  (Get-UnreportedCheck -Results @($rows | Where-Object { $_.Name -ne 'uninstalls cleanly' })) 'uninstalls cleanly'
  Assert-That 'a run that reported nothing names all six' `
  (Get-UnreportedCheck -Results @()) $expectedNames
  $script:Results.Clear()

  # Reached only if every assertion above ran. See the guard in `finally`.
  $script:Completed = $true
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  # THIS FILE'S OWN ZERO GUARD: an injected `exit 0` or an early return would
  # otherwise end the run with no output and status 0, which reads as "every
  # check is proven able to fail" while nothing was proven.
  if (-not $script:Completed) {
    [Console]::Error.WriteLine('::error::the regression test exited before completing — an early exit, a truncated file, or a killed run. NOTHING was proven; do not read this as a pass.')
    exit 1
  }
}

Write-Output "windows check regression: $script:Pass passed, $script:Fail failed"
# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "3 passed, 0 failed" and exit 0. Raise it when adding
# assertions.
if ($script:Pass -lt 237) {
  [Console]::Error.WriteLine("::error::only $script:Pass assertions ran; expected at least 237 — the test file is truncated or a block was skipped")
  exit 1
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
