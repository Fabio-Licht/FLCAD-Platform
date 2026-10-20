[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Intervention,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [switch] $SimulatePublication
)
$ErrorActionPreference='Stop'
function Fail([string]$Message){throw "AB-03 GitHub transport rejected: $Message"}
$raw=Get-Content -LiteralPath $Intervention -Raw; try{$i=$raw|ConvertFrom-Json}catch{Fail 'JSON malformado'}
$allowedProperties=@('schema_version','task_id','event','state','reason','priority','action_requested','technical_summary','report_reference','branch','commit','deduplication_id','execution_mode','gui_control_authorization','notification_status','handled')
foreach($property in $i.PSObject.Properties.Name){if($property -notin $allowedProperties){Fail "campo inesperado: $property"}}
function Git-Run([string[]]$GitArguments,[string]$Root){$o=& git -C "$Root" @GitArguments 2>&1;[pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()}}
foreach($n in @('task_id','event','state','reason','priority','action_requested','technical_summary','report_reference','branch','commit','deduplication_id')){if($null -eq $i.PSObject.Properties[$n]){Fail "campo ausente: $n"}}
if($i.schema_version -ne '1.0'){Fail 'schema_version não suportada'}
if($i.event -notin @('USER_TEST_REQUIRED','USER_APPROVAL_REQUIRED','AGENT_BLOCKED')){Fail 'evento não notificável'}
if($i.priority -notmatch '^P[0-3]$'){Fail 'prioridade inválida'}
if($i.task_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'){Fail 'task_id inválido'}
if($i.deduplication_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$'){Fail 'deduplication_id inválido'}
if($i.commit -notmatch '^[0-9a-fA-F]{40}$'){Fail 'commit inválido'}
if($i.notification_status -eq 'handled'){Fail 'intervenção já atendida'}
$root=(Resolve-Path -LiteralPath $Worktree).Path; $remote=Git-Run -GitArguments @('remote','get-url','origin') -Root $root
New-Item -ItemType Directory -Force -Path $OutDir|Out-Null; $outRoot=(Resolve-Path $OutDir).Path; $file=Join-Path $outRoot "$($i.deduplication_id)-github.json"
if(Test-Path $file){Fail 'envelope de transporte duplicado'}
$gh=$null -ne (Get-Command gh -ErrorAction SilentlyContinue)
$body="FLCAD intervention required`n`nTask: $($i.task_id)`nEvent: $($i.event)`nPriority: $($i.priority)`nReason: $($i.reason)`nAction requested: $($i.action_requested)`nTechnical summary: $($i.technical_summary)`nReport reference: $($i.report_reference)`nBranch: $($i.branch)`nCommit: $($i.commit)`nDeduplication ID: $($i.deduplication_id)`n`nThis issue is a review request. It is not an execution authorization."
if($body -match '(?i)(token|password|secret|api[_-]?key|authorization|bearer)\s*[:=]'){Fail 'corpo do Issue contém possível credencial'}
$envelope=[ordered]@{schema_version='1.0';transport_status='prepared-for-publication';simulated=[bool]$SimulatePublication;issue_title="[FLCAD][$($i.priority)] $($i.event) - $($i.task_id)";issue_body=$body;labels=@('flcad-automation','human-intervention',$i.event.ToLower());assignees=@();remote_configured=($remote.Code -eq 0 -and $remote.Text.Length -gt 0);write_permission='not-verified';gh_available=$gh;publish_performed=$false;requires_human_authorization=$true}
$envelope|ConvertTo-Json -Depth 10|Set-Content $file -Encoding UTF8
[ordered]@{status='prepared-for-publication';file=$file;publish_performed=$false;write_permission='not-verified';remote_configured=$envelope.remote_configured;gh_available=$gh}|ConvertTo-Json
