[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'),
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'validate-config.ps1') -ConfigPath $ConfigPath -ProjectRoot $ProjectRoot
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail, [bool]$Blocking = $true) {
  $checks.Add([pscustomobject]@{ name = $Name; passed = $Passed; blocking = $Blocking; detail = $Detail })
}

$windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
Add-Check 'windows-host' $windows ([Environment]::OSVersion.VersionString)

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Check 'administrator' $administrator 'Installation requires elevated PowerShell.'

foreach ($command in @('node.exe', 'npm.cmd', 'curl.exe')) {
  $found = Get-Command $command -ErrorAction SilentlyContinue
  $detail = if ($found) { $found.Source } else { 'Not found in PATH.' }
  Add-Check "command-$command" ([bool]$found) $detail
}

$placeholderOrigin = @($script:DeploymentConfig.publicOrigins | Where-Object { $_ -match '10\.0\.0\.10' }).Count -gt 0
Add-Check 'public-origins-customized' (-not $placeholderOrigin) 'Replace the template origin with the real IP or internal DNS name.'

$configuredPorts = @([int]$script:DeploymentConfig.listenPort)
foreach ($service in @($script:DeploymentConfig.services | Where-Object { $_.type -eq 'api' })) {
  $configuredPorts += [int]$service.bluePort
  $configuredPorts += [int]$service.greenPort
}
foreach ($port in $configuredPorts) {
  $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
  $knownInstall = Test-Path -LiteralPath $script:ProductionRoot
  $detail = if ($listeners.Count) { "Currently listened to by PID(s): $(@($listeners.OwningProcess) -join ', ')" } else { 'Available.' }
  Add-Check "port-$port" (-not $listeners.Count -or $knownInstall) $detail
}

$drive = [IO.Path]::GetPathRoot($script:ProductionRoot)
$driveInfo = Get-PSDrive -Name $drive.Substring(0, 1) -ErrorAction SilentlyContinue
$driveDetail = if ($driveInfo) { "Free bytes: $($driveInfo.Free)" } else { "Drive not found: $drive" }
Add-Check 'production-drive' ([bool]$driveInfo) $driveDetail

Add-Check 'backup-enabled' ([bool]$script:DeploymentConfig.backup.enabled) 'Application-consistent scheduled backup is disabled.' $false
Add-Check 'single-host-risk' $false 'Blue/green deployment does not protect against loss of this host.' $false

$checks | Format-Table -AutoSize | Out-String | Write-Host
$blockingFailures = @($checks | Where-Object { $_.blocking -and -not $_.passed })
if ($blockingFailures.Count) { throw "Preflight failed with $($blockingFailures.Count) blocking issue(s)." }
Write-Output 'Preflight passed.'
