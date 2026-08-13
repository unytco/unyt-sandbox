<#
.SYNOPSIS
  Can every Windows check actually FAIL?

.DESCRIPTION
  pwsh -File scripts/smoke/test-windows-checks.ps1

  WHY THIS EXISTS. This suite's hard rule is that a check must be able to fail:
  nine defects in it made a check silently pass, and every one was found by
  feeding a deliberately broken input, never by reading the code.

  It drives the REAL functions out of check-windows.ps1 — dot-sourced with
  -LibraryOnly — rather than a copy of them, for the same reason test-oracle.sh
  drives common.sh's matchers: every oracle bug so far has been in the call
  site, and a copy would pass while the real script stayed broken.

  AND THAT IS NOT ENOUGH ON ITS OWN — ASSERT THROUGH THE CALL SITE'S ACTUAL
  SHAPE. This file drove the real functions and still let a defect reach a real
  runner: the assertions called them BARE while check 5 wraps them in `@(...)`,
  and with `return , @(...)` those two shapes differ — the wrapped one nests the
  array a level, which then coerces into [string[]] as a single space-joined
  "DLL name". The allowlist matched nothing, every import list became one
  unrecognised entry, and the check reported a finding regardless of what the
  binary imported. It took the first real Windows run to see it, and it nearly
  had a defect filed against the app that does not exist. Assertions marked
  "wrapped:" below go through `@(...)` exactly as production does; keep them,
  and add one whenever production wraps, coerces, splits or re-types a result.

  It runs on ANY platform, which is what makes it worth having: this repo has no
  Windows machine, so without it the checks would ship having never been
  observed to go either way. The import parser is fed synthetic PE images
  assembled byte by byte here — both PE32 and PE32+, with normal and delay-load
  imports — and its output on the real shipped installer was cross-checked
  against GNU objdump during development, on both formats, name for name.

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
  # `-ceq`, NOT `-eq`. PowerShell's default string comparison is CASE-BLIND, so
  # this assertion could not tell NSIS's `/S` from `/s` — and `/s` is not a
  # switch NSIS knows, so the uninstaller would run interactively and hang the
  # job. An assertion that cannot fail is the bug this whole file exists to
  # prevent, and it was found here by mutation, not by reading.
  if ($g -ceq $w) { $script:Pass++ ; return }
  $script:Fail++
  [Console]::Error.WriteLine(("FAIL  {0,-62} expected [{1}], got [{2}]" -f $What, $w, $g))
}
function Assert-True { param([string]$What, [object]$Got) Assert-That -What $What -Got ([bool]$Got) -Want $true }
function Assert-False { param([string]$What, [object]$Got) Assert-That -What $What -Got ([bool]$Got) -Want $false }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("unyt-smoke-win-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {

  # ── a PE image, assembled byte by byte ──────────────────────────────────────
  # The import table is the only place the check's central question is answered,
  # so the fixture has to be a real PE rather than a mocked return value. Both
  # optional-header magics are built because they place the data directories at
  # different offsets — read PE32+ with PE32's layout and the import RVA is
  # garbage, which is a silent "no imports found", which is a silent pass.
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

  # ── Get-ImportedDll ─────────────────────────────────────────────────────────
  $pe64 = Build-TestPe -Path (Join-Path $root 'app64.exe') -Format 'PE32+' -Imports @('KERNEL32.dll', 'VCRUNTIME140.dll')
  Assert-That 'PE32+ imports are read' (Get-ImportedDll -Path $pe64) @('KERNEL32.dll', 'VCRUNTIME140.dll')

  $pe32 = Build-TestPe -Path (Join-Path $root 'app32.exe') -Format 'PE32' -Imports @('ADVAPI32.dll', 'USER32.dll')
  Assert-That 'PE32 imports are read (the directories move)' (Get-ImportedDll -Path $pe32) @('ADVAPI32.dll', 'USER32.dll')

  # A delay-loaded DLL is just as absent from the user's machine; the app dies
  # the moment it touches that code path rather than at startup.
  $peDelay = Build-TestPe -Path (Join-Path $root 'delay.exe') -Imports @('KERNEL32.dll') -DelayImports @('WebView2Loader.dll')
  Assert-That 'delay-load imports are read too' (Get-ImportedDll -Path $peDelay) @('KERNEL32.dll', 'WebView2Loader.dll')

  # PE32 for this one: the old format's name field is a 32-bit VIRTUAL ADDRESS,
  # which is why it only ever occurs in 32-bit images — a 64-bit image base does
  # not fit in it.
  $peOld = Build-TestPe -Path (Join-Path $root 'delayold.exe') -Format 'PE32' -Imports @('KERNEL32.dll') -DelayImports @('MSVCP140.dll') -OldFormatDelay
  Assert-That 'old-format delay descriptors (VA, not RVA)' (Get-ImportedDll -Path $peOld) @('KERNEL32.dll', 'MSVCP140.dll')

  $peNone = Build-TestPe -Path (Join-Path $root 'none.exe')
  Assert-That 'a PE with no imports reports none' @(Get-ImportedDll -Path $peNone).Count 0

  # A file that is not a PE must THROW, not return an empty list: "no imports"
  # and "could not be read" must never be the same answer, or a check that
  # scanned nothing reports the same green row as a clean scan.
  Set-Content -LiteralPath (Join-Path $root 'notpe.exe') -Value 'this is not a PE image at all' -NoNewline
  $threw = $false
  try { Get-ImportedDll -Path (Join-Path $root 'notpe.exe') | Out-Null } catch { $threw = $true }
  Assert-True 'a non-PE file throws rather than reporting no imports' $threw

  [System.IO.File]::WriteAllBytes((Join-Path $root 'trunc.exe'), [byte[]]@(0x4D, 0x5A, 0, 0))
  $threw = $false
  try { Get-ImportedDll -Path (Join-Path $root 'trunc.exe') | Out-Null } catch { $threw = $true }
  Assert-True 'a truncated PE throws' $threw

  # ── THE SHAPE THE PRODUCTION CALL SITE ACTUALLY USES ────────────────────────
  # Every assertion above calls these functions BARE, and production wraps them
  # in @(). Those are not the same thing: with `return , @(...)` the raw call
  # returned a clean 3-element array while `@(call)` nested it one level, and a
  # nested list coerced into [string[]] collapsed to ONE space-joined string. The
  # allowlist then matched nothing, every import list became a single
  # unrecognised "DLL", and the check reported a finding regardless of what the
  # binary imported — which is exactly what the first real Windows run produced.
  # Testing the bare shape could not see it. These test the wrapped shape.
  $wrapped = @(Get-ImportedDll -Path $pe64)
  Assert-That 'wrapped: the caller gets one element PER DLL' $wrapped.Count 2
  Assert-That 'wrapped: elements are strings, not a nested array' $wrapped[0].GetType().Name 'String'
  $wrappedUnsat = @(Get-UnsatisfiedImport -Imports $wrapped -ShippedFiles @('app64.exe'))
  Assert-That 'wrapped: the allowlist still filters' $wrappedUnsat.Count 1
  Assert-That 'wrapped: and names the real DLL' $wrappedUnsat[0] 'VCRUNTIME140.dll'
  $wrappedClean = @(Get-UnsatisfiedImport -Imports @('KERNEL32.dll', 'USER32.dll') -ShippedFiles @())
  Assert-That 'wrapped: a clean set yields nothing, not one blob' $wrappedClean.Count 0

  # ── the parser REFUSES to give up quietly ───────────────────────────────────
  # Every one of these used to return an empty list, and an empty list is
  # indistinguishable from a binary that imports nothing — so "could not read
  # this" became "nothing to find here", which is a pass. Each must throw.
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

  # An empty name is the subtlest of the four: it drops exactly ONE DLL from the
  # sweep, and if that one is the only unsatisfied import, the finding vanishes
  # and the check passes. Point the first descriptor's name RVA at the
  # zero-filled start of the section so the name reads as "".
  $bad3 = Join-Path $root 'emptyname.exe'
  [System.IO.File]::Copy($pe64, $bad3, $true)
  $b3 = [System.IO.File]::ReadAllBytes($bad3)
  [BitConverter]::GetBytes([uint32]0x1000).CopyTo($b3, 0x400 + 12)
  [System.IO.File]::WriteAllBytes($bad3, $b3)
  $threw = $false
  try { Get-ImportedDll -Path $bad3 | Out-Null } catch { $threw = $true }
  Assert-True 'an empty DLL name throws rather than being dropped' $threw

  # ── Get-ImportSweepVerdict ──────────────────────────────────────────────────
  # The check-level guards. The zero-import case is the one that mattered: a
  # sweep over binaries that yielded no imports at all used to report the clean
  # message.
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

  # ── Get-UnsatisfiedImport ───────────────────────────────────────────────────
  # The Windows shape of the .deb dependency gate: what does the artifact need
  # that the machine is not guaranteed to have?
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

  # End to end, from PE bytes to verdict — the two functions the check actually
  # composes, driven together rather than each in isolation.
  Assert-That 'PE bytes through to the finding' `
  (Get-UnsatisfiedImport -Imports (Get-ImportedDll -Path $pe64) -ShippedFiles @('app64.exe')) @('VCRUNTIME140.dll')

  Assert-True 'VCRUNTIME140.dll is named as the VC++ redistributable' (Test-IsVcRuntime -Dll 'VCRUNTIME140.dll')
  Assert-True 'VCRUNTIME140_1.dll too' (Test-IsVcRuntime -Dll 'VCRUNTIME140_1.dll')
  Assert-True 'MSVCP140.dll too' (Test-IsVcRuntime -Dll 'msvcp140.dll')
  Assert-True 'CONCRT140.dll too' (Test-IsVcRuntime -Dll 'CONCRT140.dll')
  Assert-False 'kernel32 is not the VC++ redistributable' (Test-IsVcRuntime -Dll 'kernel32.dll')
  Assert-False 'WebView2Loader is not either' (Test-IsVcRuntime -Dll 'WebView2Loader.dll')

  # ── Test-SignatureVerdict ───────────────────────────────────────────────────
  # NotSigned is our builds' CURRENT state, and it must be a failure: the whole
  # point of gating it is that the day a certificate is wired in, this turns
  # green with no edit.
  # FOUR OUTCOMES, all pinned. The signing state is a DECLARED expectation now,
  # not a permanent red — amber while reality matches what we declared, red the
  # moment they diverge in either direction. The row that matters most is
  # signed-but-invalid: a plain skip would have silently lost it, and it is a
  # real defect no declaration excuses.
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
  # A signed build is good news even while we declare we expect none — it must
  # not be reported as a surprise failure.
  Assert-That 'signed while expecting unsigned is still a pass' `
  (Test-SignatureVerdict -Status 'Valid' -SignerSubject 'CN=Unyt' -ExpectSigned $false).Result 'pass'
  Assert-True 'the warn says what it costs the user' `
  ((Test-SignatureVerdict -Status 'NotSigned').Message -match 'SmartScreen')
  Assert-True 'the broken-chain message says it is signed but untrusted' `
  ((Test-SignatureVerdict -Status 'NotTrusted').Message -match 'will not trust')
  # The diagnosis, not just the colour: this row and the broken-chain row are
  # both FAIL, so without pinning the message they are interchangeable — and the
  # actionable difference is that one means "signing broke" and the other means
  # "signing works but produces something users reject".
  Assert-True 'the expect-signed failure says signing has broken' `
  ((Test-SignatureVerdict -Status 'NotSigned' -ExpectSigned $true).Message -match 'signing has broken')

  # The declaration ships as "expect unsigned", so today's real state is amber.
  Assert-False 'the shipped declaration expects unsigned' $script:ExpectWindowsSigned

  # ── the three-verdict machinery ─────────────────────────────────────────────
  # 'warn' has to reach the row without failing the job, and must not become a
  # loophole: anything that is not a bool or the literal 'warn' is still broken.
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

  # THE CENTRAL CLAIM OF THE DECLARED-STATE DESIGN: a warn is visible but does
  # not fail the job, while a FAIL anywhere still does — including alongside a
  # warn, so the amber row can never mask a red one.
  $rowP = [PSCustomObject]@{ Name = 'p'; Verdict = 'pass' }
  $rowW = [PSCustomObject]@{ Name = 'w'; Verdict = 'warn' }
  $rowF = [PSCustomObject]@{ Name = 'f'; Verdict = 'FAIL' }
  Assert-That 'all passing -> exit 0' (Get-OverallStatus -Results @($rowP, $rowP)) 0
  Assert-That 'a warn alone -> exit 0 (the job stays green)' (Get-OverallStatus -Results @($rowP, $rowW)) 0
  Assert-That 'warns only -> exit 0' (Get-OverallStatus -Results @($rowW, $rowW)) 0
  Assert-That 'a FAIL -> exit 1' (Get-OverallStatus -Results @($rowP, $rowF)) 1
  Assert-That 'a warn does not mask a FAIL' (Get-OverallStatus -Results @($rowW, $rowF)) 1
  Assert-That 'no rows at all -> exit 0' (Get-OverallStatus -Results @()) 0

  # ── Get-ArtifactVersion / Get-InstallerKind ─────────────────────────────────
  Assert-That 'the version comes out of a release asset name' `
  (Get-ArtifactVersion -FileName 'unyt_0.100.0_Unyt.Sandbox_default-arc_x64_windows.exe') '0.100.0'
  Assert-That 'and out of the .msi name' `
  (Get-ArtifactVersion -FileName 'unyt_1.2.3_Unyt.Sandbox_default-arc_x64_windows.msi') '1.2.3'
  Assert-That 'a hand-built file has no version to read' (Get-ArtifactVersion -FileName 'handbuilt.exe') $null
  # NSIS artifacts here are a plain .exe, never -setup.exe; a name that does not
  # match must be unknown rather than silently accepted.
  Assert-That 'a non-release name is unknown' (Get-ArtifactVersion -FileName 'unyt-setup.exe') $null
  Assert-That 'an .exe is the NSIS installer' (Get-InstallerKind -Path 'a\b\x.exe') 'nsis'
  Assert-That 'case does not matter' (Get-InstallerKind -Path 'X.EXE') 'nsis'
  Assert-That 'an .msi is the MSI' (Get-InstallerKind -Path 'x.msi') 'msi'
  Assert-That 'anything else is refused' (Get-InstallerKind -Path 'x.zip') 'unsupported'

  # ── Get-NewUninstallEntry ───────────────────────────────────────────────────
  $a = [PSCustomObject]@{ KeyPath = 'HKCU:\...\A'; DisplayName = 'A'; DisplayVersion = '1' }
  $b = [PSCustomObject]@{ KeyPath = 'HKCU:\...\B'; DisplayName = 'B'; DisplayVersion = '1' }
  $c = [PSCustomObject]@{ KeyPath = 'HKCU:\...\Unyt'; DisplayName = 'Unyt Sandbox'; DisplayVersion = '0.100.0' }
  Assert-That 'the entry the install added is the one found' `
  (Get-NewUninstallEntry -Before @($a, $b) -After @($a, $b, $c)).KeyPath 'HKCU:\...\Unyt'
  Assert-That 'an install that registered nothing is detected' `
  @(Get-NewUninstallEntry -Before @($a, $b) -After @($a, $b)).Count 0
  Assert-That 'a first-ever entry is found on an empty machine' `
  @(Get-NewUninstallEntry -Before @() -After @($c)).Count 1

  # ── Test-UninstallEntry ─────────────────────────────────────────────────────
  Assert-True 'the registered version matching the artifact passes' (Test-UninstallEntry -Entry $c -ExpectedVersion '0.100.0').Ok
  Assert-False 'a version mismatch fails' (Test-UninstallEntry -Entry $c -ExpectedVersion '0.99.0').Ok
  Assert-False 'no entry at all fails' (Test-UninstallEntry -Entry $null -ExpectedVersion '0.100.0').Ok
  # Cannot answer is not a pass — and it must fail FOR THAT REASON. Both verdicts
  # are red, so without pinning the message a check that had stopped
  # distinguishing "no version to compare" from "the versions differ" would look
  # identical here.
  Assert-False 'an unknown expected version fails' (Test-UninstallEntry -Entry $c -ExpectedVersion $null).Ok
  Assert-True 'and fails as unanswerable, not as a mismatch' `
  ((Test-UninstallEntry -Entry $c -ExpectedVersion $null).Message -match 'carries no version')

  # ── Get-UninstallCommand ────────────────────────────────────────────────────
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

  # ── Test-InstallDirectory ───────────────────────────────────────────────────
  $good = Join-Path $root 'installed'; New-Item -ItemType Directory -Path $good -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $good 'unyt-sandbox.exe') -Value 'x'
  Assert-True 'a directory holding the program passes' (Test-InstallDirectory -Path $good).Ok
  $empty = Join-Path $root 'empty'; New-Item -ItemType Directory -Path $empty -Force | Out-Null
  Assert-False 'a registered install that shipped no program fails' (Test-InstallDirectory -Path $empty).Ok
  Assert-False 'a missing install directory fails' (Test-InstallDirectory -Path (Join-Path $root 'nope')).Ok
  Assert-False 'no recorded location fails' (Test-InstallDirectory -Path $null).Ok
  # THE TWO SHAPES A REAL REGISTRY RETURNS, observed on a runner: NSIS writes
  # InstallLocation QUOTED, the MSI writes it bare with a trailing separator.
  # Taken verbatim the quoted one fails every Test-Path, so a good install was
  # reported missing and the import sweep then had nothing to scan.
  Assert-True 'a QUOTED InstallLocation (NSIS) is accepted' (Test-InstallDirectory -Path "`"$good`"").Ok
  Assert-True 'a trailing-separator InstallLocation (MSI) is accepted' (Test-InstallDirectory -Path "$good\").Ok
  Assert-That 'and the normalised path comes back for the caller to reuse' `
  (Test-InstallDirectory -Path "`"$good`"").Path $good
  Assert-False 'a value that is nothing but quotes fails' (Test-InstallDirectory -Path '""').Ok

  # ── Test-RemovalComplete ────────────────────────────────────────────────────
  Assert-True 'a clean removal passes' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir (Join-Path $root 'nope')).Ok
  Assert-False 'an uninstaller that leaves its registration fails' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $c) -InstallDir (Join-Path $root 'nope')).Ok
  Assert-False 'an uninstaller that leaves the program behind fails' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($a, $b) -InstallDir $good).Ok
  Assert-That 'and both problems are reported at once' `
  (Test-RemovalComplete -EntryKeyPath 'HKCU:\...\Unyt' -CurrentEntries @($c) -InstallDir $good).Problems.Count 2

  # ── Invoke-Check: a body that does not answer is a FAILURE ──────────────────
  # The suite's defining bug class, guarded at the harness level: `[bool](&
  # $Body)` would call any non-empty output true, so one unsilenced cmdlet line
  # would turn a failing check green.
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

  # ── Invoke-Silently: it must not wait forever ───────────────────────────────
  # An installer given the wrong silent switch puts a dialog up and waits. Real
  # processes, on whatever platform this is running on, because the point is the
  # timeout and the kill, not the command.
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

  # An argument containing a space must reach the process as ONE argument —
  # `msiexec /i "C:\dir with space\x.msi"`. Unquoted it is re-split and msiexec
  # installs nothing.
  #
  # COUNTS THE ARGUMENTS THE CHILD ACTUALLY RECEIVED, because the obvious pin is
  # hollow: `cmd /c exit 7` and `cmd /c "exit 7"` both yield 7 on Windows, the
  # only platform this really matters on, so the assertion held whether or not
  # the quoting worked. One argument means quoting survived; two means it was
  # split. Runs identically on both platforms because the child is pwsh itself.
  $argCounter = Join-Path $root 'argcount.ps1'
  Set-Content -LiteralPath $argCounter -Value 'exit $args.Count'
  $pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $spacedPath = Join-Path $root 'dir with space\pkg.msi'
  $r = Invoke-Silently -FilePath $pwshExe -Arguments @('-NoProfile', '-File', $argCounter, $spacedPath) -TimeoutSeconds 60
  Assert-That 'a path containing a space arrives as ONE argument' $r.ExitCode 1

  # Reached only if every assertion above ran. See the guard in `finally`.
  $script:Completed = $true
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  # THIS FILE'S OWN ZERO GUARD, matching test-macos-checks.sh: an injected
  # `exit 0` or an early return would otherwise end the run with no output and
  # status 0, which reads as "every check is proven able to fail" while nothing
  # was proven. The same shape as the bugs this file exists to catch.
  if (-not $script:Completed) {
    [Console]::Error.WriteLine('::error::the regression test exited before completing — an early exit, a truncated file, or a killed run. NOTHING was proven; do not read this as a pass.')
    exit 1
  }
}

Write-Output "windows check regression: $script:Pass passed, $script:Fail failed"
# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "3 passed, 0 failed" and exit 0. Raise it when adding
# assertions.
if ($script:Pass -lt 100) {
  [Console]::Error.WriteLine("::error::only $script:Pass assertions ran; expected at least 100 — the test file is truncated or a block was skipped")
  exit 1
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
