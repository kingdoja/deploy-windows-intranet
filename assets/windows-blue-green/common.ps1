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

function Enter-DeploymentOperationLock([int]$TimeoutSeconds = 5) {
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $identityBytes = [Text.Encoding]::UTF8.GetBytes($script:ProductionRoot.ToUpperInvariant())
    $identityHash = -join ($sha256.ComputeHash($identityBytes) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha256.Dispose()
  }
  $mutexName = "Global\DeployWindowsIntranet-$($identityHash.Substring(0, 24))"
  $mutex = [Threading.Mutex]::new($false, $mutexName)
  try {
    $acquired = $false
    try {
      $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if (-not $acquired) {
      throw "Another deployment, rollback, or installation is already running for $($script:DeploymentConfig.servicePrefix)."
    }
    return $mutex
  } catch {
    $mutex.Dispose()
    throw
  }
}

function Exit-DeploymentOperationLock($Mutex) {
  if (-not $Mutex) { return }
  try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Initialize-DeploymentDirectories {
  foreach ($path in @($script:ProductionRoot, $script:ToolsRoot, $script:ServiceRoot, $script:ReleasesRoot, $script:SlotsRoot, $script:StateRoot, $script:LogsRoot, (Join-Path $script:ProductionRoot 'data'))) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
  foreach ($slot in @('blue', 'green')) {
    New-Item -ItemType Directory -Path (Join-Path $script:SlotsRoot $slot) -Force | Out-Null
  }
}

function Test-DeploymentLoopbackListeners($Listeners) {
  $listeners = @($Listeners)
  if (-not $listeners.Count) { return $false }
  foreach ($listener in $listeners) {
    if ([string]$listener.LocalAddress -notin @('127.0.0.1', '::1', '::ffff:127.0.0.1')) { return $false }
  }
  return $true
}

function Invoke-DeploymentCommand($Command, [string]$WorkingDirectory) {
  $executable = [Environment]::ExpandEnvironmentVariables([string]$Command.executable)
  $arguments = @($Command.arguments | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
  Push-Location $WorkingDirectory
  try {
    & $executable @arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE`: $executable" }
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
function Get-DeploymentCaddyAdminPort {
  $property = $script:DeploymentConfig.PSObject.Properties['caddyAdminPort']
  if ($property) { return [int]$property.Value }
  return 2019
}
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

function Remove-DeploymentJunction([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $item = Get-Item -LiteralPath $Path -Force
  if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing to remove a path that is not a junction: $Path"
  }
  [IO.Directory]::Delete($item.FullName)
}

function Set-SlotRelease([string]$Slot, [string]$ReleasePath) {
  $resolvedRelease = (Resolve-Path -LiteralPath $ReleasePath).Path
  $resolvedReleasesRoot = (Resolve-Path -LiteralPath $script:ReleasesRoot).Path.TrimEnd('\') + '\'
  if (-not $resolvedRelease.StartsWith($resolvedReleasesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release must be inside $script:ReleasesRoot"
  }
  $current = Get-SlotCurrentPath $Slot
  $next = "$current.$PID.next"
  $previous = "$current.$PID.previous"
  foreach ($temporary in @($next, $previous)) {
    if (Test-Path -LiteralPath $temporary) { Remove-DeploymentJunction $temporary }
  }
  New-Item -ItemType Junction -Path $next -Target $resolvedRelease | Out-Null
  $hadCurrent = Test-Path -LiteralPath $current
  try {
    if ($hadCurrent) { Move-Item -LiteralPath $current -Destination $previous }
    Move-Item -LiteralPath $next -Destination $current
    if ($hadCurrent -and (Test-Path -LiteralPath $previous)) { Remove-DeploymentJunction $previous }
  } catch {
    if ((-not (Test-Path -LiteralPath $current)) -and (Test-Path -LiteralPath $previous)) {
      Move-Item -LiteralPath $previous -Destination $current
    }
    if (Test-Path -LiteralPath $next) { Remove-DeploymentJunction $next }
    throw
  }
}

function Clear-SlotRelease([string]$Slot) {
  $current = Get-SlotCurrentPath $Slot
  Remove-DeploymentJunction $current
}

function Restore-SlotRelease([string]$Slot, [string]$ReleasePath) {
  if ($ReleasePath) { Set-SlotRelease $Slot $ReleasePath } else { Clear-SlotRelease $Slot }
}

function Expand-DeploymentValue([string]$Value, $Service, [string]$Slot, [string]$ReleasePath) {
  $port = if ($Service -and [string]$Service.type -eq 'api') { [string](Get-DeploymentPort $Service $Slot) } else { '' }
  $expanded = $Value
  $expanded = $expanded.Replace('{ProductionRoot}', $script:ProductionRoot)
  $expanded = $expanded.Replace('{Slot}', $Slot)
  $expanded = $expanded.Replace('{Port}', $port)
  return $expanded.Replace('{ReleasePath}', $ReleasePath)
}

function Resolve-DeploymentProcessValue([string]$Value, $Service, [string]$Slot, [string]$ReleasePath) {
  $tokenExpanded = Expand-DeploymentValue $Value $Service $Slot $ReleasePath
  return [Environment]::ExpandEnvironmentVariables($tokenExpanded)
}

function Set-PostCutoverWarning([string]$Operation, [string]$Slot, [string]$Message) {
  $warning = [ordered]@{
    operation = $Operation
    slot = $Slot
    message = $Message
    recordedAt = (Get-Date).ToString('o')
  } | ConvertTo-Json
  Set-DeploymentAtomicText (Join-Path $script:StateRoot 'post-cutover-warning.json') "$warning`n"
}

function Clear-PostCutoverWarning {
  $path = Join-Path $script:StateRoot 'post-cutover-warning.json'
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
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
          $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
          if (-not (Test-DeploymentLoopbackListeners $listeners)) {
            $addresses = @($listeners | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique)
            throw "API $($Service.name) must listen only on loopback for slot isolation. Observed: $($addresses -join ', ')"
          }
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
      $candidate = Get-Service -Name (Get-DeploymentServiceName $_ $Slot) -ErrorAction SilentlyContinue
      $candidate -and $candidate.Status -ne 'Stopped'
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
  $names = @($services | Where-Object {
    $candidate = Get-Service -Name (Get-DeploymentServiceName $_ $Slot) -ErrorAction SilentlyContinue
    $candidate -and $candidate.Status -ne 'Stopped'
  } | ForEach-Object { Get-DeploymentServiceName $_ $Slot })
  throw "Services did not stop in time: $($names -join ', ')"
}

function Write-DeploymentCaddyfile([string]$Slot) {
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add('{')
  $lines.Add("  admin 127.0.0.1:$(Get-DeploymentCaddyAdminPort)")
  $lines.Add('}')
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
    $releasePath = Get-SlotRelease $Slot
    if (-not $releasePath) { throw "No release is attached to slot $Slot." }
    $staticRoot = Join-Path $releasePath $script:DeploymentConfig.staticSite.outputDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $staticRoot 'index.html'))) { throw "Static output has no index.html: $staticRoot" }
    $web = $staticRoot.Replace('\', '/')
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
    & $script:CaddyExe reload --address "127.0.0.1:$(Get-DeploymentCaddyAdminPort)" --config $script:Caddyfile --adapter caddyfile
    if ($LASTEXITCODE -ne 0) { throw 'Caddy reload failed.' }
  } else {
    Start-Service -Name $serviceName
  }
}

function Set-ActiveDeploymentState([string]$Slot, [string]$ReleasePath) {
  Set-DeploymentAtomicText (Join-Path $script:StateRoot 'active-slot.txt') "$Slot`n"
  $state = [ordered]@{ slot = $Slot; releasePath = $ReleasePath; switchedAt = (Get-Date).ToString('o') } | ConvertTo-Json
  Set-DeploymentAtomicText (Join-Path $script:StateRoot 'active-release.json') "$state`n"
}

function Clear-ActiveDeploymentState {
  foreach ($path in @((Join-Path $script:StateRoot 'active-slot.txt'), (Join-Path $script:StateRoot 'active-release.json'))) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
}
