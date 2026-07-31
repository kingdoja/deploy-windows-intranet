<#
.SYNOPSIS
Dry-run or apply a recoverable deploy-windows-intranet schema v1 to v2 migration.

.EXAMPLE
.\migrate-schema-v1-to-v2.ps1 -ProjectRoot C:\Projects\MyApp

.EXAMPLE
.\migrate-schema-v1-to-v2.ps1 -ProjectRoot C:\Projects\MyApp -BindAddressEnvironment HOST -Apply
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ProjectRoot,
  [string]$BindAddressEnvironment = 'HOST',
  [switch]$Apply,
  [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PathWithin([string]$Candidate, [string]$Parent) {
  $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
  $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
  return $candidateFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase) -or
    $candidateFull.StartsWith("$parentFull\", [StringComparison]::OrdinalIgnoreCase)
}
function Set-AtomicBytes([string]$Path, [byte[]]$Bytes, [string]$Suffix) {
  $temporary = "$Path.$PID.$Suffix"
  [IO.File]::WriteAllBytes($temporary, $Bytes)
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$deploymentRoot = Join-Path $root 'deploy\windows'
$configPath = Join-Path $deploymentRoot 'deployment.config.json'
$skillRoot = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $skillRoot 'assets\windows-blue-green'
$templateValidator = Join-Path $templateRoot 'validate-config.ps1'
$runtimeFiles = @(
  'common.ps1',
  'deploy.ps1',
  'install.ps1',
  'preflight.ps1',
  'rollback.ps1',
  'validate-config.ps1'
)

if (-not (Test-Path -LiteralPath $configPath)) { throw "Deployment configuration not found: $configPath" }
if ($BindAddressEnvironment -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
  throw 'BindAddressEnvironment must be a valid environment variable name.'
}
foreach ($file in $runtimeFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $templateRoot $file))) { throw "Skill runtime template is missing: $file" }
  if (-not (Test-Path -LiteralPath (Join-Path $deploymentRoot $file))) { throw "Generated deployment package is missing: $file" }
}

try {
  $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
} catch {
  throw "Invalid JSON in $configPath`: $($_.Exception.Message)"
}

$schemaVersion = [int]$config.schemaVersion
if ($schemaVersion -notin @(1, 2)) { throw "Only schema versions 1 and 2 are supported. Found: $schemaVersion" }
$configChanged = $schemaVersion -eq 1
if ($configChanged) {
  $config.schemaVersion = 2
  foreach ($service in @($config.services | Where-Object { $_.type -eq 'api' })) {
    if ($service.PSObject.Properties.Name -contains 'bindAddressEnvironment') {
      $service.bindAddressEnvironment = $BindAddressEnvironment
    } else {
      $service | Add-Member -NotePropertyName bindAddressEnvironment -NotePropertyValue $BindAddressEnvironment
    }
  }
}

$outdatedRuntimeFiles = @($runtimeFiles | Where-Object {
  $source = Join-Path $templateRoot $_
  $destination = Join-Path $deploymentRoot $_
  (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
})

$candidatePath = Join-Path ([IO.Path]::GetTempPath()) "deploy-schema-v2-$([guid]::NewGuid().ToString('N')).json"
try {
  $candidateJson = ($config | ConvertTo-Json -Depth 20) + "`n"
  [IO.File]::WriteAllText($candidatePath, $candidateJson, [Text.UTF8Encoding]::new($false))
  & $templateValidator -ConfigPath $candidatePath -ProjectRoot $root
} finally {
  if (Test-Path -LiteralPath $candidatePath) { Remove-Item -LiteralPath $candidatePath -Force }
}

Write-Output "Configuration migration required: $configChanged"
Write-Output "Runtime files requiring synchronization: $($outdatedRuntimeFiles.Count)"
foreach ($file in $outdatedRuntimeFiles) { Write-Output "  - deploy\windows\$file" }
Write-Output "API bind-address environment: $BindAddressEnvironment=127.0.0.1"

if (-not $configChanged -and -not $outdatedRuntimeFiles.Count) {
  Write-Output 'Deployment package is already at schema v2 and matches this Skill runtime.'
  return
}
if (-not $Apply) {
  Write-Output 'Dry run completed. Re-run with -Apply after reviewing the listed files.'
  return
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
if (-not $git) { throw 'Git is required for -Apply so the migration remains recoverable.' }
$repositoryRoot = (& $git.Source -C $root rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repositoryRoot) { throw 'ProjectRoot must be inside a Git worktree before using -Apply.' }
$worktreeChanges = @(& $git.Source -C $repositoryRoot status --porcelain --untracked-files=all)
if ($worktreeChanges.Count) {
  throw 'Git worktree is not clean. Commit or otherwise preserve existing changes before using -Apply.'
}

if (-not $BackupPath) {
  $BackupPath = Join-Path ([IO.Path]::GetTempPath()) "windows-deployment-schema-v1-backup-$([guid]::NewGuid().ToString('N')).zip"
}
$backupFullPath = [IO.Path]::GetFullPath($BackupPath)
if (Test-PathWithin $backupFullPath $deploymentRoot) { throw 'BackupPath must be outside deploy\windows.' }
if (Test-Path -LiteralPath $backupFullPath) { throw "Backup already exists: $backupFullPath" }
$backupParent = Split-Path -Parent $backupFullPath
New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
Compress-Archive -LiteralPath $deploymentRoot -DestinationPath $backupFullPath -CompressionLevel Optimal

$originalFiles = @{}
foreach ($file in $outdatedRuntimeFiles) {
  $path = Join-Path $deploymentRoot $file
  $originalFiles[$path] = [IO.File]::ReadAllBytes($path)
}
if ($configChanged) { $originalFiles[$configPath] = [IO.File]::ReadAllBytes($configPath) }

try {
  foreach ($file in $outdatedRuntimeFiles) {
    $source = Join-Path $templateRoot $file
    $destination = Join-Path $deploymentRoot $file
    Set-AtomicBytes $destination ([IO.File]::ReadAllBytes($source)) 'migrating'
  }
  if ($configChanged) {
    Set-AtomicBytes $configPath ([Text.UTF8Encoding]::new($false).GetBytes($candidateJson)) 'migrating'
  }
  & (Join-Path $deploymentRoot 'validate-config.ps1') -ConfigPath $configPath -ProjectRoot $root
} catch {
  $migrationError = $_
  foreach ($entry in $originalFiles.GetEnumerator()) {
    Set-AtomicBytes ([string]$entry.Key) ([byte[]]$entry.Value) 'rollback'
  }
  throw "Migration failed and project files were restored. Backup: $backupFullPath. Error: $($migrationError.Exception.Message)"
}
Write-Output "Migration completed. Backup: $backupFullPath"
Write-Warning 'Review the Git diff, confirm the application honors the selected bind-address variable, then run preflight.ps1 and install.ps1 from an elevated PowerShell session.'
