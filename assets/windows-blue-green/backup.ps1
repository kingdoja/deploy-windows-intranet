[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath

if (-not $script:DeploymentConfig.backup.enabled) { throw 'Backup is disabled in deployment.config.json.' }
$slot = Get-ActiveDeploymentSlot
if (-not $slot) { throw 'No active release is available for backup.' }
$release = Get-SlotRelease $slot

if ([string]$script:DeploymentConfig.productionRootEnvironment) {
  [Environment]::SetEnvironmentVariable([string]$script:DeploymentConfig.productionRootEnvironment, $script:ProductionRoot, 'Process')
}
foreach ($property in $script:DeploymentConfig.commonEnvironment.PSObject.Properties) {
  $value = Expand-DeploymentValue ([string]$property.Value) $null $slot $release
  [Environment]::SetEnvironmentVariable($property.Name, $value, 'Process')
}

$command = [pscustomobject]@{
  executable = Expand-DeploymentValue ([string]$script:DeploymentConfig.backup.command.executable) $null $slot $release
  arguments = @($script:DeploymentConfig.backup.command.arguments | ForEach-Object { Expand-DeploymentValue ([string]$_) $null $slot $release })
}
Invoke-DeploymentCommand $command $release
Write-Output "Backup command completed for release: $release"

