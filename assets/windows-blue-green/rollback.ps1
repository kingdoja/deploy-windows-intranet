[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath
$operationLock = Enter-DeploymentOperationLock
try {
  Assert-DeploymentAdministrator

$currentSlot = Get-ActiveDeploymentSlot
if (-not $currentSlot) { throw 'No active slot is recorded.' }
$targetSlot = Get-OtherDeploymentSlot $currentSlot
$targetRelease = Get-SlotRelease $targetSlot
$currentRelease = Get-SlotRelease $currentSlot
if (-not $targetRelease) { throw "No rollback release is attached to slot $targetSlot." }

Start-DeploymentSlot $targetSlot
try {
  Publish-DeploymentCaddyConfiguration $targetSlot
  Set-ActiveDeploymentState $targetSlot $targetRelease
} catch {
  if ($currentRelease) {
    try {
      Publish-DeploymentCaddyConfiguration $currentSlot
    } catch {
      Write-Warning "Automatic traffic restoration failed: $($_.Exception.Message)"
    }
    try {
      Set-ActiveDeploymentState $currentSlot $currentRelease
    } catch {
      Write-Warning "Automatic active-state restoration failed: $($_.Exception.Message)"
    }
  }
  Stop-DeploymentSlot $targetSlot
  throw
}
Clear-PostCutoverWarning
$completionStatus = 'switched'
try {
  Stop-DeploymentSlot $currentSlot
} catch {
  $completionStatus = 'switched-with-drain-warning'
  $message = "Rollback switched to $targetSlot, but previous slot $currentSlot did not drain: $($_.Exception.Message)"
  Set-PostCutoverWarning 'rollback' $currentSlot $message
  Write-Warning $message
}
Write-Output "Rolled back to: $targetRelease"
Write-Output "Active slot: $targetSlot"
Write-Output "Completion status: $completionStatus"
} finally {
  Exit-DeploymentOperationLock $operationLock
}
