<#
.SYNOPSIS
  Does windows-wipe.ps1 remove the app's data, and nothing when it cannot name the app?

.DESCRIPTION
  pwsh -File scripts/test-windows-wipe.ps1

  Runs the script as docs/windows-wipe.md does, in a child pwsh whose APPDATA and LOCALAPPDATA are
  folders of this test, beside another app's data that must survive. Runs on any platform, and names
  only folders Windows allows.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wipe = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'windows-wipe.ps1'
$pwsh = (Get-Process -Id $PID).Path
$script:Pass = 0
$script:Fail = 0
$script:Completed = $false
$script:Crash = ''
$script:Output = ''
function Assert-True {
  param([Parameter(Mandatory)][string]$What, [object]$Got, [string]$Detail = '')
  if ($Got) { $script:Pass++; return }
  $script:Fail++
  [Console]::Error.WriteLine("FAIL  $What")
  if ($Detail) { [Console]::Error.WriteLine(($Detail.TrimEnd() -split "`n" | ForEach-Object { "      $_" }) -join "`n") }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("unyt-wipe-" + [guid]::NewGuid().ToString('n'))
$roaming = Join-Path $root 'Roaming'
$local = Join-Path $root 'Local'
# The app's Cargo authors, "zo-el <joelulahanna@gmail.com>", as app_dirs2 names its folder.
$holochain = Join-Path $local 'zo-el ,60,joelulahanna,64,gmail.com,62,'
$app = @{ identifier = 'co.example.wipe'; productName = 'Example Wipe' }

function New-Machine {
  # The app's data, and another app's beside it.
  foreach ($folder in @($roaming, $local)) {
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
  }
  foreach ($folder in @(
      (Join-Path $local 'Example Wipe'), (Join-Path $roaming 'co.example.wipe'), (Join-Path $local 'co.example.wipe/logs'),
      (Join-Path $holochain 'co.example.wipe/0.1/holochain'), (Join-Path $local 'Temp/co.example.wipe-1'),
      (Join-Path $roaming 'co.example.other'), (Join-Path $holochain 'co.example.other'), (Join-Path $local 'Temp/other'))) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
  }
}
function Test-Untouched {
  $kept = @((Join-Path $local 'Example Wipe'), (Join-Path $roaming 'co.example.wipe'), (Join-Path $holochain 'co.example.wipe'),
    (Join-Path $roaming 'co.example.other'), (Join-Path $holochain 'co.example.other'), (Join-Path $local 'Temp/other'))
  return @($kept | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0
}
function Invoke-Wipe {
  # Returns the child's exit status, and leaves its output in $script:Output.
  $env:APPDATA = $roaming
  $env:LOCALAPPDATA = $local
  $script:Output = & $pwsh -NoProfile -File $wipe @args 2>&1 | Out-String
  return $LASTEXITCODE
}
function Write-Identity {
  # A file of its own each time, so no case reads another's.
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  $path = Join-Path $root ("identity-" + [guid]::NewGuid().ToString('n') + '.json')
  Set-Content -LiteralPath $path -Value $Text -NoNewline
  return $path
}

try {
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  New-Machine
  $identity = Write-Identity ($app | ConvertTo-Json)
  Assert-True 'a wipe that names the app removes its data' ((Invoke-Wipe -Identity $identity) -eq 0) $script:Output
  foreach ($gone in @((Join-Path $local 'Example Wipe'), (Join-Path $roaming 'co.example.wipe'),
      (Join-Path $local 'co.example.wipe'), (Join-Path $holochain 'co.example.wipe'), (Join-Path $local 'Temp/co.example.wipe-1'))) {
    Assert-True "and $gone is gone" (-not (Test-Path -LiteralPath $gone))
  }
  foreach ($kept in @((Join-Path $roaming 'co.example.other'), (Join-Path $holochain 'co.example.other'),
      (Join-Path $local 'Temp/other'), $holochain, $roaming, $local)) {
    Assert-True "and $kept is kept" (Test-Path -LiteralPath $kept)
  }

  New-Machine
  Assert-True 'a wipe named by hand removes the same data' (
    (Invoke-Wipe -Identifier co.example.wipe -ProductName 'Example Wipe') -eq 0) $script:Output
  Assert-True 'and keeps the other app' (Test-Path -LiteralPath (Join-Path $holochain 'co.example.other'))

  New-Machine
  Assert-True 'a wipe asked what it would do removes nothing' ((Invoke-Wipe -Identity $identity -WhatIf) -eq 0) $script:Output
  Assert-True 'and the machine is untouched' (Test-Untouched)

  $refusals = [ordered]@{
    'a missing identity file' = @('-Identity', (Join-Path $root 'absent.json'))
    'an identity file that is no JSON' = @('-Identity', (Write-Identity '{"identifier": '))
    'an empty identity file' = @('-Identity', (Write-Identity ''))
    'an identity file that is a list' = @('-Identity', (Write-Identity '[]'))
    'an identity with no identifier' = @('-Identity', (Write-Identity '{"productName": "Example Wipe"}'))
    'an identity whose identifier is blank' = @('-Identity', (Write-Identity '{"identifier": " ", "productName": "Example Wipe"}'))
    'an identity whose identifier is a number' = @('-Identity', (Write-Identity '{"identifier": 1, "productName": "Example Wipe"}'))
    'an identity whose product is a path' = @('-Identity', (Write-Identity '{"identifier": "co.example.wipe", "productName": ".."}'))
    'an empty identifier typed by hand' = @('-Identifier', '', '-ProductName', 'Example Wipe')
    'a blank product typed by hand' = @('-Identifier', 'co.example.wipe', '-ProductName', ' ')
    'a product typed by hand as a path' = @('-Identifier', 'co.example.wipe', '-ProductName', 'Example\..\..')
    'an identifier typed by hand as a parent folder' = @('-Identifier', '..', '-ProductName', 'Example Wipe')
  }
  foreach ($case in $refusals.GetEnumerator()) {
    New-Machine
    $wipeArgs = $case.Value
    Assert-True "a wipe given $($case.Key) is refused" ((Invoke-Wipe @wipeArgs) -ne 0) $script:Output
    Assert-True "and it removes nothing" (Test-Untouched) $script:Output
  }

  New-Machine
  $env:APPDATA = ''
  $script:Output = & $pwsh -NoProfile -File $wipe -Identity $identity 2>&1 | Out-String
  Assert-True 'a wipe on a machine with no APPDATA is refused' ($script:Output -match 'APPDATA is not set') $script:Output
  Assert-True 'and it removes nothing' (Test-Untouched)

  $script:Completed = $true
}
catch {
  $script:Crash = ($_ | Out-String).TrimEnd()
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $script:Completed) {
    [Console]::Error.WriteLine("::error::the wipe test exited before completing, so it proved nothing: $script:Crash")
    if ($script:Output) { [Console]::Error.WriteLine("the last wipe printed:`n$($script:Output.TrimEnd())") }
    exit 1
  }
}

Write-Output "windows wipe: $script:Pass passed, $script:Fail failed"
if ($script:Pass -lt 42) {
  [Console]::Error.WriteLine("::error::only $script:Pass assertions ran; expected at least 42")
  exit 1
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
