[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$deploymentRoot = Join-Path $root 'deploy\windows'
$configPath = Join-Path $deploymentRoot 'deployment.config.json'
$validator = Join-Path $deploymentRoot 'validate-config.ps1'
if (-not (Test-Path -LiteralPath $validator)) { throw "Missing generated validator: $validator" }

& $validator -ConfigPath $configPath -ProjectRoot $root

$required = @('common.ps1', 'preflight.ps1', 'install.ps1', 'deploy.ps1', 'rollback.ps1', 'status.ps1', 'memory-guard.ps1', 'backup.ps1')
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $deploymentRoot $_)) })
if ($missing.Count) { throw "Missing generated files: $($missing -join ', ')" }

Write-Output "Deployment package is valid: $deploymentRoot"
