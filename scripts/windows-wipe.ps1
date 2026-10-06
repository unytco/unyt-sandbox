<#
.SYNOPSIS
  Removes everything the app identity.json names leaves on a Windows machine, as docs/windows-wipe.md
  lists it.

.DESCRIPTION
  pwsh -File scripts/windows-wipe.ps1 [-Identity <identity.json>] [-WhatIf]
  pwsh -File scripts/windows-wipe.ps1 -Identifier <identifier> -ProductName <productName> [-WhatIf]

  Without names it reads them from identity.json, by default the one at this repo's root. It refuses
  before it stops or removes anything unless both are plain names, so no path it removes can be a
  folder that holds another app's data.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'File')]
param(
  [Parameter(ParameterSetName = 'File')][string]$Identity = (Join-Path (Split-Path -Parent $PSScriptRoot) 'identity.json'),
  [Parameter(ParameterSetName = 'Names', Mandatory)][AllowEmptyString()][string]$Identifier,
  [Parameter(ParameterSetName = 'Names', Mandatory)][AllowEmptyString()][string]$ProductName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Field {
  param([AllowNull()][object]$Object, [string]$Field)
  if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
  $property = $Object.PSObject.Properties[$Field]
  if ($null -eq $property) { return $null }
  return $property.Value
}

if ($PSCmdlet.ParameterSetName -eq 'File') {
  try {
    $app = Get-Content -LiteralPath $Identity -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "cannot read the app's names from ${Identity}: $($_.Exception.Message)"
  }
  $Identifier = Get-Field $app 'identifier'
  $ProductName = Get-Field $app 'productName'
}

# The forms release-app.sh holds identity.json to.
$names = @(
  @('identifier', $Identifier, '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'),
  @('productName', $ProductName, '^[A-Za-z0-9][A-Za-z0-9 ._()\[\]{}-]*$')
)
foreach ($name in $names) {
  $value = $name[1]
  if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -cnotmatch $name[2]) {
    throw "the app's $($name[0]) is '$value', which is no name this script can remove the app's data by"
  }
}
foreach ($variable in 'APPDATA', 'LOCALAPPDATA') {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($variable))) {
    throw "$variable is not set, so there is no telling where the app's data is"
  }
}

# Every process the app's install folders hold, and no other app's holochain or lair-keystore.
$installs = @(Join-Path $env:LOCALAPPDATA $ProductName)
if ($env:ProgramFiles) { $installs += Join-Path $env:ProgramFiles $ProductName }
$processes = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  # A process this user may not read has no path to read.
  $path = try { $_.Path } catch { $null }
  $path -and @($installs | Where-Object { $path.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, 'OrdinalIgnoreCase') })
}
foreach ($process in $processes) {
  if ($PSCmdlet.ShouldProcess("$($process.ProcessName) ($($process.Id))", 'Stop-Process')) {
    $process | Stop-Process -Force
  }
}

$folders = @(
  (Join-Path $env:LOCALAPPDATA $ProductName),
  (Join-Path $env:APPDATA $Identifier),
  (Join-Path $env:LOCALAPPDATA $Identifier),
  (Join-Path (Join-Path $env:APPDATA 'zo-el <joelulahanna@gmail.com>') $Identifier)
)
$temp = Join-Path $env:LOCALAPPDATA 'Temp'
if (Test-Path -LiteralPath $temp) {
  $folders += @(Get-ChildItem -LiteralPath $temp -Directory -Filter "$Identifier*" | ForEach-Object FullName)
}
foreach ($folder in $folders) {
  if ((Test-Path -LiteralPath $folder) -and $PSCmdlet.ShouldProcess($folder, 'Remove-Item -Recurse')) {
    Remove-Item -LiteralPath $folder -Recurse -Force
  }
}
# cmdkey fails when there is no such credential, which is no failure of the wipe.
if ((Get-Command cmdkey -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess($Identifier, 'cmdkey /delete')) {
  & { $ErrorActionPreference = 'Continue'; cmdkey "/delete:$Identifier" *> $null }
}

if (-not $WhatIfPreference) {
  $left = @($folders | Where-Object { Test-Path -LiteralPath $_ })
  if ($left.Count -gt 0) { throw "still on the machine: $($left -join ', ')" }
}
