[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath
Assert-DeploymentAdministrator

$currentSlot = Get-ActiveDeploymentSlot
if (-not $currentSlot) { throw 'No active slot is recorded.' }
$targetSlot = Get-OtherDeploymentSlot $currentSlot
$targetRelease = Get-SlotRelease $targetSlot
$currentRelease = Get-SlotRelease $currentSlot
if (-not $targetRelease) { throw "No rollback release is attached to slot $targetSlot." }

Start-DeploymentSlot $targetSlot
try {
  Publish-DeploymentWeb $targetRelease
  Publish-DeploymentCaddyConfiguration $targetSlot
  Set-ActiveDeploymentState $targetSlot $targetRelease
} catch {
  if ($currentRelease) {
    try {
      Publish-DeploymentWeb $currentRelease
      Publish-DeploymentCaddyConfiguration $currentSlot
    } catch {
      Write-Warning "Automatic traffic restoration failed: $($_.Exception.Message)"
    }
  }
  Stop-DeploymentSlot $targetSlot
  throw
}
Stop-DeploymentSlot $currentSlot
Write-Output "Rolled back to: $targetRelease"
Write-Output "Active slot: $targetSlot"
