param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DeploymentConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$script:DeploymentConfig = Get-Content -Raw -LiteralPath $script:DeploymentConfigPath | ConvertFrom-Json
$script:SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ProductionRoot = [Environment]::ExpandEnvironmentVariables([string]$script:DeploymentConfig.productionRoot)
$script:ToolsRoot = Join-Path $script:ProductionRoot 'tools'
$script:ServiceRoot = Join-Path $script:ProductionRoot 'service'
$script:ReleasesRoot = Join-Path $script:ProductionRoot 'releases'
$script:SlotsRoot = Join-Path $script:ProductionRoot 'slots'
$script:WebRoot = Join-Path $script:ProductionRoot 'web'
$script:StateRoot = Join-Path $script:ProductionRoot 'state'
$script:LogsRoot = Join-Path $script:ProductionRoot 'logs'
$script:CaddyExe = Join-Path $script:ToolsRoot 'caddy.exe'
$script:Caddyfile = Join-Path $script:ServiceRoot 'Caddyfile'
$script:NodeExe = (Get-Command node.exe -ErrorAction Stop).Source

function Assert-DeploymentAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this command from an elevated PowerShell session.'
  }
}

function Initialize-DeploymentDirectories {
  foreach ($path in @($script:ProductionRoot, $script:ToolsRoot, $script:ServiceRoot, $script:ReleasesRoot, $script:SlotsRoot, $script:WebRoot, $script:StateRoot, $script:LogsRoot, (Join-Path $script:ProductionRoot 'data'))) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
  foreach ($slot in @('blue', 'green')) {
    New-Item -ItemType Directory -Path (Join-Path $script:SlotsRoot $slot) -Force | Out-Null
  }
}

function Invoke-DeploymentCommand($Command, [string]$WorkingDirectory) {
  $executable = [Environment]::ExpandEnvironmentVariables([string]$Command.executable)
  $arguments = @($Command.arguments | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
  Push-Location $WorkingDirectory
  try {
    & $executable @arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE`: $executable $($arguments -join ' ')" }
  } finally {
    Pop-Location
  }
}

function Set-DeploymentAtomicText([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $temporary = "$Path.$PID.tmp"
  [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-DeploymentServiceToken([string]$Name) {
  return -join ($Name -split '-' | ForEach-Object {
    if ($_.Length -eq 1) { $_.ToUpperInvariant() } else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
  })
}

function Get-DeploymentServiceName($Service, [string]$Slot) {
  $slotToken = $Slot.Substring(0, 1).ToUpperInvariant() + $Slot.Substring(1)
  return "$($script:DeploymentConfig.servicePrefix)$(Get-DeploymentServiceToken ([string]$Service.name))$slotToken"
}

function Get-CaddyServiceName { return "$($script:DeploymentConfig.servicePrefix)Caddy" }
function Get-MemoryGuardServiceName { return "$($script:DeploymentConfig.servicePrefix)MemoryGuard" }
function Get-BackupTaskName { return "$($script:DeploymentConfig.servicePrefix) Daily Backup" }

function Get-DeploymentPort($Service, [string]$Slot) {
  if ($Slot -eq 'blue') { return [int]$Service.bluePort }
  if ($Slot -eq 'green') { return [int]$Service.greenPort }
  throw "Invalid slot: $Slot"
}

function Get-OtherDeploymentSlot([string]$Slot) {
  if ($Slot -eq 'blue') { return 'green' }
  if ($Slot -eq 'green') { return 'blue' }
  throw "Invalid slot: $Slot"
}

function Get-ActiveDeploymentSlot {
  $path = Join-Path $script:StateRoot 'active-slot.txt'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $slot = (Get-Content -Raw -LiteralPath $path).Trim()
  if ($slot -notin @('blue', 'green')) { throw "Invalid active slot state: $slot" }
  return $slot
}

function Get-SlotCurrentPath([string]$Slot) { return Join-Path (Join-Path $script:SlotsRoot $Slot) 'current' }

function Get-SlotRelease([string]$Slot) {
  $current = Get-SlotCurrentPath $Slot
  if (-not (Test-Path -LiteralPath $current)) { return $null }
  $item = Get-Item -LiteralPath $current -Force
  if (-not $item.Target) { throw "Slot path is not a junction: $current" }
  return [string]@($item.Target)[0]
}

function Set-SlotRelease([string]$Slot, [string]$ReleasePath) {
  $resolvedRelease = (Resolve-Path -LiteralPath $ReleasePath).Path
  $resolvedReleasesRoot = (Resolve-Path -LiteralPath $script:ReleasesRoot).Path.TrimEnd('\') + '\'
  if (-not $resolvedRelease.StartsWith($resolvedReleasesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release must be inside $script:ReleasesRoot"
  }
  $current = Get-SlotCurrentPath $Slot
  if (Test-Path -LiteralPath $current) { Remove-Item -LiteralPath $current -Force }
  New-Item -ItemType Junction -Path $current -Target $resolvedRelease | Out-Null
}

function Expand-DeploymentValue([string]$Value, $Service, [string]$Slot, [string]$ReleasePath) {
  $port = if ($Service -and [string]$Service.type -eq 'api') { [string](Get-DeploymentPort $Service $Slot) } else { '' }
  $expanded = [Environment]::ExpandEnvironmentVariables($Value)
  $expanded = $expanded.Replace('{ProductionRoot}', $script:ProductionRoot)
  $expanded = $expanded.Replace('{Slot}', $Slot)
  $expanded = $expanded.Replace('{Port}', $port)
  return $expanded.Replace('{ReleasePath}', $ReleasePath)
}

function Wait-DeploymentHealth($Service, [string]$Slot, [int]$TimeoutSeconds = 90) {
  $port = Get-DeploymentPort $Service $Slot
  $url = "http://127.0.0.1:$port$($Service.healthPath)"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastError = $null
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 5
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        $json = $null
        try { $json = $response.Content | ConvertFrom-Json } catch { }
        if ($json -and (($json.PSObject.Properties.Name -contains 'ok' -and $json.ok -eq $false) -or ($json.PSObject.Properties.Name -contains 'ready' -and $json.ready -eq $false))) {
          $lastError = "Health JSON reports not ready: $($response.Content)"
        } else {
          return
        }
      }
    } catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Seconds 2
  }
  throw "Health check timed out for $($Service.name) at $url. Last error: $lastError"
}

function Start-DeploymentSlot([string]$Slot) {
  foreach ($service in @($script:DeploymentConfig.services | Where-Object { $_.type -eq 'api' })) {
    $name = Get-DeploymentServiceName $service $Slot
    Set-Service -Name $name -StartupType Automatic
    if ((Get-Service -Name $name).Status -ne 'Running') { Start-Service -Name $name }
    Wait-DeploymentHealth $service $Slot
  }
  foreach ($service in @($script:DeploymentConfig.services | Where-Object { $_.type -eq 'worker' })) {
    $name = Get-DeploymentServiceName $service $Slot
    Set-Service -Name $name -StartupType Automatic
    if ((Get-Service -Name $name).Status -ne 'Running') { Start-Service -Name $name }
  }
}

function Stop-DeploymentSlot([string]$Slot) {
  $services = @($script:DeploymentConfig.services)
  foreach ($service in $services) {
    $name = Get-DeploymentServiceName $service $Slot
    Set-Service -Name $name -StartupType Manual
    $state = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($state -and $state.Status -ne 'Stopped') { Stop-Service -Name $name -ErrorAction SilentlyContinue }
  }

  $maxStop = [int](($services | Measure-Object -Property stopTimeoutSeconds -Maximum).Maximum)
  $deadline = (Get-Date).AddSeconds($maxStop + 20)
  $stoppedSince = $null
  while ((Get-Date) -lt $deadline) {
    $running = @($services | Where-Object {
      (Get-Service -Name (Get-DeploymentServiceName $_ $Slot) -ErrorAction SilentlyContinue).Status -ne 'Stopped'
    })
    if (-not $running.Count) {
      if (-not $stoppedSince) { $stoppedSince = Get-Date }
      if (((Get-Date) - $stoppedSince).TotalSeconds -ge 10) { return }
    } else {
      $stoppedSince = $null
      foreach ($service in $running) { Stop-Service -Name (Get-DeploymentServiceName $service $Slot) -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
  }
  $names = @($services | Where-Object { (Get-Service -Name (Get-DeploymentServiceName $_ $Slot)).Status -ne 'Stopped' } | ForEach-Object { Get-DeploymentServiceName $_ $Slot })
  throw "Services did not stop in time: $($names -join ', ')"
}

function Write-DeploymentCaddyfile([string]$Slot) {
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add(":$($script:DeploymentConfig.listenPort) {")
  $index = 0
  foreach ($service in @($script:DeploymentConfig.services | Where-Object { $_.type -eq 'api' })) {
    $matcher = "service$index"
    $routes = @($service.routePaths) -join ' '
    $lines.Add("  @$matcher path $routes")
    $lines.Add("  handle @$matcher {")
    $lines.Add("    reverse_proxy 127.0.0.1:$(Get-DeploymentPort $service $Slot)")
    $lines.Add('  }')
    $index++
  }
  if ($script:DeploymentConfig.staticSite.enabled) {
    $web = $script:WebRoot.Replace('\', '/')
    $lines.Add('  handle {')
    $lines.Add("    root * `"$web`"")
    $lines.Add('    try_files {path} /index.html')
    $lines.Add('    file_server')
    $lines.Add('  }')
  }
  $log = (Join-Path $script:LogsRoot 'caddy-access.log').Replace('\', '/')
  $lines.Add('  log {')
  $lines.Add("    output file `"$log`"")
  $lines.Add('  }')
  $lines.Add('}')
  Set-DeploymentAtomicText $script:Caddyfile (($lines -join "`n") + "`n")
}

function Publish-DeploymentCaddyConfiguration([string]$Slot) {
  Write-DeploymentCaddyfile $Slot
  & $script:CaddyExe validate --config $script:Caddyfile --adapter caddyfile
  if ($LASTEXITCODE -ne 0) { throw 'Caddy configuration validation failed.' }
  $serviceName = Get-CaddyServiceName
  $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if (-not $service) { throw "Caddy service is not installed: $serviceName" }
  Set-Service -Name $serviceName -StartupType Automatic
  if ($service.Status -eq 'Running') {
    & $script:CaddyExe reload --config $script:Caddyfile --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Caddy reload failed.' }
  } else {
    Start-Service -Name $serviceName
  }
}

function Publish-DeploymentWeb([string]$ReleasePath) {
  if (-not $script:DeploymentConfig.staticSite.enabled) { return }
  $dist = Join-Path $ReleasePath $script:DeploymentConfig.staticSite.outputDirectory
  if (-not (Test-Path -LiteralPath (Join-Path $dist 'index.html'))) { throw "Static output has no index.html: $dist" }
  New-Item -ItemType Directory -Path $script:WebRoot -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $dist -Force | Where-Object { $_.Name -ne 'index.html' }) {
    Copy-Item -LiteralPath $item.FullName -Destination $script:WebRoot -Recurse -Force
  }
  $temporaryIndex = Join-Path $script:WebRoot "index.html.$PID.tmp"
  Copy-Item -LiteralPath (Join-Path $dist 'index.html') -Destination $temporaryIndex -Force
  Move-Item -LiteralPath $temporaryIndex -Destination (Join-Path $script:WebRoot 'index.html') -Force
}

function Set-ActiveDeploymentState([string]$Slot, [string]$ReleasePath) {
  Set-DeploymentAtomicText (Join-Path $script:StateRoot 'active-slot.txt') "$Slot`n"
  $state = [ordered]@{ slot = $Slot; releasePath = $ReleasePath; switchedAt = (Get-Date).ToString('o') } | ConvertTo-Json
  Set-DeploymentAtomicText (Join-Path $script:StateRoot 'active-release.json') "$state`n"
}
