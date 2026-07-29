[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'),
  [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
  [switch]$SkipTests,
  [switch]$AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'validate-config.ps1') -ConfigPath $ConfigPath -ProjectRoot $SourceRoot
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath
Assert-DeploymentAdministrator
Initialize-DeploymentDirectories

$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$git = Get-Command git.exe -ErrorAction SilentlyContinue
$gitCommit = $null
$dirty = $false
if ($git -and (Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))) {
  Push-Location $SourceRoot
  try {
    $gitCommit = (& $git.Source rev-parse HEAD 2>$null)
    $dirty = [bool](& $git.Source status --porcelain)
  } finally { Pop-Location }
  if ($dirty -and -not $AllowDirty) { throw 'The Git worktree is dirty. Commit changes or explicitly use -AllowDirty and record the risk.' }
}

if ($SkipTests) {
  Write-Warning 'Tests are skipped for this release.'
} else {
  Invoke-DeploymentCommand $script:DeploymentConfig.release.testCommand $SourceRoot
}
Invoke-DeploymentCommand $script:DeploymentConfig.release.buildCommand $SourceRoot

$shortCommit = if ($gitCommit) { $gitCommit.Substring(0, [Math]::Min(8, $gitCommit.Length)) } else { 'nogit' }
$dirtySuffix = if ($dirty) { '-dirty' } else { '' }
$releaseId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$shortCommit$dirtySuffix"
$releasePath = Join-Path $script:ReleasesRoot $releaseId
if (Test-Path -LiteralPath $releasePath) { throw "Release already exists: $releasePath" }
New-Item -ItemType Directory -Path $releasePath | Out-Null

try {
  foreach ($directory in @($script:DeploymentConfig.release.includeDirectories)) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot $directory) -Destination $releasePath -Recurse -Force
  }
  foreach ($file in @($script:DeploymentConfig.release.includeFiles)) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot $file) -Destination (Join-Path $releasePath $file) -Force
  }
  Invoke-DeploymentCommand $script:DeploymentConfig.release.installCommand $releasePath

  $manifest = [ordered]@{
    releaseId = $releaseId
    gitCommit = $gitCommit
    dirty = $dirty
    createdAt = (Get-Date).ToString('o')
    sourceRoot = $SourceRoot
    configSha256 = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
  } | ConvertTo-Json
  Set-DeploymentAtomicText (Join-Path $releasePath 'release.json') "$manifest`n"
} catch {
  Write-Warning "Incomplete release remains for diagnosis: $releasePath"
  throw
}

$oldSlot = Get-ActiveDeploymentSlot
$newSlot = if ($oldSlot) { Get-OtherDeploymentSlot $oldSlot } else { 'blue' }
$oldRelease = if ($oldSlot) { Get-SlotRelease $oldSlot } else { $null }
$previousInactiveRelease = Get-SlotRelease $newSlot
Write-Host "Starting release $releaseId in inactive slot $newSlot."
Stop-DeploymentSlot $newSlot
Set-SlotRelease $newSlot $releasePath

try {
  Start-DeploymentSlot $newSlot
  Publish-DeploymentWeb $releasePath
  Publish-DeploymentCaddyConfiguration $newSlot
  Set-ActiveDeploymentState $newSlot $releasePath
} catch {
  $deploymentFailure = $_
  if ($oldSlot -and $oldRelease) {
    try {
      Publish-DeploymentWeb $oldRelease
      Publish-DeploymentCaddyConfiguration $oldSlot
    } catch {
      Write-Warning "Automatic traffic restoration failed: $($_.Exception.Message)"
    }
    try {
      Set-ActiveDeploymentState $oldSlot $oldRelease
    } catch {
      Write-Warning "Automatic active-state restoration failed: $($_.Exception.Message)"
    }
  } else {
    try { Clear-ActiveDeploymentState } catch { Write-Warning "Failed to clear partial active state: $($_.Exception.Message)" }
  }
  $newSlotStopped = $true
  try {
    Stop-DeploymentSlot $newSlot
  } catch {
    $newSlotStopped = $false
    Write-Warning "Failed to stop the rejected slot $newSlot`: $($_.Exception.Message)"
  }
  if ($newSlotStopped) {
    try {
      Restore-SlotRelease $newSlot $previousInactiveRelease
    } catch {
      Write-Warning "Failed to restore the previous rollback slot $newSlot`: $($_.Exception.Message)"
    }
  } else {
    Write-Warning "The previous rollback junction was not restored because slot $newSlot is still running."
  }
  throw $deploymentFailure
}

Clear-PostCutoverWarning
$completionStatus = 'switched'
if ($oldSlot) {
  try {
    Stop-DeploymentSlot $oldSlot
  } catch {
    $completionStatus = 'switched-with-drain-warning'
    $message = "Traffic switched to $newSlot, but old slot $oldSlot did not drain: $($_.Exception.Message)"
    Set-PostCutoverWarning 'deploy' $oldSlot $message
    Write-Warning $message
  }
}
Write-Output "Release completed: $releaseId"
Write-Output "Active slot: $newSlot"
Write-Output "Completion status: $completionStatus"
