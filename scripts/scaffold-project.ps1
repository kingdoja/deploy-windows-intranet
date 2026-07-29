[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ProjectRoot,
  [string]$AppName,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$skillRoot = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $skillRoot 'assets\windows-blue-green'
if (-not (Test-Path -LiteralPath $templateRoot)) { throw "Template not found: $templateRoot" }

$packagePath = Join-Path $root 'package.json'
$package = if (Test-Path -LiteralPath $packagePath) { Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json } else { $null }
if (-not $AppName) {
  $AppName = if ($package -and $package.PSObject.Properties.Name -contains 'name') { [string]$package.name } else { Split-Path -Leaf $root }
}

$prefix = -join ($AppName -split '[^A-Za-z0-9]+' | Where-Object { $_ } | ForEach-Object {
  if ($_.Length -eq 1) { $_.ToUpperInvariant() } else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
})
if (-not $prefix) { $prefix = 'IntranetApp' }
if ($prefix[0] -match '\d') { $prefix = "App$prefix" }

$destination = Join-Path $root 'deploy\windows'
$existing = @()
if (Test-Path -LiteralPath $destination) {
  $existing = @(Get-ChildItem -LiteralPath $destination -Force)
}
if ($existing.Count -and -not $Force) {
  throw "Deployment directory is not empty: $destination. Review it first; use -Force only when overwrite is explicitly intended."
}

New-Item -ItemType Directory -Path $destination -Force | Out-Null
Get-ChildItem -LiteralPath $templateRoot -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
}

$exampleConfig = Join-Path $destination 'deployment.config.example.json'
$configPath = Join-Path $destination 'deployment.config.json'
$config = Get-Content -Raw -LiteralPath $exampleConfig | ConvertFrom-Json
$config.appName = $AppName
$config.servicePrefix = $prefix
$config.productionRoot = "C:\ProgramData\$prefix"
$config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8
Remove-Item -LiteralPath $exampleConfig -Force

$docsRoot = Join-Path $root 'docs'
New-Item -ItemType Directory -Path $docsRoot -Force | Out-Null
$runbookTemplate = Join-Path $destination 'WINDOWS_INTRANET_RUNBOOK.template.md'
$runbookPath = Join-Path $docsRoot 'WINDOWS_INTRANET_DEPLOYMENT.md'
if ((Test-Path -LiteralPath $runbookPath) -and -not $Force) {
  throw "Runbook already exists: $runbookPath"
}
$runbook = (Get-Content -Raw -LiteralPath $runbookTemplate).Replace('{{APP_NAME}}', $AppName).Replace('{{SERVICE_PREFIX}}', $prefix)
[IO.File]::WriteAllText($runbookPath, $runbook, [Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath $runbookTemplate -Force

Write-Output "Created deployment package: $destination"
Write-Output "Created Runbook: $runbookPath"
Write-Warning 'Customize deployment.config.json and the Runbook before running install.ps1.'
