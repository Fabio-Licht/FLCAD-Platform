[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Package,
  [Parameter(Mandatory=$true)][string]$TaskId,
  [Parameter(Mandatory=$true)][string]$Worktree,
  [Parameter(Mandatory=$true)][string]$OutFile,
  [Parameter(Mandatory=$true)][datetime]$ExpiresAt
)
$ErrorActionPreference='Stop'
function Fail([string]$Message){throw "AB-09G authorization rejected: $Message"}
function Read-Json([string]$Path){try{Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{Fail 'invalid JSON'}}
function Hash([string]$Path){(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()}
function Git-Run([string[]]$GitArguments,[string]$Root){$o=& git -C $Root @GitArguments 2>&1;[pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()}}
if($ExpiresAt.ToUniversalTime() -le (Get-Date).ToUniversalTime()){Fail 'authorization must expire in the future'}
if($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'){Fail 'invalid task_id'}
$packageRoot=(Resolve-Path -LiteralPath $Package).Path;$worktreeRoot=(Resolve-Path -LiteralPath $Worktree).Path
$report=Join-Path $packageRoot 'report.json';$manifest=Join-Path $packageRoot 'manifest.json';$transport=Join-Path $packageRoot 'transport.json';$review=Join-Path $packageRoot 'review-request.json'
foreach($p in @($report,$manifest,$transport,$review)){if(!(Test-Path -LiteralPath $p -PathType Leaf)){Fail "package file missing: $p"}}
$r=Read-Json $report;$m=Read-Json $manifest;if($r.task_id -ne $TaskId -or $m.task_id -ne $TaskId){Fail 'task_id mismatch'}
if($m.package_status -ne 'prepared-for-publication'){Fail 'package is not prepared'}
$files=@($m.files|ForEach-Object{[string]$_.name});if($files.Count -ne 3 -or @($files|Where-Object{$_ -notin @('report.json','review-request.json','transport.json')}).Count -gt 0){Fail 'local manifest contract invalid'}
foreach($e in $m.files){if((Hash (Join-Path $packageRoot $e.name)) -ne [string]$e.sha256){Fail "package hash mismatch: $($e.name)"}}
$branch=Git-Run @('branch','--show-current') $worktreeRoot;$remote=Git-Run @('ls-remote','origin','refs/heads/automation/reports') $worktreeRoot
if($branch.Code -ne 0 -or $branch.Text -ne 'automation/reports'){Fail 'publication branch mismatch'};if($remote.Code -ne 0 -or $remote.Text -notmatch '^([0-9a-fA-F]{40})\s'){Fail 'remote branch unavailable'}
$expectedRemote=([regex]::Match($remote.Text,'^[0-9a-fA-F]{40}')).Value.ToLowerInvariant();$id='AB09G-'+[guid]::NewGuid().ToString('N')
$ticket=[ordered]@{schema_version='1.0';authorization_id=$id;task_id=$TaskId;package_path=$packageRoot;package_sha256=(Hash $manifest);branch='automation/reports';expected_remote_sha=$expectedRemote;max_publications=1;expires_at=$ExpiresAt.ToUniversalTime().ToString('o');state='issued';issued_at=(Get-Date).ToUniversalTime().ToString('o')}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile)|Out-Null;$ticket|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $OutFile -Encoding UTF8
$ticket|ConvertTo-Json -Depth 8
