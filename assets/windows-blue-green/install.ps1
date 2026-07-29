[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'),
  [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
  [switch]$SkipTests,
  [switch]$AllowDirty,
  [switch]$SkipInitialDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'preflight.ps1') -ConfigPath $ConfigPath -ProjectRoot $SourceRoot
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath
Assert-DeploymentAdministrator
Initialize-DeploymentDirectories

function Escape-DeploymentXml([string]$Value) { return [Security.SecurityElement]::Escape($Value) }

function Get-VerifiedDeploymentDownload([string]$Url, [string]$Destination, [string]$ExpectedHash) {
  if (Test-Path -LiteralPath $Destination) {
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -eq $ExpectedHash) { return }
    Remove-Item -LiteralPath $Destination -Force
  }
  & curl.exe --fail --location --retry 5 --retry-all-errors --connect-timeout 20 --output $Destination $Url
  if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
  $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
  if ($actual -ne $ExpectedHash) {
    Remove-Item -LiteralPath $Destination -Force
    throw "SHA-256 mismatch for $Url"
  }
}

function Install-DeploymentTools {
  $downloadRoot = Join-Path $script:ToolsRoot 'downloads'
  New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
  $caddyVersion = [string]$script:DeploymentConfig.tools.caddyVersion
  $caddyZip = Join-Path $downloadRoot "caddy-$caddyVersion.zip"
  $caddyUrl = "https://github.com/caddyserver/caddy/releases/download/v$caddyVersion/caddy_${caddyVersion}_windows_amd64.zip"
  Get-VerifiedDeploymentDownload $caddyUrl $caddyZip ([string]$script:DeploymentConfig.tools.caddySha256)
  $caddyStage = Join-Path $downloadRoot "caddy-$caddyVersion"
  if (Test-Path -LiteralPath $caddyStage) { Remove-Item -LiteralPath $caddyStage -Recurse -Force }
  Expand-Archive -LiteralPath $caddyZip -DestinationPath $caddyStage -Force
  $stagedCaddy = Join-Path $caddyStage 'caddy.exe'
  $caddyChanged = -not (Test-Path -LiteralPath $script:CaddyExe) -or
    (Get-FileHash -LiteralPath $stagedCaddy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $script:CaddyExe -Algorithm SHA256).Hash
  if ($caddyChanged) {
    $caddyService = Get-Service -Name (Get-CaddyServiceName) -ErrorAction SilentlyContinue
    if ($caddyService -and $caddyService.Status -ne 'Stopped') {
      throw 'Caddy binary version changed while the service is running. Schedule a maintenance window, stop the Caddy service, and rerun installation.'
    }
    Copy-Item -LiteralPath $stagedCaddy -Destination $script:CaddyExe -Force
  }

  $winswVersion = [string]$script:DeploymentConfig.tools.winswVersion
  $winsw = Join-Path $script:ToolsRoot 'WinSW-x64.exe'
  $winswUrl = "https://github.com/winsw/winsw/releases/download/v$winswVersion/WinSW-x64.exe"
  Get-VerifiedDeploymentDownload $winswUrl $winsw ([string]$script:DeploymentConfig.tools.winswSha256)
}

function Install-WrappedDeploymentService([string]$Id, [string]$Xml) {
  $winsw = Join-Path $script:ToolsRoot 'WinSW-x64.exe'
  $serviceExe = Join-Path $script:ServiceRoot "$Id.exe"
  $serviceXml = Join-Path $script:ServiceRoot "$Id.xml"
  $wrapperChanged = -not (Test-Path -LiteralPath $serviceExe) -or
    (Get-FileHash -LiteralPath $winsw -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $serviceExe -Algorithm SHA256).Hash
  if ($wrapperChanged) {
    $existingService = Get-Service -Name $Id -ErrorAction SilentlyContinue
    if ($existingService -and $existingService.Status -ne 'Stopped') {
      throw "WinSW binary version changed while service $Id is running. Schedule a maintenance window and stop the service before installation."
    }
    Copy-Item -LiteralPath $winsw -Destination $serviceExe -Force
  }
  Set-DeploymentAtomicText $serviceXml $Xml
  if (Get-Service -Name $Id -ErrorAction SilentlyContinue) {
    & $serviceExe refresh
    if ($LASTEXITCODE -ne 0) { throw "Failed to refresh Windows service: $Id" }
  } else {
    & $serviceExe install
    if ($LASTEXITCODE -ne 0) { throw "Failed to install Windows service: $Id" }
  }
}

function Get-ServiceEnvironmentXml($Service, [string]$Slot, [string]$CurrentPath) {
  $values = [ordered]@{}
  if ([string]$script:DeploymentConfig.productionRootEnvironment) { $values[[string]$script:DeploymentConfig.productionRootEnvironment] = $script:ProductionRoot }
  if ([string]$script:DeploymentConfig.allowedOriginsEnvironment) { $values[[string]$script:DeploymentConfig.allowedOriginsEnvironment] = (@($script:DeploymentConfig.publicOrigins) -join ',') }
  foreach ($property in $script:DeploymentConfig.commonEnvironment.PSObject.Properties) {
    $values[$property.Name] = Expand-DeploymentValue ([string]$property.Value) $Service $Slot $CurrentPath
  }
  foreach ($property in $Service.environment.PSObject.Properties) {
    $values[$property.Name] = Expand-DeploymentValue ([string]$property.Value) $Service $Slot $CurrentPath
  }
  if ($Service.type -eq 'api') { $values[[string]$Service.portEnvironment] = [string](Get-DeploymentPort $Service $Slot) }
  return @($values.GetEnumerator() | ForEach-Object {
    "  <env name=`"$(Escape-DeploymentXml ([string]$_.Key))`" value=`"$(Escape-DeploymentXml ([string]$_.Value))`" />"
  }) -join "`n"
}

function Install-ApplicationServices {
  foreach ($slot in @('blue', 'green')) {
    $current = Get-SlotCurrentPath $slot
    foreach ($service in @($script:DeploymentConfig.services)) {
      $id = Get-DeploymentServiceName $service $slot
      $entry = Join-Path $current $service.entry
      $environmentXml = Get-ServiceEnvironmentXml $service $slot $current
      $xml = @"
<service>
  <id>$(Escape-DeploymentXml $id)</id>
  <name>$(Escape-DeploymentXml "$($script:DeploymentConfig.appName) $($service.displayName) [$slot]")</name>
  <description>Blue/green $($service.type) service for $($script:DeploymentConfig.appName).</description>
  <executable>$(Escape-DeploymentXml $script:NodeExe)</executable>
  <arguments>--disable-warning=ExperimentalWarning &quot;$(Escape-DeploymentXml $entry)&quot;</arguments>
  <workingdirectory>$(Escape-DeploymentXml $current)</workingdirectory>
$environmentXml
  <startmode>Manual</startmode>
  <stoptimeout>$([int]$service.stopTimeoutSeconds) sec</stoptimeout>
  <stopparentprocessfirst>true</stopparentprocessfirst>
  <onfailure action="restart" delay="10 sec" />
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size-time">
    <sizeThreshold>10485760</sizeThreshold>
    <pattern>yyyyMMdd</pattern>
    <autoRollAtTime>00:00:00</autoRollAtTime>
    <zipOlderThanNumDays>7</zipOlderThanNumDays>
  </log>
  <logpath>$(Escape-DeploymentXml (Join-Path $script:LogsRoot "$slot-$($service.name)"))</logpath>
</service>
"@
      Install-WrappedDeploymentService $id $xml
    }
  }
}

function Install-InfrastructureServices {
  $caddyId = Get-CaddyServiceName
  $caddyXml = @"
<service>
  <id>$(Escape-DeploymentXml $caddyId)</id>
  <name>$(Escape-DeploymentXml "$($script:DeploymentConfig.appName) Caddy")</name>
  <description>Stable intranet HTTP entry point for $($script:DeploymentConfig.appName).</description>
  <executable>$(Escape-DeploymentXml $script:CaddyExe)</executable>
  <arguments>run --config &quot;$(Escape-DeploymentXml $script:Caddyfile)&quot; --adapter caddyfile</arguments>
  <workingdirectory>$(Escape-DeploymentXml $script:ServiceRoot)</workingdirectory>
  <startmode>Automatic</startmode>
  <stoptimeout>30 sec</stoptimeout>
  <onfailure action="restart" delay="5 sec" />
  <resetfailure>1 hour</resetfailure>
  <logpath>$(Escape-DeploymentXml (Join-Path $script:LogsRoot 'caddy-service'))</logpath>
</service>
"@
  Install-WrappedDeploymentService $caddyId $caddyXml

  if ($script:DeploymentConfig.memoryGuard.enabled) {
    $guardId = Get-MemoryGuardServiceName
    $guardScript = Join-Path $script:ServiceRoot 'memory-guard.ps1'
    $productionConfig = Join-Path $script:ServiceRoot 'deployment.config.json'
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $guardXml = @"
<service>
  <id>$(Escape-DeploymentXml $guardId)</id>
  <name>$(Escape-DeploymentXml "$($script:DeploymentConfig.appName) Memory Guard")</name>
  <description>Restarts services after sustained configured memory overages.</description>
  <executable>$(Escape-DeploymentXml $powershell)</executable>
  <arguments>-NoProfile -ExecutionPolicy Bypass -File &quot;$(Escape-DeploymentXml $guardScript)&quot; -ConfigPath &quot;$(Escape-DeploymentXml $productionConfig)&quot;</arguments>
  <workingdirectory>$(Escape-DeploymentXml $script:ServiceRoot)</workingdirectory>
  <startmode>Automatic</startmode>
  <stoptimeout>30 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec" />
  <resetfailure>1 hour</resetfailure>
  <logpath>$(Escape-DeploymentXml (Join-Path $script:LogsRoot 'memory-guard-service'))</logpath>
</service>
"@
    Install-WrappedDeploymentService $guardId $guardXml
  }
}

function Install-HostSettings {
  $firewallName = "$($script:DeploymentConfig.servicePrefix) Intranet HTTP"
  Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([int]$script:DeploymentConfig.listenPort) -RemoteAddress @($script:DeploymentConfig.firewallRemoteAddresses) -Profile Domain,Private | Out-Null

  if ($script:DeploymentConfig.power.disableAcSleep) { & powercfg.exe /change standby-timeout-ac 0 | Out-Null }
  if ($script:DeploymentConfig.power.disableAcHibernate) { & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null }
}

function Install-BackupTask {
  if (-not $script:DeploymentConfig.backup.enabled) { return }
  $productionConfig = Join-Path $script:ServiceRoot 'deployment.config.json'
  $backupScript = Join-Path $script:ServiceRoot 'backup.ps1'
  $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$productionConfig`""
  & schtasks.exe /Create /F /SC DAILY /ST ([string]$script:DeploymentConfig.backup.schedule) /TN (Get-BackupTaskName) /TR $taskCommand /RU SYSTEM | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create the scheduled backup task.' }
}

Install-DeploymentTools
foreach ($file in @('common.ps1', 'memory-guard.ps1', 'backup.ps1')) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $script:ServiceRoot $file) -Force
}
Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $script:ServiceRoot 'deployment.config.json') -Force
Install-ApplicationServices
Install-InfrastructureServices
Install-HostSettings

if (-not $SkipInitialDeploy) {
  & (Join-Path $PSScriptRoot 'deploy.ps1') -ConfigPath $ConfigPath -SourceRoot $SourceRoot -SkipTests:$SkipTests -AllowDirty:$AllowDirty
}

Install-BackupTask
if ($script:DeploymentConfig.memoryGuard.enabled) {
  $guardName = Get-MemoryGuardServiceName
  Set-Service -Name $guardName -StartupType Automatic
  if ((Get-Service -Name $guardName).Status -ne 'Running') { Start-Service -Name $guardName }
}

Write-Output "Installation completed for $($script:DeploymentConfig.appName)."
Write-Output "Production root: $script:ProductionRoot"
Write-Output "Stable URL: $(@($script:DeploymentConfig.publicOrigins)[0])"
