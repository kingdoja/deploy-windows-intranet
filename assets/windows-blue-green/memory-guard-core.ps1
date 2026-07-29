Set-StrictMode -Version Latest

function Get-ProcessTreeMemoryBytes([int]$RootProcessId, $Processes) {
  $processById = @{}
  $childrenByParent = @{}
  foreach ($process in @($Processes)) {
    $processId = [int]$process.ProcessId
    $parentProcessId = [int]$process.ParentProcessId
    $processById[$processId] = $process
    if (-not $childrenByParent.ContainsKey($parentProcessId)) {
      $childrenByParent[$parentProcessId] = [Collections.Generic.List[int]]::new()
    }
    $childrenByParent[$parentProcessId].Add($processId)
  }

  $queue = [Collections.Generic.Queue[int]]::new()
  $queue.Enqueue($RootProcessId)
  $seen = @{}
  [long]$total = 0
  while ($queue.Count) {
    $processId = $queue.Dequeue()
    if ($seen.ContainsKey($processId)) { continue }
    $seen[$processId] = $true
    if ($processById.ContainsKey($processId)) {
      $total += [long]$processById[$processId].WorkingSetSize
    }
    if ($childrenByParent.ContainsKey($processId)) {
      foreach ($childProcessId in $childrenByParent[$processId]) { $queue.Enqueue($childProcessId) }
    }
  }
  return $total
}
