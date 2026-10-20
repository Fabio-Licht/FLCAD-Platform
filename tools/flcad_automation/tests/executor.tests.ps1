$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$executor = Join-Path $root 'executor.ps1'
$demo = Join-Path $root 'demo-task.json'
$codexTask = Join-Path $root 'codex-probe-task.json'
$worktree = (Resolve-Path (Join-Path $root '..\..')).Path

function Assert-True([bool] $Condition, [string] $Message) { if (!$Condition) { throw "ASSERTION FAILED: $Message" } }

& powershell -NoProfile -File $executor -Task $demo -Worktree $worktree -ValidateOnly | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'tarefa válida deve passar na validação'

$invalid = Join-Path $env:TEMP 'flcad-invalid-task.json'
'{"schemaVersion":"1.0","id":"bad","action":"shell","state":"approved"}' | Set-Content -LiteralPath $invalid -Encoding UTF8
$oldPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& powershell -NoProfile -File $executor -Task $invalid -Worktree $worktree -ValidateOnly 2>&1 | Out-Null
$invalidExit = $LASTEXITCODE; $ErrorActionPreference = $oldPreference
Assert-True ($invalidExit -ne 0) 'invalid task must be rejected'
Remove-Item -LiteralPath $invalid -Force

$traversal = Join-Path $env:TEMP 'flcad-traversal-task.json'
@{
  schemaVersion = '1.0'; id = 'AB-01-TRAVERSAL'; objective = 'traversal test';
  sourceBranch = 'automation/flcad-bridge'; baseCommit = '81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54';
  allowedPaths = @('../outside'); requiredTests = @('traversal'); acceptanceCriteria = @('reject');
  limits = @{ maxDurationSeconds = 1; maxOutputBytes = 1048576 };
  permissions = @{ workspaceWrite = $false; network = $false; gitMutation = $false; remotePublish = $false };
  state = 'approved'; reportPath = 'tools/flcad_automation/reports/AB-01-TRAVERSAL.json'; action = 'environment'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $traversal -Encoding UTF8
$oldPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& powershell -NoProfile -File $executor -Task $traversal -Worktree $worktree -ValidateOnly 2>&1 | Out-Null
$traversalExit = $LASTEXITCODE; $ErrorActionPreference = $oldPreference
Assert-True ($traversalExit -ne 0) 'path traversal must be rejected'
Remove-Item -LiteralPath $traversal -Force

$lock = Join-Path $worktree '.flcad_automation.lock'
$stream = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
  $oldPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & powershell -NoProfile -File $executor -Task $demo -Worktree $worktree -ValidateOnly 2>&1 | Out-Null
  $concurrentExit = $LASTEXITCODE; $ErrorActionPreference = $oldPreference
  Assert-True ($concurrentExit -ne 0) 'concurrent execution must be rejected'
} finally { $stream.Dispose(); Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }

& powershell -NoProfile -File $executor -Task $demo -Worktree $worktree | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'dry-run deve concluir'
$report = Join-Path $worktree 'tools\flcad_automation\reports\AB-01-DRYRUN-ENV.json'
Assert-True (Test-Path $report) 'relatório do dry-run deve existir'
$parsed = Get-Content $report -Raw | ConvertFrom-Json
Assert-True ($parsed.status -eq 'completed') 'relatório deve indicar completed'
Assert-True ($parsed.head -eq '81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54') 'HEAD reportado incorreto'

$timeoutTask = Join-Path $env:TEMP 'flcad-timeout-task.json'
$timeoutReport = Join-Path $worktree 'tools\flcad_automation\reports\AB-01-TIMEOUT-TEST.json'
@{
  schemaVersion = '1.0'; id = 'AB-01-TIMEOUT'; objective = 'timeout test';
  sourceBranch = 'automation/flcad-bridge'; baseCommit = '81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54';
  allowedPaths = @('tools/flcad_automation'); requiredTests = @('timeout'); acceptanceCriteria = @('timeout');
  limits = @{ maxDurationSeconds = 1; maxOutputBytes = 1048576 };
  permissions = @{ workspaceWrite = $false; network = $false; gitMutation = $false; remotePublish = $false };
  state = 'approved'; reportPath = 'tools/flcad_automation/reports/AB-01-TIMEOUT-TEST.json'; action = 'codex-environment-probe'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $timeoutTask -Encoding UTF8
$oldPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& powershell -NoProfile -File $executor -Task $timeoutTask -Worktree $worktree 2>&1 | Out-Null
$timeoutExit = $LASTEXITCODE; $ErrorActionPreference = $oldPreference
Assert-True ($timeoutExit -eq 124) 'timeout deve terminar com código 124'
Remove-Item -LiteralPath $timeoutTask,$timeoutReport,(Join-Path $worktree 'tools\flcad_automation\reports\AB-01-TIMEOUT-TEST.log') -Force -ErrorAction SilentlyContinue

$cancelProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
$cancelLock = Join-Path $worktree '.flcad_automation.lock'
@{ pid = $cancelProcess.Id; taskId = 'AB-01-CANCEL'; startedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $cancelLock -Encoding UTF8
& powershell -NoProfile -File $executor -Task $demo -Worktree $worktree -Cancel 2>&1 | Out-Null
Start-Sleep -Milliseconds 250
$cancelProcess.Refresh()
Assert-True $cancelProcess.HasExited 'cancelamento deve terminar o processo registrado'
Remove-Item -LiteralPath $cancelLock -Force -ErrorAction SilentlyContinue

Write-Output 'executor.tests.ps1: PASS'
