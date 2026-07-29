Set-StrictMode -Version Latest

function Get-ObsoleteManagedServiceIds([string[]]$PreviousIds, [string[]]$ExpectedIds) {
  $expected = @{}
  foreach ($id in @($ExpectedIds)) { $expected[$id.ToLowerInvariant()] = $true }
  return @($PreviousIds | Where-Object { -not $expected.ContainsKey($_.ToLowerInvariant()) } | Sort-Object -Unique)
}
