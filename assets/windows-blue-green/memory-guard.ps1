[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'deployment.config.json'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1') -ConfigPath $ConfigPath
. (Join-Path $PSScriptRoot 'memory-guard-core.ps1')

if (-not $script:DeploymentConfig.memoryGuard.enabled) { exit 0 }
$pollSeconds = [int]$script:DeploymentConfig.memoryGuard.pollSeconds
$sustainedSeconds = [int]$script:DeploymentConfig.memoryGuard.sustainedSeconds
$overLimitSince = @{}
$eventLog = Join-Path $script:LogsRoot 'memory-guard.jsonl'
New-Item -ItemType Directory -Path $script:LogsRoot -Force | Out-Null

while ($true) {
  try {
    $slot = Get-ActiveDeploymentSlot
    if ($slot) {
      $processes = @(Get-CimInstance Win32_Process)
      foreach ($service in @($script:DeploymentConfig.services)) {
        $serviceName = Get-DeploymentServiceName $service $slot
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if (-not $serviceInfo -or [int]$serviceInfo.ProcessId -le 0) { $overLimitSince.Remove($serviceName) | Out-Null; continue }
        $bytes = Get-ProcessTreeMemoryBytes ([int]$serviceInfo.ProcessId) $processes
        $limit = [long]$service.memoryLimitMb * 1MB
        if ($bytes -gt $limit) {
          if (-not $overLimitSince.ContainsKey($serviceName)) { $overLimitSince[$serviceName] = Get-Date }
          $duration = ((Get-Date) - $overLimitSince[$serviceName]).TotalSeconds
          if ($duration -ge $sustainedSeconds) {
            $record = [ordered]@{ timestamp = (Get-Date).ToString('o'); service = $serviceName; slot = $slot; memoryBytes = $bytes; limitBytes = $limit; action = 'restart' } | ConvertTo-Json -Compress
            Add-Content -LiteralPath $eventLog -Value $record -Encoding utf8
            Restart-Service -Name $serviceName -Force
            $overLimitSince.Remove($serviceName) | Out-Null
          }
        } else {
          $overLimitSince.Remove($serviceName) | Out-Null
        }
      }
    }
  } catch {
    $record = [ordered]@{ timestamp = (Get-Date).ToString('o'); action = 'error'; message = $_.Exception.Message } | ConvertTo-Json -Compress
    Add-Content -LiteralPath $eventLog -Value $record -Encoding utf8
  }
  Start-Sleep -Seconds $pollSeconds
}
