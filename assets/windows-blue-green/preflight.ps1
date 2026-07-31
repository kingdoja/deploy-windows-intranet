[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'),
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'validate-config.ps1') -ConfigPath $ConfigPath -ProjectRoot $ProjectRoot
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath
. (Join-Path $PSScriptRoot 'preflight-core.ps1')

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

$referencedMachineVariables = @{}
foreach ($environment in @($script:DeploymentConfig.commonEnvironment) + @($script:DeploymentConfig.services | ForEach-Object { $_.environment })) {
  if (-not $environment) { continue }
  foreach ($property in $environment.PSObject.Properties) {
    if ([string]$property.Value -match '^%([A-Za-z_][A-Za-z0-9_]*)%$') {
      $referencedMachineVariables[$Matches[1].ToUpperInvariant()] = $Matches[1]
    }
  }
}
foreach ($variableName in $referencedMachineVariables.Values) {
  $defined = $null -ne [Environment]::GetEnvironmentVariable($variableName, 'Machine')
  Add-Check "machine-environment-$variableName" $defined 'Referenced service variables must exist at machine scope for LocalSystem.'
}

$placeholderOrigin = @($script:DeploymentConfig.publicOrigins | Where-Object { $_ -match '10\.0\.0\.10' }).Count -gt 0
Add-Check 'public-origins-customized' (-not $placeholderOrigin) 'Replace the template origin with the real IP or internal DNS name.'

$portExpectations = [Collections.Generic.List[object]]::new()
$portExpectations.Add([pscustomobject]@{ port = [int]$script:DeploymentConfig.listenPort; serviceName = Get-CaddyServiceName; loopbackOnly = $false })
foreach ($service in @($script:DeploymentConfig.services | Where-Object { $_.type -eq 'api' })) {
  foreach ($slot in @('blue', 'green')) {
    $portExpectations.Add([pscustomobject]@{ port = Get-DeploymentPort $service $slot; serviceName = Get-DeploymentServiceName $service $slot; loopbackOnly = $true })
  }
}
$processes = @(Get-CimInstance Win32_Process)
foreach ($expectation in $portExpectations) {
  $port = [int]$expectation.port
  $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
  if (-not $listeners.Count) {
    Add-Check "port-$port" $true 'Available.'
    continue
  }
  $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='$($expectation.serviceName)'" -ErrorAction SilentlyContinue
  $owned = [bool]($serviceInfo -and (Test-ListenerProcessOwnership @($listeners.OwningProcess) ([int]$serviceInfo.ProcessId) $processes))
  $loopbackSafe = -not $expectation.loopbackOnly -or (Test-DeploymentLoopbackListeners $listeners)
  $passed = $owned -and $loopbackSafe
  $detail = if ($passed) {
    "Owned by expected service $($expectation.serviceName); listener PID(s): $(@($listeners.OwningProcess) -join ', ')"
  } elseif ($owned -and -not $loopbackSafe) {
    "Expected service $($expectation.serviceName) is exposed beyond loopback at: $(@($listeners.LocalAddress | Sort-Object -Unique) -join ', ')"
  } else {
    "Unexpected listener PID(s): $(@($listeners.OwningProcess) -join ', '); expected service: $($expectation.serviceName)"
  }
  Add-Check "port-$port" $passed $detail
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
