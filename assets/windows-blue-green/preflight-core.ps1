Set-StrictMode -Version Latest

function Test-ListenerProcessOwnership([int[]]$ListenerProcessIds, [int]$ServiceProcessId, $Processes) {
  if ($ServiceProcessId -le 0 -or -not $ListenerProcessIds.Count) { return $false }
  $parentByProcess = @{}
  foreach ($process in @($Processes)) {
    $parentByProcess[[int]$process.ProcessId] = [int]$process.ParentProcessId
  }

  foreach ($listenerProcessId in $ListenerProcessIds) {
    $currentProcessId = $listenerProcessId
    $seen = @{}
    $owned = $false
    while ($currentProcessId -gt 0 -and -not $seen.ContainsKey($currentProcessId)) {
      if ($currentProcessId -eq $ServiceProcessId) { $owned = $true; break }
      $seen[$currentProcessId] = $true
      if (-not $parentByProcess.ContainsKey($currentProcessId)) { break }
      $currentProcessId = $parentByProcess[$currentProcessId]
    }
    if (-not $owned) { return $false }
  }
  return $true
}
