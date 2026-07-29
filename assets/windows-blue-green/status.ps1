[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath

$activeSlot = Get-ActiveDeploymentSlot
$result = [ordered]@{
  appName = $script:DeploymentConfig.appName
  productionRoot = $script:ProductionRoot
  activeSlot = $activeSlot
  activeRelease = if ($activeSlot) { Get-SlotRelease $activeSlot } else { $null }
  stableUrl = @($script:DeploymentConfig.publicOrigins)[0]
  slots = [ordered]@{}
  services = [ordered]@{}
  backupTask = $null
  latestMemoryEvent = $null
}

foreach ($slot in @('blue', 'green')) {
  $slotState = [ordered]@{ release = Get-SlotRelease $slot; health = [ordered]@{} }
  foreach ($service in @($script:DeploymentConfig.services | Where-Object { $_.type -eq 'api' })) {
    $port = Get-DeploymentPort $service $slot
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port$($service.healthPath)" -TimeoutSec 3
      $slotState.health[$service.name] = [ordered]@{ status = $response.StatusCode; body = $response.Content }
    } catch {
      $slotState.health[$service.name] = [ordered]@{ error = $_.Exception.Message }
    }
  }
  $result.slots[$slot] = $slotState
}

$servicePattern = "$($script:DeploymentConfig.servicePrefix)*"
foreach ($service in Get-Service -Name $servicePattern -ErrorAction SilentlyContinue | Sort-Object Name) {
  $result.services[$service.Name] = [string]$service.Status
}

$task = Get-ScheduledTask -TaskName (Get-BackupTaskName) -ErrorAction SilentlyContinue
if ($task) {
  $info = Get-ScheduledTaskInfo -TaskName $task.TaskName
  $result.backupTask = [ordered]@{ state = [string]$task.State; lastRunTime = $info.LastRunTime; lastTaskResult = $info.LastTaskResult; nextRunTime = $info.NextRunTime }
}
$memoryLog = Join-Path $script:LogsRoot 'memory-guard.jsonl'
if (Test-Path -LiteralPath $memoryLog) { $result.latestMemoryEvent = Get-Content -LiteralPath $memoryLog -Tail 1 }

$result | ConvertTo-Json -Depth 10

