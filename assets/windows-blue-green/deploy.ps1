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
Write-Host "Starting release $releaseId in inactive slot $newSlot."
Stop-DeploymentSlot $newSlot
Set-SlotRelease $newSlot $releasePath

try {
  Start-DeploymentSlot $newSlot
  Publish-DeploymentWeb $releasePath
  Publish-DeploymentCaddyConfiguration $newSlot
  Set-ActiveDeploymentState $newSlot $releasePath
} catch {
  if ($oldSlot -and $oldRelease) {
    try {
      Publish-DeploymentWeb $oldRelease
      Publish-DeploymentCaddyConfiguration $oldSlot
    } catch {
      Write-Warning "Automatic traffic restoration failed: $($_.Exception.Message)"
    }
  }
  Stop-DeploymentSlot $newSlot
  throw
}

if ($oldSlot) { Stop-DeploymentSlot $oldSlot }
Write-Output "Release completed: $releaseId"
Write-Output "Active slot: $newSlot"
