[CmdletBinding()]
param(
  [ValidateSet('Prepare','Status')][string]$Command = 'Prepare',
  [Parameter(Mandatory=$true)][string]$Outbox,
  [Parameter(Mandatory=$true)][string]$Worktree,
  [string]$Policy = (Join-Path $PSScriptRoot 'publication-policy.json'),
  [string]$AuthorizationTicket = '',
  [switch]$AuthorizePush
)

$ErrorActionPreference = 'Stop'
function Fail([string]$Message){ throw "AB-09C recurring publication rejected: $Message" }
function Read-Json([string]$Path){ try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { Fail "invalid JSON: $Path" } }
function Git-Run([string[]]$GitArguments,[string]$Root){$o=& git -C $Root @GitArguments 2>&1;[pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()}}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Safe-Id([string]$Value){if($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'){Fail 'task_id invalid'}}
function Validate-Policy([object]$Value){
  foreach($n in @('schema_version','policy_id','enabled','destination_branch','allowed_files','max_packages_per_run','max_total_bytes','max_package_bytes','push_mode')){if($null -eq $Value.PSObject.Properties[$n]){Fail "policy field missing: $n"}}
  if($Value.schema_version -ne '1.0' -or $Value.enabled -ne $true -or $Value.destination_branch -ne 'automation/reports' -or $Value.push_mode -ne 'operator-authorized-only'){Fail 'policy is not the closed automation/reports policy'}
  $allowed=@($Value.allowed_files|ForEach-Object{[string]$_}); if($allowed.Count -ne 3 -or @($allowed|Where-Object{$_ -notin @('report.json','review-request.json','manifest.json')}).Count -gt 0){Fail 'policy file allowlist is invalid'}
  if([int]$Value.max_packages_per_run -lt 1 -or [int]$Value.max_packages_per_run -gt 20 -or [int64]$Value.max_total_bytes -lt 1 -or [int64]$Value.max_package_bytes -lt 1){Fail 'policy limits are invalid'}
}
function Assert-Status([string]$Text){
  foreach($line in ($Text -split "`n"|Where-Object{$_.Trim()})){
    if($line.Trim() -notmatch '^\?\?\s+reports(?:/.*)?$'){Fail 'worktree has unexpected changes or staged content'}
  }
}
function Read-Ticket([string]$Path){try{Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{Fail 'authorization ticket is invalid JSON'}}
function Validate-Ticket([object]$Ticket,[string]$Path,[string]$PackageRoot,[string]$TaskId){
  foreach($n in @('schema_version','authorization_id','task_id','package_path','package_sha256','branch','expected_remote_sha','max_publications','expires_at','state')){if($null -eq $Ticket.PSObject.Properties[$n]){Fail "authorization ticket field missing: $n"}}
  if($Ticket.schema_version -ne '1.0' -or $Ticket.branch -ne 'automation/reports' -or $Ticket.max_publications -ne 1 -or $Ticket.state -ne 'issued'){Fail 'authorization ticket is not issued for one use'}
  if($Ticket.task_id -ne $TaskId -or [IO.Path]::GetFullPath($Ticket.package_path).TrimEnd('\') -ne $PackageRoot.TrimEnd('\')){Fail 'authorization ticket package binding mismatch'}
  if($Ticket.package_sha256 -ne (Hash (Join-Path $PackageRoot 'manifest.json'))){Fail 'authorization ticket package SHA-256 mismatch'}
  if($Ticket.expected_remote_sha -notmatch '^[0-9a-fA-F]{40}$'){Fail 'authorization ticket remote SHA is invalid'}
  try{$expires=[datetime]::Parse([string]$Ticket.expires_at).ToUniversalTime()}catch{Fail 'authorization ticket expiry is invalid'}
  if($expires -le (Get-Date).ToUniversalTime()){Fail 'authorization ticket expired'}
  return $Ticket
}
function Consume-Ticket([string]$Path,[object]$Ticket,[string]$CandidateCommit){
  $lockPath="$Path.lock";$lock=$null
  try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch{Fail 'authorization ticket is already being consumed'}
  try{
    $current=Read-Ticket $Path;if($current.state -ne 'issued' -or $current.authorization_id -ne $Ticket.authorization_id){Fail 'authorization ticket was consumed or changed'}
    $current.state='consumed'
    if($null -eq $current.PSObject.Properties['candidate_commit']){$current|Add-Member -NotePropertyName candidate_commit -NotePropertyValue $CandidateCommit}else{$current.candidate_commit=$CandidateCommit}
    $consumedAt=(Get-Date).ToUniversalTime().ToString('o')
    if($null -eq $current.PSObject.Properties['consumed_at']){$current|Add-Member -NotePropertyName consumed_at -NotePropertyValue $consumedAt}else{$current.consumed_at=$consumedAt}
    $tmp="$Path.$([guid]::NewGuid().ToString('N')).tmp";$current|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $Path -Force
  } finally {if($null -ne $lock){$lock.Dispose()};if(Test-Path $lockPath){Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue}}
}

$worktreeRoot=(Resolve-Path -LiteralPath $Worktree).Path
$outboxRoot=(Resolve-Path -LiteralPath $Outbox).Path
$policyObject=Read-Json ((Resolve-Path -LiteralPath $Policy).Path); Validate-Policy $policyObject
if($AuthorizePush -and [string]::IsNullOrWhiteSpace($AuthorizationTicket)){Fail 'one-time authorization ticket is required'}
$branch=Git-Run @('branch','--show-current') $worktreeRoot
if($branch.Code -ne 0 -or $branch.Text -ne [string]$policyObject.destination_branch){Fail "destination branch mismatch: got=[$($branch.Text)] expected=[$($policyObject.destination_branch)]"}
$origin=Git-Run @('remote','get-url','origin') $worktreeRoot
if($origin.Code -ne 0 -or [string]::IsNullOrWhiteSpace($origin.Text)){Fail 'origin is not configured'}
$status=Git-Run @('status','--porcelain') $worktreeRoot
if($status.Code -ne 0){Fail 'could not inspect worktree'}
Assert-Status $status.Text

$candidates=@(Get-ChildItem -LiteralPath $outboxRoot -Directory | Sort-Object Name)
if($candidates.Count -gt [int]$policyObject.max_packages_per_run){Fail 'package count exceeds policy limit'}
$ticket=$null
if($AuthorizePush){
  if($candidates.Count -ne 1){Fail 'one-time authorization requires exactly one eligible package'}
  $candidateReport=Read-Json (Join-Path $candidates[0].FullName 'report.json')
  $ticket=Validate-Ticket (Read-Ticket ((Resolve-Path -LiteralPath $AuthorizationTicket).Path)) ((Resolve-Path -LiteralPath $AuthorizationTicket).Path) ((Resolve-Path -LiteralPath $candidates[0].FullName).Path) ([string]$candidateReport.task_id)
}
$summary=@();$preparedPaths=@();$totalBytes=0L
foreach($dir in $candidates){
  $files=@(Get-ChildItem -LiteralPath $dir.FullName -File)
  $names=@($files|ForEach-Object{$_.Name})
  if($files.Count -ne 4 -or @($names|Where-Object{$_ -notin @('report.json','review-request.json','manifest.json','transport.json')}).Count -gt 0 -or @($names|Select-Object -Unique).Count -ne 4){Fail "package $($dir.Name) does not have the AB-04 local contract"}
  $report=Read-Json (Join-Path $dir.FullName 'report.json'); Safe-Id ([string]$report.task_id)
  if($dir.Name -ne [string]$report.task_id){Fail "directory/task_id mismatch: $($dir.Name)"}
  $packageBytes=([int64]($files|Measure-Object -Property Length -Sum).Sum); if($packageBytes -gt [int64]$policyObject.max_package_bytes){Fail "package too large: $($dir.Name)"};$totalBytes+=$packageBytes
  if($totalBytes -gt [int64]$policyObject.max_total_bytes){Fail 'total package size exceeds policy limit'}
  if($Command -eq 'Status'){ $summary += [ordered]@{task_id=$report.task_id;bytes=$packageBytes}; continue }
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'publish-report.ps1'),'-Package',$dir.FullName,'-Worktree',$worktreeRoot,'-Branch',$policyObject.destination_branch,'-Version','1','-AllowPreparedOutputs')
  $raw=& powershell.exe @args 2>&1; if($LASTEXITCODE -ne 0){Fail "publisher failed for $($dir.Name): $($raw -join ' ')"};$result=($raw -join "`n")|ConvertFrom-Json
  if($result.status -notin @('prepared-for-publication','idempotent')){Fail "publisher did not prepare $($dir.Name)"}
  $summary += [ordered]@{task_id=$result.task_id;status=$result.status;destination=$result.destination;public_manifest_sha256=$result.public_manifest_sha256}
  if($result.status -eq 'prepared-for-publication'){foreach($name in @('report.json','review-request.json','manifest.json')){$preparedPaths += ((Join-Path ([string]$result.destination) $name) -replace '\\','/')}}
}
if($Command -eq 'Status'){[ordered]@{status='eligible-packages';policy_id=$policyObject.policy_id;packages=$summary}|ConvertTo-Json -Depth 8;exit 0}

if($AuthorizePush){
  $fetch=Git-Run @('fetch','origin') $worktreeRoot;if($fetch.Code -ne 0){Fail 'git fetch failed'}
  $remoteRef="refs/remotes/origin/$($policyObject.destination_branch)";$base=(Git-Run @('rev-parse',$remoteRef) $worktreeRoot);if($base.Code -ne 0){Fail 'remote destination branch is missing'}
  if($base.Text.ToLowerInvariant() -ne [string]$ticket.expected_remote_sha.ToLowerInvariant()){Fail 'remote advanced beyond authorization ticket'}
  if($preparedPaths.Count -eq 0){Fail 'authorized package is already published; refusing replay'}
  $before=@(git -C $worktreeRoot status --porcelain);Assert-Status ($before -join "`n")
  git -C $worktreeRoot add -- @preparedPaths
  $staged=@(git -C $worktreeRoot diff --cached --name-only);if(@(Compare-Object $preparedPaths $staged).Count -ne 0){Fail 'staging differs from prepared allowlist'}
  git -C $worktreeRoot diff --cached --check;if($LASTEXITCODE -ne 0){Fail 'staged diff check failed'}
  git -C $worktreeRoot commit -m 'docs(automation): publish technical review packages';if($LASTEXITCODE -ne 0){Fail 'commit failed'}
  $candidateCommit=(git -C $worktreeRoot rev-parse HEAD).Trim();Consume-Ticket ((Resolve-Path -LiteralPath $AuthorizationTicket).Path) $ticket $candidateCommit
  $push=Git-Run @('push','origin',$policyObject.destination_branch) $worktreeRoot;if($push.Code -ne 0){Fail 'push failed'}
  [ordered]@{status='published';packages=$summary;push_performed=$true;authorization_id=$ticket.authorization_id;candidate_commit=$candidateCommit}|ConvertTo-Json -Depth 8;exit 0
}
[ordered]@{status='prepared-for-publication';packages=$summary;push_performed=$false;policy_id=$policyObject.policy_id}|ConvertTo-Json -Depth 8
