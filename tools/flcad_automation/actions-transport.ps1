[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Intervention,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [string] $Repository = 'Fabio-Licht/FLCAD-Platform',
  [string] $Workflow = '.github/workflows/flcad-human-intervention.yml'
)
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "AB-03-F1 Actions transport rejected: $Message" }
$raw = Get-Content -LiteralPath $Intervention -Raw
try { $i = $raw | ConvertFrom-Json } catch { Fail 'JSON malformado' }
$allowedProperties = @('schema_version','task_id','event','state','reason','priority','action_requested','technical_summary','report_reference','branch','commit','deduplication_id','execution_mode','gui_control_authorization','notification_status','handled')
foreach ($property in $i.PSObject.Properties.Name) { if ($property -notin $allowedProperties) { Fail "campo inesperado: $property" } }
$allowed = @('USER_TEST_REQUIRED','USER_APPROVAL_REQUIRED','AGENT_BLOCKED')
foreach ($n in @('task_id','event','state','reason','priority','action_requested','technical_summary','report_reference','branch','commit','deduplication_id')) {
  if ($null -eq $i.PSObject.Properties[$n]) { Fail "campo ausente: $n" }
}
if ($i.schema_version -ne '1.0') { Fail 'schema_version não suportada' }
if ($i.event -notin $allowed) { Fail 'evento não permitido' }
$expectedState = if ($i.event -eq 'AGENT_BLOCKED') { 'BLOCKED' } else { 'WAITING_FOR_USER' }
if ($i.state -ne $expectedState) { Fail 'estado incompatível com o evento' }
if ($i.priority -notmatch '^P[0-3]$') { Fail 'prioridade inválida' }
if ($i.task_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail 'task_id inválido' }
if ($i.deduplication_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$') { Fail 'deduplication_id inválido' }
if ($i.commit -notmatch '^[0-9a-fA-F]{40}$') { Fail 'commit inválido' }
foreach ($n in @('reason','action_requested','technical_summary','report_reference','branch')) { $value = [string]$i.$n; if ($value.Length -lt 1 -or $value.Length -gt 4000) { Fail "campo excede limite: $n" } }
if ($i.notification_status -eq 'handled') { Fail 'intervenção já atendida' }
$serialized = $i | ConvertTo-Json -Depth 10 -Compress
if ($serialized.Length -gt 16000) { Fail 'payload excede 16 KiB' }
if ($serialized -match '(?i)(token|password|secret|api[_-]?key|authorization|bearer)\s*[:=]') { Fail 'payload contém possível credencial' }
$root = (Resolve-Path -LiteralPath $Worktree).Path
$git = & git -C $root rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) { Fail 'worktree Git inválido' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outRoot = (Resolve-Path $OutDir).Path
$file = Join-Path $outRoot "$($i.deduplication_id)-actions.json"
if (Test-Path -LiteralPath $file) { Fail 'pedido de dispatch duplicado' }
$inputs = [ordered]@{}
foreach ($n in @('task_id','event','state','reason','priority','action_requested','technical_summary','report_reference','branch','commit','deduplication_id')) { $inputs[$n] = [string]$i.$n }
$inputs.publish = 'false'
$envelope = [ordered]@{
  schema_version = '1.0'
  transport = 'github-actions-workflow-dispatch'
  status = 'prepared-for-publication'
  repository = $Repository
  workflow = $Workflow
  ref = [string]$i.branch
  inputs = $inputs
  dispatch_performed = $false
  issue_publication_enabled = $false
  authentication = 'not-used'
  requires_explicit_operator_dispatch = $true
}
$envelope | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding UTF8
[ordered]@{status=$envelope.status;file=$file;dispatch_performed=$false;issue_publication_enabled=$false;repository=$Repository;workflow=$Workflow}|ConvertTo-Json -Compress
