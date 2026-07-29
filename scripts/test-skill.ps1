[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "deploy-windows-intranet-test-$([guid]::NewGuid().ToString('N'))"
$projectRoot = Join-Path $fixtureRoot 'project'
$deploymentRoot = Join-Path $projectRoot 'deploy\windows'
$productionRoot = Join-Path $fixtureRoot 'production'
$environmentName = 'DEPLOY_WINDOWS_INTRANET_TEST_VALUE'

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Write-TestFile([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

try {
  New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
  Write-TestFile (Join-Path $projectRoot 'package.json') '{"name":"skill-fixture","version":"1.0.0","scripts":{"test":"node --test","build":"node scripts/build.js"}}'
  Write-TestFile (Join-Path $projectRoot 'package-lock.json') '{"name":"skill-fixture","version":"1.0.0","lockfileVersion":3,"packages":{}}'
  Write-TestFile (Join-Path $projectRoot 'server\api.js') "process.on('SIGTERM', () => process.exit(0))`n"
  Write-TestFile (Join-Path $projectRoot 'server\worker.js') "process.on('SIGTERM', () => process.exit(0))`n"
  Write-TestFile (Join-Path $projectRoot 'shared\placeholder.txt') 'fixture'
  Write-TestFile (Join-Path $projectRoot 'dist\index.html') '<!doctype html><title>Fixture</title>'
  Write-TestFile (Join-Path $projectRoot 'scripts\build.js') "process.stdout.write('fixture build')`n"

  & (Join-Path $skillRoot 'scripts\scaffold-project.ps1') -ProjectRoot $projectRoot -AppName 'Skill Fixture' | Out-Null
  $configPath = Join-Path $deploymentRoot 'deployment.config.json'
  $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
  $config.productionRoot = $productionRoot
  $config.publicOrigins = @('http://127.0.0.1:19080')
  $config.listenPort = 19080
  $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8
  & (Join-Path $skillRoot 'scripts\validate-project.ps1') -ProjectRoot $projectRoot | Out-Null

  $parseErrors = [Collections.Generic.List[object]]::new()
  foreach ($scriptFile in Get-ChildItem -Recurse -Filter '*.ps1' -LiteralPath $skillRoot) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($error in @($errors)) { $parseErrors.Add($error) }
  }
  Assert-Equal 0 $parseErrors.Count 'PowerShell source contains parse errors.'

  [Environment]::SetEnvironmentVariable($environmentName, 'resolved-value', 'Process')
  . (Join-Path $deploymentRoot 'common.ps1') -ConfigPath $configPath
  $reference = "%$environmentName%"
  Assert-Equal $reference (Expand-DeploymentValue $reference $null 'blue' 'C:\release') 'Service environment references must remain unexpanded.'
  Assert-Equal 'resolved-value' (Resolve-DeploymentProcessValue $reference $null 'blue' 'C:\release') 'Process-time environment resolution failed.'

  . (Join-Path $deploymentRoot 'memory-guard-core.ps1')
  $processes = @(
    [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; WorkingSetSize = 100 },
    [pscustomobject]@{ ProcessId = 11; ParentProcessId = 10; WorkingSetSize = 200 },
    [pscustomobject]@{ ProcessId = 12; ParentProcessId = 1; WorkingSetSize = 400 }
  )
  Assert-Equal 300 (Get-ProcessTreeMemoryBytes 10 $processes) 'Memory Guard process-tree sum is incorrect.'

  . (Join-Path $deploymentRoot 'preflight-core.ps1')
  Assert-True (Test-ListenerProcessOwnership @(11) 10 $processes) 'Expected listener ownership was rejected.'
  Assert-True (-not (Test-ListenerProcessOwnership @(12) 10 $processes)) 'Unrelated listener ownership was accepted.'

  . (Join-Path $deploymentRoot 'install-core.ps1')
  $obsolete = @(Get-ObsoleteManagedServiceIds @('AppApiBlue', 'AppOldWorkerBlue') @('AppApiBlue'))
  Assert-Equal 1 $obsolete.Count 'Obsolete-service calculation returned the wrong count.'
  Assert-Equal 'AppOldWorkerBlue' $obsolete[0] 'Obsolete-service calculation returned the wrong service.'

  Initialize-DeploymentDirectories
  $releaseOne = Join-Path $script:ReleasesRoot 'release-one'
  $releaseTwo = Join-Path $script:ReleasesRoot 'release-two'
  New-Item -ItemType Directory -Path $releaseOne, $releaseTwo -Force | Out-Null
  Set-SlotRelease 'blue' $releaseOne
  Assert-Equal $releaseOne (Get-SlotRelease 'blue') 'Initial slot junction is incorrect.'
  Set-SlotRelease 'blue' $releaseTwo
  Assert-Equal $releaseTwo (Get-SlotRelease 'blue') 'Slot junction swap is incorrect.'
  Restore-SlotRelease 'blue' $releaseOne
  Assert-Equal $releaseOne (Get-SlotRelease 'blue') 'Slot junction restoration is incorrect.'
  Clear-SlotRelease 'blue'
  Assert-True (-not (Get-SlotRelease 'blue')) 'Slot junction was not cleared.'

  Set-PostCutoverWarning 'deploy' 'green' 'fixture warning'
  $warningPath = Join-Path $script:StateRoot 'post-cutover-warning.json'
  Assert-True (Test-Path -LiteralPath $warningPath) 'Post-cutover warning was not persisted.'
  $warning = Get-Content -Raw -LiteralPath $warningPath | ConvertFrom-Json
  Assert-Equal 'green' $warning.slot 'Post-cutover warning recorded the wrong slot.'
  Clear-PostCutoverWarning
  Assert-True (-not (Test-Path -LiteralPath $warningPath)) 'Post-cutover warning was not cleared.'

  Set-ActiveDeploymentState 'green' $releaseTwo
  Assert-Equal 'green' (Get-ActiveDeploymentSlot) 'Active deployment state was not written.'
  Clear-ActiveDeploymentState
  Assert-True (-not (Get-ActiveDeploymentSlot)) 'Active deployment state was not cleared.'

  $collisionConfigPath = Join-Path $deploymentRoot 'deployment.config.collision.json'
  $collisionConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
  $firstApi = $collisionConfig.services[0]
  $secondApi = ($firstApi | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
  $firstApi.name = 'api-a'
  $secondApi.name = 'apia'
  $secondApi.bluePort = 18101
  $secondApi.greenPort = 28101
  $collisionConfig.services = @($firstApi, $secondApi, $collisionConfig.services[1])
  $collisionConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $collisionConfigPath -Encoding utf8
  $collisionRejected = $false
  try {
    & (Join-Path $deploymentRoot 'validate-config.ps1') -ConfigPath $collisionConfigPath -ProjectRoot $projectRoot 2>$null | Out-Null
  } catch {
    $collisionRejected = $true
  }
  Assert-True $collisionRejected 'Normalized Windows service ID collision was not rejected.'

  Write-Output 'All deploy-windows-intranet regression tests passed.'
} finally {
  [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
  if (Test-Path -LiteralPath $fixtureRoot) { [IO.Directory]::Delete($fixtureRoot, $true) }
}
