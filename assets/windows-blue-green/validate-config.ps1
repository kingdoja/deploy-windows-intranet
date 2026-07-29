[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'),
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

function Add-ConfigError([string]$Message) { $errors.Add($Message) }
function Add-ConfigWarning([string]$Message) { $warnings.Add($Message) }
function Has-Property($Object, [string]$Name) {
  return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}
function Test-SafeRelativePath([string]$Value) {
  if (-not $Value -or [IO.Path]::IsPathRooted($Value)) { return $false }
  return -not (@($Value -split '[\\/]' | Where-Object { $_ -eq '..' }).Count)
}
function Get-NormalizedServiceToken([string]$Name) {
  return -join ($Name -split '-' | ForEach-Object {
    if ($_.Length -eq 1) { $_.ToUpperInvariant() } else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
  })
}
function Test-CommandObject($Command, [string]$Name) {
  if (-not $Command -or -not (Has-Property $Command 'executable') -or -not [string]$Command.executable) {
    Add-ConfigError "$Name.executable is required."
    return
  }
  if (-not (Has-Property $Command 'arguments')) { Add-ConfigError "$Name.arguments is required." }
  foreach ($argument in @($Command.arguments)) {
    if ([string]$argument -match '[;&|<>]') {
      Add-ConfigError "$Name contains a shell control character in an argument. Use an executable plus plain arguments."
    }
  }
}
function Test-EnvironmentObject($Environment, [string]$Name) {
  if (-not $Environment) { return }
  foreach ($property in $Environment.PSObject.Properties) {
    if ($property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
      Add-ConfigError "$Name has an invalid environment variable name: $($property.Name)"
    }
    if ($property.Name -match '(?i)(secret|token|password|api.?key|private.?key)' -and [string]$property.Value -notmatch '^%[A-Za-z_][A-Za-z0-9_]*%$') {
      Add-ConfigError "$Name.$($property.Name) appears to contain a secret. Reference a machine variable such as %VARIABLE_NAME%."
    }
  }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

try {
  $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
} catch {
  throw "Invalid JSON in $ConfigPath`: $($_.Exception.Message)"
}

if (-not (Has-Property $config 'schemaVersion') -or $config.schemaVersion -ne 1) { Add-ConfigError 'schemaVersion must be 1.' }
if (-not [string]$config.appName) { Add-ConfigError 'appName is required.' }
if ([string]$config.servicePrefix -notmatch '^[A-Za-z][A-Za-z0-9]{1,39}$') { Add-ConfigError 'servicePrefix must be 2-40 ASCII letters or digits and start with a letter.' }

if (-not [IO.Path]::IsPathRooted([string]$config.productionRoot)) {
  Add-ConfigError 'productionRoot must be an absolute path.'
} else {
  $fullProductionRoot = [IO.Path]::GetFullPath([string]$config.productionRoot).TrimEnd('\')
  $driveRoot = [IO.Path]::GetPathRoot($fullProductionRoot).TrimEnd('\')
  if ($fullProductionRoot -eq $driveRoot) { Add-ConfigError 'productionRoot cannot be a drive root.' }
  if ($fullProductionRoot.StartsWith($ProjectRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    Add-ConfigError 'productionRoot must be outside the source checkout.'
  }
}

if ([int]$config.listenPort -lt 1 -or [int]$config.listenPort -gt 65535) { Add-ConfigError 'listenPort must be between 1 and 65535.' }
if (-not @($config.publicOrigins).Count) { Add-ConfigError 'At least one publicOrigins value is required.' }
foreach ($origin in @($config.publicOrigins)) {
  $uri = $null
  if (-not [Uri]::TryCreate([string]$origin, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
    Add-ConfigError "Invalid public origin: $origin"
  }
}
if (-not @($config.firewallRemoteAddresses).Count) { Add-ConfigError 'firewallRemoteAddresses cannot be empty.' }
if (@($config.firewallRemoteAddresses) -contains '0.0.0.0/0') { Add-ConfigWarning 'Firewall allows every IPv4 address.' }

foreach ($toolField in @('caddyVersion', 'caddySha256', 'winswVersion', 'winswSha256')) {
  if (-not (Has-Property $config.tools $toolField) -or -not [string]$config.tools.$toolField) { Add-ConfigError "tools.$toolField is required." }
}
foreach ($hashField in @('caddySha256', 'winswSha256')) {
  if ([string]$config.tools.$hashField -notmatch '^[A-Fa-f0-9]{64}$') { Add-ConfigError "tools.$hashField must be a SHA-256 hash." }
}

Test-CommandObject $config.release.testCommand 'release.testCommand'
Test-CommandObject $config.release.buildCommand 'release.buildCommand'
Test-CommandObject $config.release.installCommand 'release.installCommand'

foreach ($path in @($config.release.includeDirectories) + @($config.release.includeFiles)) {
  if (-not (Test-SafeRelativePath ([string]$path))) { Add-ConfigError "Unsafe release include path: $path"; continue }
  if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $path))) { Add-ConfigError "Release include path does not exist: $path" }
}
if ($config.staticSite.enabled) {
  if (-not (Test-SafeRelativePath ([string]$config.staticSite.outputDirectory))) { Add-ConfigError 'staticSite.outputDirectory must be a safe relative path.' }
  if (@($config.release.includeDirectories) -notcontains [string]$config.staticSite.outputDirectory) { Add-ConfigError 'staticSite.outputDirectory must be listed in release.includeDirectories.' }
}

Test-EnvironmentObject $config.commonEnvironment 'commonEnvironment'
if (-not @($config.services).Count) { Add-ConfigError 'At least one service is required.' }
$serviceNames = @{}
$generatedServiceIds = @{}
$ports = @{}
$apiCount = 0
foreach ($service in @($config.services)) {
  $name = [string]$service.name
  if ($name -notmatch '^[a-z][a-z0-9-]{0,30}$') { Add-ConfigError "Invalid service name: $name" }
  if ($serviceNames.ContainsKey($name)) { Add-ConfigError "Duplicate service name: $name" } else { $serviceNames[$name] = $true }
  foreach ($slot in @('Blue', 'Green')) {
    $generatedId = "$($config.servicePrefix)$(Get-NormalizedServiceToken $name)$slot"
    $collisionKey = $generatedId.ToLowerInvariant()
    if ($generatedServiceIds.ContainsKey($collisionKey)) {
      Add-ConfigError "Service name $name collides with $($generatedServiceIds[$collisionKey]) after Windows service ID normalization: $generatedId"
    } else {
      $generatedServiceIds[$collisionKey] = $name
    }
  }
  if ([string]$service.type -notin @('api', 'worker')) { Add-ConfigError "Service $name type must be api or worker." }
  if (-not (Test-SafeRelativePath ([string]$service.entry))) { Add-ConfigError "Service $name has an unsafe entry path." }
  elseif (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $service.entry))) { Add-ConfigError "Service entry does not exist: $($service.entry)" }
  if ([int]$service.stopTimeoutSeconds -lt 10) { Add-ConfigError "Service $name stopTimeoutSeconds must be at least 10." }
  if ([int]$service.memoryLimitMb -lt 128) { Add-ConfigError "Service $name memoryLimitMb must be at least 128." }
  Test-EnvironmentObject $service.environment "services.$name.environment"

  if ($service.type -eq 'api') {
    $apiCount++
    if ([string]$service.portEnvironment -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Add-ConfigError "API $name requires portEnvironment." }
    foreach ($field in @('bluePort', 'greenPort')) {
      $port = [int]$service.$field
      if ($port -lt 1 -or $port -gt 65535) { Add-ConfigError "API $name $field is invalid." }
      elseif ($ports.ContainsKey($port)) { Add-ConfigError "Port $port is duplicated by API $name." } else { $ports[$port] = $name }
    }
    if ([string]$service.healthPath -notmatch '^/') { Add-ConfigError "API $name healthPath must start with /." }
    if (-not @($service.routePaths).Count) { Add-ConfigError "API $name requires at least one routePaths entry." }
    foreach ($route in @($service.routePaths)) {
      if ([string]$route -notmatch '^/') { Add-ConfigError "API $name route must start with /: $route" }
    }
  }
}
if ($apiCount -eq 0) { Add-ConfigError 'At least one API service is required.' }
if ($ports.ContainsKey([int]$config.listenPort)) { Add-ConfigError 'listenPort conflicts with a slot API port.' }

if ($config.memoryGuard.enabled) {
  if ([int]$config.memoryGuard.pollSeconds -lt 10) { Add-ConfigError 'memoryGuard.pollSeconds must be at least 10.' }
  if ([int]$config.memoryGuard.sustainedSeconds -lt [int]$config.memoryGuard.pollSeconds) { Add-ConfigError 'memoryGuard.sustainedSeconds must be at least pollSeconds.' }
}
if ($config.backup.enabled) {
  if ([string]$config.backup.schedule -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Add-ConfigError 'backup.schedule must use HH:mm.' }
  Test-CommandObject $config.backup.command 'backup.command'
} else {
  Add-ConfigWarning 'Scheduled backup is disabled. Record the accepted risk or configure an application-consistent backup.'
}

foreach ($warning in $warnings) { Write-Warning $warning }
if ($errors.Count) {
  foreach ($message in $errors) { Write-Error $message -ErrorAction Continue }
  throw "Deployment configuration has $($errors.Count) error(s)."
}

Write-Output "Configuration is valid: $ConfigPath"
