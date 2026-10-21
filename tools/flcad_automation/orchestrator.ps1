[CmdletBinding()]
param(
  [ValidateSet('Add','Run','Status','Cancel','Recover','Review','Watch','Pause','Resume','Stop')]
  [string] $Command = 'Status',
  [string] $QueuePath = 'tools/flcad_automation/orchestrator-queue.json',
  [string] $Task,
  [string] $TaskId,
  [string] $Review,
  [string] $Worktree = (Get-Location).Path,
  [int] $TimeoutSeconds = 3600,
  [int] $MaxAttempts = 1,
  [int] $IntervalSeconds = 5,
  [switch] $ContinueAfterReview
)

$ErrorActionPreference = 'Stop'
$script:Version = '0.1.0'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:OrchestratorPath = $MyInvocation.MyCommand.Path

function Fail([string] $Message) { throw "FLCAD orchestrator rejected: $Message" }
function Read-Json([string] $Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "arquivo não encontrado: $Path" }
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
  catch { Fail "JSON inválido: $Path" }
}
function Write-Json([string] $Path, [object] $Value) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Get-Queue {
  if (!(Test-Path -LiteralPath $QueuePath -PathType Leaf)) {
    return [pscustomobject]@{ schema_version = '1.0'; tasks = @() }
  }
  return Read-Json $QueuePath
}
function Save-Queue([object] $Queue) { Write-Json $QueuePath $Queue }
function Get-TaskRecord([object] $Queue, [string] $Id) {
  return ($Queue.tasks | Where-Object { $_.task_id -eq $Id } | Select-Object -First 1)
}
function Assert-TaskId([string] $Id) {
  if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail "task_id inválido" }
}
function Quote-Arg([string] $Value) { return '"' + ($Value -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1') + '"' }
function Invoke-Process([string] $FileName, [string[]] $Arguments, [string] $Root, [int] $Timeout) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FileName; $psi.WorkingDirectory = $Root; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.Arguments = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
  $p = [Diagnostics.Process]::new(); $p.StartInfo = $psi
  [void]$p.Start(); $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
  if (!$p.WaitForExit($Timeout * 1000)) {
    try { $p.Kill() } catch {}
    return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; Output = "$($stdout.Result)`n$($stderr.Result)" }
  }
  return [pscustomobject]@{ ExitCode = $p.ExitCode; TimedOut = $false; Output = "$($stdout.Result)`n$($stderr.Result)" }
}
function Get-ReportHash([string] $Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-ExecutionWorktree([object] $TaskObject, [string] $BridgeWorktree) {
  if ($TaskObject.action -in @('flutter-selection-latency','flutter-real-seed-matrix')) { return 'C:\flcad_mobile' }
  return $BridgeWorktree
}
function New-FlutterSnapshot([object] $TaskObject) {
  $runtimeBase=Split-Path -Parent (Split-Path -Parent $QueuePath);$snapshotBase=Join-Path $runtimeBase 'snapshots';New-Item -ItemType Directory -Force -Path $snapshotBase|Out-Null
  $snapshotRoot=Join-Path $snapshotBase ("flcad-watch-snapshot-$($TaskObject.id)-"+[guid]::NewGuid().ToString('N'))
  $script=Join-Path $scriptDir 'flutter-snapshot.ps1';$powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
  $created=Invoke-Process $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Command','Create','-SnapshotRoot',$snapshotRoot,'-ExpectedBranch',$TaskObject.sourceBranch,'-ExpectedCommit',$TaskObject.baseCommit) $Worktree $TimeoutSeconds
  $manifest=Join-Path $snapshotRoot 'snapshot-manifest.json'
  if($created.ExitCode -ne 0 -or !(Test-Path -LiteralPath $manifest -PathType Leaf)){Fail "snapshot creation failed: $($created.Output)"}
  $verified=Invoke-Process $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Command','Verify','-ManifestPath',$manifest) $Worktree 120
  if($verified.ExitCode -ne 0){Fail "snapshot verification failed: $($verified.Output)"}
  return [pscustomobject]@{Root=$snapshotRoot;Manifest=$manifest}
}
function Get-ControlPath([string] $Name) { return Join-Path (Split-Path -Parent $QueuePath) $Name }
function Write-Control([string] $Name, [string] $Reason) {
  $path=Get-ControlPath $Name; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [ordered]@{requested_at=(Get-Date).ToUniversalTime().ToString('o');reason=$Reason} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}
function Write-Heartbeat([string] $State, [string] $Message='') {
  $path=Get-ControlPath 'watch-heartbeat.json'
  [ordered]@{schema_version='1.0';pid=$PID;state=$State;message=$Message;updated_at=(Get-Date).ToUniversalTime().ToString('o');queue_path=$QueuePath} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}
function Test-TaskExecutionLock([object] $TaskObject) {
  $executionRoot=Get-ExecutionWorktree $TaskObject $Worktree
  return Test-Path -LiteralPath (Join-Path $executionRoot '.flcad_automation.lock') -PathType Leaf
}
function Recover-StaleRunning([object] $Queue) {
  foreach($record in @($Queue.tasks | Where-Object {$_.state -eq 'running'})) {
    $taskObject=Read-Json $record.task_path
    if (-not (Test-TaskExecutionLock $taskObject)) { $record.state='queued';$record.reason='recovered after interrupted watch/executor' }
  }
  Save-Queue $Queue
}
function New-ClassificationInput([object] $TaskObject, [int] $ExitCode, [bool] $TimedOut, [bool] $ReportPresent, [string] $Reason) {
  return [ordered]@{
    schema_version='1.0'; task_id=$TaskObject.id
    execution_status=if($TimedOut){'timed-out'}elseif($ExitCode -eq 0 -and $ReportPresent){'completed'}else{'failed'}
    criteria_verified=($ExitCode -eq 0 -and $ReportPresent)
    review_required=$true; professional_test_required=$false; approval_required=$false
    critical_decision_required=$false; blocked=(!$ReportPresent -or $ExitCode -ne 0)
    dependency_unavailable=$false; gui_authorization_required=$false; security_failure=$false
    action_requested='Independent technical review of the report'
    reason=$Reason
  }
}
function Invoke-One([object] $Queue, [object] $Record) {
  foreach ($name in @('started_at','finished_at','report_path','report_sha256','result_path','classification_path','executor_exit_code','classification','event','reason','review','review_path')) {
    if ($null -eq $Record.PSObject.Properties[$name]) { $Record | Add-Member -NotePropertyName $name -NotePropertyValue $null }
  }
  $taskObject = Read-Json $Record.task_path
  $executionWorktree = Get-ExecutionWorktree $taskObject $Worktree
  $snapshot = $null
  $reportRootForRun = $Worktree
  if ($taskObject.action -in @('flutter-selection-latency','flutter-real-seed-matrix')) {
    try { $snapshot=New-FlutterSnapshot $taskObject;$executionWorktree=$snapshot.Root;$reportRootForRun=Join-Path (Split-Path -Parent (Split-Path -Parent $QueuePath)) 'reports';New-Item -ItemType Directory -Force -Path $reportRootForRun|Out-Null }
    catch { $Record.state='blocked';$Record.reason=$_.Exception.Message;Save-Queue $Queue;return $Record }
  }
  $Record.state = 'running'; $Record.attempts = [int]$Record.attempts + 1
  $Record.started_at = (Get-Date).ToUniversalTime().ToString('o'); Save-Queue $Queue
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $executor = Join-Path $scriptDir 'executor.ps1'
  $executorArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$executor,'-Task',$Record.task_path,'-Worktree',$executionWorktree,'-ReportRoot',$reportRootForRun)
  if($null -ne $snapshot){$executorArgs+=@('-SnapshotManifest',$snapshot.Manifest)}
  $run = Invoke-Process $powershell $executorArgs $executionWorktree $TimeoutSeconds
  $reportPath = Join-Path $reportRootForRun $taskObject.reportPath
  $reportPresent = Test-Path -LiteralPath $reportPath -PathType Leaf
  $reason = if($run.TimedOut){'executor timeout'}elseif($run.ExitCode -ne 0){'executor failed'}elseif(!$reportPresent){'executor report missing'}else{'executor completed'}
  $stateDir = Join-Path (Split-Path -Parent $QueuePath) 'orchestrator-state'
  $resultPath = Join-Path $stateDir "$($taskObject.id)-result.json"
  $classificationPath = Join-Path $stateDir "$($taskObject.id)-classification.json"
  Write-Json $resultPath (New-ClassificationInput $taskObject $run.ExitCode $run.TimedOut $reportPresent $reason)
  $classifier = Join-Path $scriptDir 'classify-result.ps1'
  $classificationRun = Invoke-Process $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$classifier,'-InputJson',$resultPath,'-OutFile',$classificationPath) $Worktree 120
  $classification = $null
  if ($classificationRun.ExitCode -eq 0 -and (Test-Path -LiteralPath $classificationPath)) { $classification = Read-Json $classificationPath }
  $Record.finished_at = (Get-Date).ToUniversalTime().ToString('o')
  $Record.report_path = $reportPath; $Record.report_sha256 = Get-ReportHash $reportPath
  $Record.result_path = $resultPath; $Record.classification_path = $classificationPath
  $Record.executor_exit_code = $run.ExitCode
  if ($null -eq $classification) { $Record.state = 'blocked'; $Record.reason = 'classification failed' }
  else {
    $Record.classification = $classification.classification
    $Record.event = $classification.event
    $Record.state = switch ($classification.classification) {
      'COMPLETED' { 'completed' }; 'READY_FOR_REVIEW' { 'ready_for_review' }
      'WAITING_FOR_USER' { 'waiting_for_user' }; default { 'blocked' }
    }
  }
  Save-Queue $Queue
  return $Record
}
function Invoke-QueueOnce([object] $Queue) {
  $running=@($Queue.tasks|Where-Object{$_.state -eq 'running'}).Count
  if($running -gt 0){return [pscustomobject]@{started=$false;message='running task present'}}
  $blocked=@($Queue.tasks|Where-Object{$_.state -in @('ready_for_review','waiting_for_user','changes_requested','blocked')})
  if($blocked.Count -gt 0){return [pscustomobject]@{started=$false;message="safe stop: $($blocked[0].task_id)"}}
  $record=$Queue.tasks|Where-Object{$_.state -eq 'queued'}|Select-Object -First 1
  if(!$record){return [pscustomobject]@{started=$false;message='idle'}}
  if([int]$record.attempts -ge $MaxAttempts){$record.state='blocked';$record.reason='attempt limit reached';Save-Queue $Queue;return [pscustomobject]@{started=$false;message='attempt limit reached'}}
  $taskObject=Read-Json $record.task_path
  Invoke-One $Queue $record | Out-Null
  return [pscustomobject]@{started=$true;message=$record.task_id}
}
function Invoke-AutoReview([object] $Queue) {
  $record=$Queue.tasks|Where-Object{$_.state -eq 'ready_for_review'}|Select-Object -First 1
  if(!$record){return [pscustomobject]@{attempted=$false;message='no review pending'}}
  $task=Read-Json $record.task_path;$reviewDir=Join-Path (Split-Path -Parent $QueuePath) 'reviews';New-Item -ItemType Directory -Force -Path $reviewDir|Out-Null
  $reviewPath=Join-Path $reviewDir "$($task.id).json";$reviewer=Join-Path $scriptDir 'independent-review.ps1';$powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
  $reviewRun=Invoke-Process $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$reviewer,'-Report',$record.report_path,'-TaskId',$task.id,'-AnalyzedCommit',$task.baseCommit,'-ReportSha256',$record.report_sha256,'-OutFile',$reviewPath,'-TimeoutSeconds','300') $Worktree 360
  if($reviewRun.ExitCode -ne 0 -or !(Test-Path $reviewPath)){Set-Content -LiteralPath (Join-Path $reviewDir "$($task.id)-review-error.log") -Value $reviewRun.Output -Encoding UTF8;return [pscustomobject]@{attempted=$true;message="independent reviewer failed: $($reviewRun.ExitCode)"}}
  $reviewCommand=Invoke-Process $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:OrchestratorPath,'-Command','Review','-QueuePath',$QueuePath,'-TaskId',$task.id,'-Review',$reviewPath,'-Worktree',$Worktree,'-ContinueAfterReview') $Worktree 900
  return [pscustomobject]@{attempted=$true;message=if($reviewCommand.ExitCode -eq 0){'review applied'}else{'review application failed'}}
}

$Worktree = (Resolve-Path -LiteralPath $Worktree).Path
$QueuePath = if ([IO.Path]::IsPathRooted($QueuePath)) {
  [IO.Path]::GetFullPath($QueuePath)
} else {
  [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $QueuePath))
}
$queue = Get-Queue
if ($null -eq $queue.tasks) { $queue.tasks = @() }

switch ($Command) {
  'Add' {
    if ([string]::IsNullOrWhiteSpace($Task)) { Fail '-Task é obrigatório' }
    $source = (Resolve-Path -LiteralPath $Task -ErrorAction Stop).Path; $taskObject = Read-Json $source
    Assert-TaskId ([string]$taskObject.id)
    if ($taskObject.state -ne 'approved') { Fail 'somente tarefas approved entram na fila' }
    if (Get-TaskRecord $queue $taskObject.id) { Fail 'task_id já existe na fila' }
    $taskDir = Join-Path (Split-Path -Parent $QueuePath) 'orchestrator-tasks'
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    $stored = Join-Path $taskDir "$($taskObject.id).json"; Copy-Item -LiteralPath $source -Destination $stored
    $queue.tasks += [pscustomobject]@{ task_id=$taskObject.id; task_path=$stored; state='queued'; attempts=0; added_at=(Get-Date).ToUniversalTime().ToString('o') }
    Save-Queue $queue; Write-Output "QUEUED: $($taskObject.id)"; break
  }
  'Status' { $queue | ConvertTo-Json -Depth 20; break }
  'Recover' {
    foreach($record in @($queue.tasks | Where-Object {$_.state -eq 'running'})){if($null -eq $record.PSObject.Properties['reason']){$record|Add-Member -NotePropertyName reason -NotePropertyValue $null}}
    Recover-StaleRunning $queue; Write-Output 'RECOVERED'; break
  }
  'Pause' { Write-Control 'watch.pause' 'operator pause requested'; Write-Output 'PAUSE_REQUESTED'; break }
  'Resume' { $pause=Get-ControlPath 'watch.pause'; if(Test-Path $pause){Remove-Item -LiteralPath $pause -Force}; Write-Output 'RESUME_REQUESTED'; break }
  'Stop' { Write-Control 'watch.stop' 'operator stop requested'; Write-Output 'STOP_REQUESTED'; break }
  'Cancel' {
    if ([string]::IsNullOrWhiteSpace($TaskId)) { Fail '-TaskId é obrigatório' }
    $record = Get-TaskRecord $queue $TaskId; if (!$record) { Fail 'task_id não encontrado' }
    if ($record.state -in @('queued','running','ready_for_review')) {
      if ($record.state -eq 'running') {
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
        $executor = Join-Path $scriptDir 'executor.ps1'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $executor -Task $record.task_path -Worktree $Worktree -Cancel 2>&1 | Out-Null
      }
      $record.state='cancelled'; $record.reason='cancel requested'; Save-Queue $queue; Write-Output "CANCELLED: $TaskId"; break
    }
    Fail "estado não cancelável: $($record.state)"
  }
  'Review' {
    if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Review)) { Fail '-TaskId e -Review são obrigatórios' }
    $record = Get-TaskRecord $queue $TaskId; if (!$record) { Fail 'task_id não encontrado' }
    $reviewPath = (Resolve-Path -LiteralPath $Review).Path; $reviewObject = Read-Json $reviewPath
    $taskObject = Read-Json $record.task_path
    foreach($name in @('review_path','review_decision','reviewer_identity','reviewer_execution_id','review')) {
      if ($null -eq $record.PSObject.Properties[$name]) { $record | Add-Member -NotePropertyName $name -NotePropertyValue $null }
    }
    if ($null -ne $record.PSObject.Properties['reviewer_execution_id'] -and $record.reviewer_execution_id) { Fail 'revisão duplicada' }
    foreach($required in @('schema_version','task_id','decision','criteria_verified','reviewer_identity','reviewer_execution_id','findings','reviewed_at','report_sha256','analyzed_commit')) { if ($null -eq $reviewObject.PSObject.Properties[$required]) { Fail "contrato de revisão incompleto: $required" } }
    $allowedReviewFields = @('schema_version','task_id','analyzed_commit','report_sha256','decision','findings','criteria_verified','reviewed_at','reviewer_identity','reviewer_execution_id')
    $unknownReviewFields = @($reviewObject.PSObject.Properties.Name | Where-Object { $_ -notin $allowedReviewFields })
    if ($unknownReviewFields.Count -gt 0) { Fail "campos de revisão não permitidos: $($unknownReviewFields -join ', ')" }
    if ($reviewObject.criteria_verified -isnot [bool] -or $reviewObject.findings -isnot [array]) { Fail 'tipos inválidos em criteria_verified/findings' }
    if ($reviewObject.schema_version -ne '1.0' -or [string]$reviewObject.reviewed_at -eq '' -or [string]$reviewObject.reviewer_identity -eq '' -or [string]$reviewObject.report_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$reviewObject.analyzed_commit -notmatch '^[0-9a-fA-F]{40}$') { Fail 'valores de vínculo/revisão inválidos' }
    if ($record.state -ne 'ready_for_review' -or $reviewObject.task_id -ne $TaskId -or $reviewObject.report_sha256.ToLower() -ne $record.report_sha256.ToLower() -or $reviewObject.analyzed_commit -ne $taskObject.baseCommit -or [string]::IsNullOrWhiteSpace([string]$reviewObject.reviewer_execution_id) -or [string]$reviewObject.reviewer_identity -match 'executor') { Fail 'revisão ausente, incompatível ou não independente' }
    if ($reviewObject.decision -notin @('APPROVED','CHANGES_REQUESTED','BLOCKED','HUMAN_REVIEW_REQUIRED')) { Fail 'decisão desconhecida' }
    $record.review_path=$reviewPath; $record.review_decision=$reviewObject.decision; $record.reviewer_identity=$reviewObject.reviewer_identity; $record.reviewer_execution_id=$reviewObject.reviewer_execution_id
    if ($reviewObject.decision -eq 'APPROVED' -and $reviewObject.criteria_verified -eq $true) {
      $record.state='completed'; $record.review='approved'; Save-Queue $queue; Write-Output "APPROVED: $TaskId"
      if ($ContinueAfterReview) {
        $next = $queue.tasks | Where-Object {$_.state -eq 'queued'} | Select-Object -First 1
        if ($next) { Invoke-One $queue $next | ConvertTo-Json -Depth 20 }
      }
      break
    }
    $record.state=if($reviewObject.decision -eq 'CHANGES_REQUESTED'){'changes_requested'}else{'blocked'}; $record.reason=[string]($reviewObject.findings -join '; '); Save-Queue $queue; Write-Output "$($reviewObject.decision): $TaskId"; break
  }
  'Run' {
    $result=Invoke-QueueOnce $queue
    if($result.message -in @('running task present','attempt limit reached') -or $result.message -like 'safe stop*'){Fail $result.message}
    Write-Output $result.message
    break
  }
  'Watch' {
    if($IntervalSeconds -lt 1 -or $IntervalSeconds -gt 300){Fail 'IntervalSeconds fora do intervalo'}
    $watchLockPath=Get-ControlPath 'watch.lock';$watchLock=$null
    try {
      try{$watchLock=[IO.File]::Open($watchLockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch{Fail 'já existe um Watch nesta fila'}
      $lockJson=[ordered]@{pid=$PID;started_at=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json;$lockBytes=[Text.Encoding]::UTF8.GetBytes($lockJson);$watchLock.Write($lockBytes,0,$lockBytes.Length);$watchLock.Flush()
      $script:WatchMode=$true;Recover-StaleRunning $queue; Write-Heartbeat 'running' 'watch started'
      while($true){
        if(Test-Path (Get-ControlPath 'watch.stop')){Write-Heartbeat 'stopped' 'stop requested';break}
        $queue=Get-Queue;if($null -eq $queue.tasks){$queue.tasks=@()}
        if(Test-Path (Get-ControlPath 'watch.pause')){Write-Heartbeat 'paused' 'pause requested'}else{try{$reviewResult=Invoke-AutoReview $queue;if($reviewResult.attempted){Write-Heartbeat 'running' $reviewResult.message}else{$result=Invoke-QueueOnce $queue;Write-Heartbeat 'running' $result.message}}catch{Write-Heartbeat 'blocked' $_.Exception.Message;break}}
        Start-Sleep -Seconds $IntervalSeconds
      }
    } finally {
      if($null -ne $watchLock){$watchLock.Dispose()};if(Test-Path $watchLockPath){Remove-Item -LiteralPath $watchLockPath -Force -ErrorAction SilentlyContinue};$stop=Get-ControlPath 'watch.stop';if(Test-Path $stop){Remove-Item -LiteralPath $stop -Force -ErrorAction SilentlyContinue}
    }
    break
  }
}
