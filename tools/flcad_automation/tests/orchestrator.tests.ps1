$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$orchestrator = Join-Path (Split-Path -Parent $PSScriptRoot) 'orchestrator.ps1'
$worktree = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$sandbox = Join-Path $env:TEMP ('flcad-ab06-' + [guid]::NewGuid().ToString('N'))
$reportRelative = 'tools/flcad_automation/orchestrator-state/AB06A-TEST-1.json'
$reportAbsolute = Join-Path $worktree $reportRelative
$reportTwoAbsolute = Join-Path $worktree 'tools/flcad_automation/orchestrator-state/AB06A-TEST-2.json'
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

function Write-Json([string]$Path, [object]$Value) { $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Invoke-Orchestrator([string[]]$Arguments) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $script:LastOrchestratorOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $orchestrator @Arguments 2>&1)
  $ErrorActionPreference = $old
  return $LASTEXITCODE
}

try {
  $head = (git -C $worktree rev-parse HEAD).Trim()
  $taskPath = Join-Path $sandbox 'task.json'
  $queuePath = Join-Path $sandbox 'queue.json'
  $task = [ordered]@{
    schemaVersion='1.0'; id='AB06A-TEST-1'; objective='synthetic authorized environment probe'
    sourceBranch='automation/flcad-bridge'; baseCommit=$head; allowedPaths=@('tools/flcad_automation')
    requiredTests=@('synthetic'); acceptanceCriteria=@('report generated'); limits=@{maxDurationSeconds=30;maxOutputBytes=1048576}
    permissions=@{workspaceWrite=$false;network=$false;gitMutation=$false;remotePublish=$false}
    state='approved'; reportPath=$reportRelative; action='environment'
  }
  Write-Json $taskPath $task
  $code = Invoke-Orchestrator @('-Command','Add','-QueuePath',$queuePath,'-Task',$taskPath,'-Worktree',$worktree)
  Assert-True ($code -eq 0) 'authorized task should be queued'
  $code = Invoke-Orchestrator @('-Command','Add','-QueuePath',$queuePath,'-Task',$taskPath,'-Worktree',$worktree)
  Assert-True ($code -ne 0) 'replay task must be rejected'
  $taskTwoPath = Join-Path $sandbox 'task-two.json'
  $taskTwo = [ordered]@{}; foreach($entry in $task.GetEnumerator()) { $taskTwo[$entry.Key] = $entry.Value }
  $taskTwo.id='AB06A-TEST-2'; $taskTwo.reportPath='tools/flcad_automation/orchestrator-state/AB06A-TEST-2.json'; Write-Json $taskTwoPath $taskTwo
  $code = Invoke-Orchestrator @('-Command','Add','-QueuePath',$queuePath,'-Task',$taskTwoPath,'-Worktree',$worktree)
  Assert-True ($code -eq 0) 'second authorized task should be queued'
  $code = Invoke-Orchestrator @('-Command','Run','-QueuePath',$queuePath,'-Worktree',$worktree,'-TimeoutSeconds','30')
  Assert-True ($code -eq 0) "authorized task should execute: $($script:LastOrchestratorOutput -join ' | ')"
  $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
  Assert-True ($queue.tasks[0].state -eq 'ready_for_review') "completed task must stop for independent review: state=$($queue.tasks[0].state), classification=$($queue.tasks[0].classification), reason=$($queue.tasks[0].reason)"
  Assert-True ($queue.tasks[1].state -eq 'queued') 'second task must remain queued before review'
  Assert-True (Test-Path -LiteralPath $reportAbsolute) 'executor report must exist'
  $code = Invoke-Orchestrator @('-Command','Run','-QueuePath',$queuePath,'-Worktree',$worktree)
  Assert-True ($code -ne 0) 'second task must not run while review is absent'
  $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
  Assert-True ($queue.tasks[1].state -eq 'queued') 'safe stop must preserve second task'
  $reviewPath = Join-Path $sandbox 'review.json'
  $review = [ordered]@{
    schema_version='1.0'; task_id='AB06A-TEST-1'; analyzed_commit=$head
    report_sha256=$queue.tasks[0].report_sha256; decision='APPROVED'
    findings=@('synthetic authorized environment probe completed')
    criteria_verified=$true; reviewed_at=(Get-Date).ToUniversalTime().ToString('o')
    reviewer_identity='external-supervisor'; reviewer_execution_id='external-review-1'
  }
  Write-Json $reviewPath $review
  $code = Invoke-Orchestrator @('-Command','Review','-QueuePath',$queuePath,'-TaskId','AB06A-TEST-1','-Review',$reviewPath,'-Worktree',$worktree,'-ContinueAfterReview')
  Assert-True ($code -eq 0) "valid external review should be accepted: $($script:LastOrchestratorOutput -join ' | ')"
  $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
  Assert-True ($queue.tasks[0].state -eq 'completed') 'approved task must complete'
  Assert-True ($queue.tasks[1].state -eq 'ready_for_review') 'review approval should chain the next authorized task'
  Assert-True (Test-Path -LiteralPath $reportTwoAbsolute) 'chained task report must exist'
  $duplicateCode = Invoke-Orchestrator @('-Command','Review','-QueuePath',$queuePath,'-TaskId','AB06A-TEST-1','-Review',$reviewPath,'-Worktree',$worktree)
  Assert-True ($duplicateCode -ne 0) 'duplicate review must be rejected'
  $badReviewPath = Join-Path $sandbox 'bad-review.json'
  $badReview = [ordered]@{}; foreach($entry in $review.GetEnumerator()) { $badReview[$entry.Key] = $entry.Value }
  $badReview.task_id='AB06A-TEST-2'; $badReview.report_sha256=('0' * 64); $badReview.decision='UNKNOWN'; $badReview.criteria_verified=$false
  Write-Json $badReviewPath $badReview
  $code = Invoke-Orchestrator @('-Command','Review','-QueuePath',$queuePath,'-TaskId','AB06A-TEST-2','-Review',$badReviewPath,'-Worktree',$worktree)
  Assert-True ($code -ne 0) 'mismatched SHA and unknown decision must be rejected'
  $code = Invoke-Orchestrator @('-Command','Cancel','-QueuePath',$queuePath,'-TaskId','UNKNOWN','-Worktree',$worktree)
  Assert-True ($code -ne 0) 'unknown task must be rejected'
  $queue.tasks[0].state='running'; Write-Json $queuePath $queue
  $code = Invoke-Orchestrator @('-Command','Run','-QueuePath',$queuePath,'-Worktree',$worktree)
  Assert-True ($code -ne 0) 'concurrent run must be rejected'
  Write-Output 'orchestrator.tests.ps1: PASS'
} finally {
  if (Test-Path -LiteralPath $reportAbsolute) { Remove-Item -LiteralPath $reportAbsolute -Force }
  if (Test-Path -LiteralPath $reportTwoAbsolute) { Remove-Item -LiteralPath $reportTwoAbsolute -Force }
  $reportDir = Split-Path -Parent $reportAbsolute
  if (Test-Path -LiteralPath $reportDir) { Remove-Item -LiteralPath $reportDir -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
