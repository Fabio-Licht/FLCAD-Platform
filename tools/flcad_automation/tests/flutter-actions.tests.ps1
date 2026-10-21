$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executor = Join-Path $root 'executor.ps1'
$snapshotScript = Join-Path $root 'flutter-snapshot.ps1'
$bridge = Split-Path -Parent (Split-Path -Parent $root)
$functional = 'C:\flcad_mobile'
$head = (git -C $functional rev-parse HEAD).Trim()
$branch = (git -C $functional branch --show-current).Trim()
$sandbox = Join-Path $env:TEMP ('flcad-ab06d-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$snapshotRoot=Join-Path $sandbox 'snapshot'
$manifest=Join-Path $snapshotRoot 'snapshot-manifest.json'
function Write-Json([string]$Path,[object]$Value){$Value|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $Path -Encoding UTF8}
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $snapshotScript -Command Create -SnapshotRoot $snapshotRoot | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'snapshot must be created'
function New-Task([string]$Id,[string]$Action,[string]$TestName){
  return [ordered]@{schemaVersion='1.0';id=$Id;objective="AB-06D $TestName";sourceBranch=$branch;baseCommit=$head;allowedPaths=@('test');requiredTests=@($TestName);acceptanceCriteria=@('fixed test completed');limits=@{maxDurationSeconds=600;maxOutputBytes=1048576};permissions=@{workspaceWrite=$false;network=$false;gitMutation=$false;remotePublish=$false};state='approved';reportPath="tools/flcad_automation/ab06d-reports/$Id.json";action=$Action}
}
try {
  Assert-True ($branch -eq 'feat/plane-axis-intersection-point') 'functional branch must be authorized'
  Assert-True ($head -eq '81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54') 'functional HEAD must be authorized'
  foreach($entry in @(@{id='AB06D-SEL';action='flutter-selection-latency';name='selection diagnostics'},@{id='AB06D-GEO';action='flutter-real-seed-matrix';name='real seed matrix'})) {
    $taskPath=Join-Path $sandbox ($entry.id+'.json'); Write-Json $taskPath (New-Task $entry.id $entry.action $entry.name)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $executor -Task $taskPath -Worktree $snapshotRoot -SnapshotManifest $manifest -ReportRoot $bridge -ValidateOnly | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "$($entry.action) must validate in a verified snapshot"
  }
  $badPath=Join-Path $sandbox 'bad.json'; $bad=New-Task 'AB06D-BAD' 'flutter-selection-latency' 'bad path'; $bad | Add-Member -NotePropertyName testPath -NotePropertyValue 'test/arbitrary.dart'; Write-Json $badPath $bad
  $old=$ErrorActionPreference; $ErrorActionPreference='Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $executor -Task $badPath -Worktree $functional -ReportRoot $bridge -ValidateOnly 2>&1 | Out-Null; $badExit=$LASTEXITCODE; $ErrorActionPreference=$old
  Assert-True ($badExit -ne 0) 'arbitrary test path must be rejected'
  $wrongPath=Join-Path $sandbox 'wrong.json'; $wrong=New-Task 'AB06D-WRONG' 'flutter-selection-latency' 'wrong worktree'; Write-Json $wrongPath $wrong
  $old=$ErrorActionPreference; $ErrorActionPreference='Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $executor -Task $wrongPath -Worktree $bridge -ReportRoot $bridge -ValidateOnly 2>&1 | Out-Null; $wrongExit=$LASTEXITCODE; $ErrorActionPreference=$old
  Assert-True ($wrongExit -ne 0) 'bridge worktree must be rejected for Flutter actions'
  Write-Output 'flutter-actions.tests.ps1: PASS'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
