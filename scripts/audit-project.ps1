[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$rootPrefix = $root.TrimEnd('\') + '\'
function Get-ProjectRelativePath([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside the project root: $fullPath"
  }
  return $fullPath.Substring($rootPrefix.Length).Replace('/', '\')
}
$packagePath = Join-Path $root 'package.json'
$package = $null
if (Test-Path -LiteralPath $packagePath) {
  $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
}

$relativeFiles = @()
$rg = Get-Command rg -ErrorAction SilentlyContinue
if ($rg) {
  $relativeFiles = @(& $rg.Source --files $root | ForEach-Object {
    Get-ProjectRelativePath $_
  })
} else {
  $relativeFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
    Get-ProjectRelativePath $_.FullName
  })
}

$entryCandidates = @($relativeFiles | Where-Object {
  $_ -notmatch '\.(test|spec)\.' -and (
    $_ -match '^(server|api|worker|backend)\\[^\\]*(api|worker|server)[^\\]*\.(js|mjs|cjs|ts)$' -or
    $_ -match '^(server|api|worker|backend)\\(index|main|app)\.(js|mjs|cjs|ts)$'
  )
} | Sort-Object -Unique)

$healthCandidates = @()
if ($rg) {
  $healthCandidates = @(& $rg.Source -l --glob '*.{js,mjs,cjs,ts,tsx}' '(health|ready|readiness|liveness)' $root 2>$null | ForEach-Object {
    Get-ProjectRelativePath $_
  } | Where-Object {
    $_ -notmatch '\.(test|spec)\.' -and $_ -match '^(server|api|backend|scripts)\\'
  } | Sort-Object -Unique)
}

$scripts = [ordered]@{}
if ($package -and $package.PSObject.Properties.Name -contains 'scripts') {
  foreach ($property in $package.scripts.PSObject.Properties) {
    $scripts[$property.Name] = [string]$property.Value
  }
}

$persistentCandidates = [Collections.Generic.List[string]]::new()
foreach ($directoryName in @('data', 'storage', 'uploads', 'media', 'database', 'db')) {
  if (Test-Path -LiteralPath (Join-Path $root $directoryName)) { $persistentCandidates.Add("$directoryName\") }
}
if ($rg) {
  foreach ($path in @(& $rg.Source --files --hidden --no-ignore -g '*.db' -g '*.sqlite' -g '*.sqlite3' -g '!node_modules/**' -g '!.git/**' $root 2>$null | Select-Object -First 100)) {
    $persistentCandidates.Add((Get-ProjectRelativePath $path))
  }
}

$result = [ordered]@{
  projectRoot = $root
  packageName = if ($package -and $package.PSObject.Properties.Name -contains 'name') { $package.name } else { $null }
  packageManager = if (Test-Path (Join-Path $root 'pnpm-lock.yaml')) { 'pnpm' } elseif (Test-Path (Join-Path $root 'yarn.lock')) { 'yarn' } elseif (Test-Path (Join-Path $root 'package-lock.json')) { 'npm' } else { $null }
  scripts = $scripts
  entryCandidates = $entryCandidates
  healthCandidates = $healthCandidates
  persistentCandidates = @($persistentCandidates | Sort-Object -Unique)
  hasViteConfig = [bool]($relativeFiles | Where-Object { $_ -match '(^|\\)vite\.config\.(js|mjs|ts)$' } | Select-Object -First 1)
  hasExistingDeployment = Test-Path -LiteralPath (Join-Path $root 'deploy\windows')
  requiresManualReview = @(
    'Confirm API and worker entry points.',
    'Confirm health readiness semantics and graceful shutdown.',
    'Confirm persistent paths, migration compatibility, backup, and restore.',
    'Confirm internal DNS, firewall range, and secret injection.'
  )
}

$result | ConvertTo-Json -Depth 8
