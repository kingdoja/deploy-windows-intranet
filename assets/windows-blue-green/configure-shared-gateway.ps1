[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'),
  [Parameter(Mandatory)][string[]]$Hostnames,
  [Parameter(Mandatory)][string]$GatewayCaddyfile,
  [Parameter(Mandatory)][string]$GatewayCaddyExe,
  [string]$GatewayAdminAddress = '127.0.0.1:2019',
  [string]$RouteDirectory = 'C:\ProgramData\IntranetGateway\routes',
  [string]$RouteName,
  [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
if (-not $RouteName) { $RouteName = ([string]$config.servicePrefix).ToLowerInvariant() }
if ($RouteName -notmatch '^[a-z][a-z0-9-]{0,62}$') { throw 'RouteName must be a safe lowercase DNS-style token.' }
foreach ($hostname in $Hostnames) {
  if ($hostname -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
    throw "Invalid hostname: $hostname"
  }
}
if ($GatewayAdminAddress -notmatch '^(127\.0\.0\.1|\[::1\]):[1-9][0-9]{0,4}$') { throw 'GatewayAdminAddress must be a loopback host and port.' }
$gatewayAdminPort = [int]($GatewayAdminAddress -replace '^.*:', '')
if ($gatewayAdminPort -gt 65535) { throw 'GatewayAdminAddress port must be at most 65535.' }

$routeDirectoryFull = [IO.Path]::GetFullPath($RouteDirectory).TrimEnd('\')
$routePath = Join-Path $routeDirectoryFull "$RouteName.caddy"
$matcher = ($RouteName -replace '-', '_')
$content = @"
@$matcher host $($Hostnames -join ' ')
handle @$matcher {
    reverse_proxy 127.0.0.1:$([int]$config.listenPort)
}
"@

if (-not $Apply) {
  Write-Output "Shared gateway route candidate: $routePath"
  Write-Output $content
  Write-Output "The gateway owner must import $($routeDirectoryFull.Replace('\', '/'))/*.caddy inside its HTTP server block."
  Write-Warning 'Dry run only. Rerun with -Apply after gateway ownership, DNS, and rollback are reviewed.'
  return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Applying a shared gateway route requires elevated PowerShell.' }
foreach ($path in @($GatewayCaddyfile, $GatewayCaddyExe)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required gateway file not found: $path" }
}
$gatewaySource = Get-Content -Raw -LiteralPath $GatewayCaddyfile
$importTarget = "$($routeDirectoryFull.Replace('\', '/'))/*.caddy"
if ($gatewaySource -notmatch "(?im)^\s*import\s+$([regex]::Escape($importTarget))\s*$") {
  throw "Gateway Caddyfile does not import $importTarget. The gateway owner must add and persist that import first."
}

New-Item -ItemType Directory -Path $routeDirectoryFull -Force | Out-Null
$backup = $null
if (Test-Path -LiteralPath $routePath) {
  $backup = "$routePath.backup-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
  Copy-Item -LiteralPath $routePath -Destination $backup -Force
}

try {
  if ($PSCmdlet.ShouldProcess($routePath, 'Install and reload shared Caddy gateway route')) {
    $temp = "$routePath.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temp, $content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $routePath -Force
    & $GatewayCaddyExe validate --config $GatewayCaddyfile --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Shared gateway configuration validation failed.' }
    & $GatewayCaddyExe reload --address $GatewayAdminAddress --config $GatewayCaddyfile --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Shared gateway reload failed.' }
  }
} catch {
  if ($backup) { Copy-Item -LiteralPath $backup -Destination $routePath -Force }
  else { Remove-Item -LiteralPath $routePath -Force -ErrorAction SilentlyContinue }
  throw
}

Write-Output "Shared gateway route installed: $routePath"
