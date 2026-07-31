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
function Assert-ConfigRejected($Config, [string]$Path, [string]$Validator, [string]$Root, [string]$Message) {
  $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
  $rejected = $false
  try {
    & $Validator -ConfigPath $Path -ProjectRoot $Root 2>$null | Out-Null
  } catch {
    $rejected = $true
  }
  Assert-True $rejected $Message
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
  $config.schemaVersion = 1
  foreach ($api in @($config.services | Where-Object { $_.type -eq 'api' })) {
    $api.PSObject.Properties.Remove('bindAddressEnvironment')
  }
  $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8
  Write-TestFile (Join-Path $deploymentRoot 'common.ps1') '# simulated customized schema v1 runtime'

  $git = Get-Command git.exe -ErrorAction Stop
  & $git.Source -C $projectRoot init --quiet
  & $git.Source -C $projectRoot config user.email 'skill-test@example.invalid'
  & $git.Source -C $projectRoot config user.name 'Skill Test'
  & $git.Source -C $projectRoot add --all
  & $git.Source -C $projectRoot commit --quiet -m 'schema v1 fixture'
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create the schema v1 Git fixture.' }

  $migrationScript = Join-Path $skillRoot 'scripts\migrate-schema-v1-to-v2.ps1'
  & $migrationScript -ProjectRoot $projectRoot | Out-Null
  $dryRunConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
  Assert-Equal 1 $dryRunConfig.schemaVersion 'Migration dry run changed the project.'
  Assert-Equal '# simulated customized schema v1 runtime' (Get-Content -Raw -LiteralPath (Join-Path $deploymentRoot 'common.ps1')) 'Migration dry run changed a runtime script.'

  $migrationBackup = Join-Path $fixtureRoot 'schema-v1-backup.zip'
  & $migrationScript -ProjectRoot $projectRoot -Apply -BackupPath $migrationBackup | Out-Null
  $migratedConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
  Assert-Equal 2 $migratedConfig.schemaVersion 'Schema v1 configuration was not migrated.'
  Assert-Equal 'HOST' $migratedConfig.services[0].bindAddressEnvironment 'API bind-address environment was not added.'
  Assert-True (Test-Path -LiteralPath $migrationBackup) 'Migration backup was not created.'
  Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $deploymentRoot 'common.ps1')) -match 'Enter-DeploymentOperationLock') 'Schema v2 runtime scripts were not synchronized.'
  $restoredBackup = Join-Path $fixtureRoot 'restored-schema-v1-backup'
  Expand-Archive -LiteralPath $migrationBackup -DestinationPath $restoredBackup
  $restoredConfigs = @(Get-ChildItem -LiteralPath $restoredBackup -Recurse -Filter 'deployment.config.json' -File)
  Assert-Equal 1 $restoredConfigs.Count 'Migration backup does not contain exactly one deployment configuration.'
  $restoredConfig = Get-Content -Raw -LiteralPath $restoredConfigs[0].FullName | ConvertFrom-Json
  Assert-Equal 1 $restoredConfig.schemaVersion 'Migration backup did not preserve the schema v1 configuration.'

  $config = $migratedConfig
  $config.productionRoot = 'C:\ProgramData\SkillFixture'
  $config.publicOrigins = @('http://127.0.0.1:19080')
  $config.listenPort = 19080
  $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8
  & (Join-Path $skillRoot 'scripts\validate-project.ps1') -ProjectRoot $projectRoot | Out-Null
  $validatedConfigJson = $config | ConvertTo-Json -Depth 20
  $config.productionRoot = $productionRoot
  $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8

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
  Assert-True (Test-DeploymentLoopbackListeners @([pscustomobject]@{ LocalAddress = '127.0.0.1' }, [pscustomobject]@{ LocalAddress = '::1' })) 'Loopback-only listeners were rejected.'
  Assert-True (-not (Test-DeploymentLoopbackListeners @([pscustomobject]@{ LocalAddress = '0.0.0.0' }))) 'Wildcard listener was accepted.'

  $outerLock = Enter-DeploymentOperationLock
  try {
    $innerLock = Enter-DeploymentOperationLock
    Exit-DeploymentOperationLock $innerLock
    $probePath = Join-Path $fixtureRoot 'lock-probe.ps1'
    Write-TestFile $probePath @'
param([string]$CommonPath, [string]$ConfigPath)
. $CommonPath -ConfigPath $ConfigPath
$probeLock = $null
try {
  $probeLock = Enter-DeploymentOperationLock -TimeoutSeconds 1
} catch {
  exit 0
}
if ($probeLock) { Exit-DeploymentOperationLock $probeLock }
exit 2
'@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probePath (Join-Path $deploymentRoot 'common.ps1') $configPath
    Assert-Equal 0 $LASTEXITCODE 'A concurrent deployment process acquired the operation lock.'
  } finally {
    Exit-DeploymentOperationLock $outerLock
  }

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
  Write-TestFile (Join-Path $releaseOne 'dist\index.html') '<!doctype html><title>Release one</title>'
  Write-TestFile (Join-Path $releaseTwo 'dist\index.html') '<!doctype html><title>Release two</title>'
  Set-SlotRelease 'blue' $releaseOne
  Assert-Equal $releaseOne (Get-SlotRelease 'blue') 'Initial slot junction is incorrect.'
  Write-DeploymentCaddyfile 'blue'
  $caddyfileOne = Get-Content -Raw -LiteralPath $script:Caddyfile
  Assert-True $caddyfileOne.Contains((Join-Path $releaseOne 'dist').Replace('\', '/')) 'Caddy did not point static traffic at the active immutable release.'
  Set-SlotRelease 'blue' $releaseTwo
  Assert-Equal $releaseTwo (Get-SlotRelease 'blue') 'Slot junction swap is incorrect.'
  Write-DeploymentCaddyfile 'blue'
  $caddyfileTwo = Get-Content -Raw -LiteralPath $script:Caddyfile
  Assert-True $caddyfileTwo.Contains((Join-Path $releaseTwo 'dist').Replace('\', '/')) 'Caddy static root did not switch with the slot.'
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
  $collisionConfig = $validatedConfigJson | ConvertFrom-Json
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

  $validator = Join-Path $deploymentRoot 'validate-config.ps1'
  $unsafeOrigin = $validatedConfigJson | ConvertFrom-Json
  $unsafeOrigin.publicOrigins = @('http://127.0.0.1:19080/path')
  Assert-ConfigRejected $unsafeOrigin (Join-Path $deploymentRoot 'deployment.config.bad-origin.json') $validator $projectRoot 'Public origin with a path was accepted.'

  $broadFirewall = $validatedConfigJson | ConvertFrom-Json
  $broadFirewall.firewallRemoteAddresses = @('0.0.0.0/0')
  Assert-ConfigRejected $broadFirewall (Join-Path $deploymentRoot 'deployment.config.broad-firewall.json') $validator $projectRoot 'Global firewall range was accepted.'

  $missingBind = $validatedConfigJson | ConvertFrom-Json
  $missingBind.services[0].PSObject.Properties.Remove('bindAddressEnvironment')
  Assert-ConfigRejected $missingBind (Join-Path $deploymentRoot 'deployment.config.missing-bind.json') $validator $projectRoot 'API without bindAddressEnvironment was accepted.'

  $profileRoot = $validatedConfigJson | ConvertFrom-Json
  $profileRoot.productionRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) 'UnsafeProductionRoot'
  Assert-ConfigRejected $profileRoot (Join-Path $deploymentRoot 'deployment.config.profile-root.json') $validator $projectRoot 'Production root inside a user profile was accepted.'

  $installSource = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'assets\windows-blue-green\install.ps1')
  Assert-True ($installSource.LastIndexOf('Install-HostSettings') -gt $installSource.LastIndexOf('deploy.ps1')) 'Host settings are applied before a successful deployment.'
  $deploySource = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'assets\windows-blue-green\deploy.ps1')
  $rollbackSource = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'assets\windows-blue-green\rollback.ps1')
  Assert-True ($deploySource -notmatch 'Publish-DeploymentWeb' -and $rollbackSource -notmatch 'Publish-DeploymentWeb') 'Frontend publishing is still separate from the Caddy cutover.'

  Write-Output 'All deploy-windows-intranet regression tests passed.'
} finally {
  [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
  if (Test-Path -LiteralPath $fixtureRoot) {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedFixture) -notmatch '^deploy-windows-intranet-test-[a-f0-9]{32}$') {
      throw "Refusing to remove unexpected test fixture path: $resolvedFixture"
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $resolvedFixture) { Write-Warning "Test fixture cleanup was incomplete: $resolvedFixture" }
  }
}
