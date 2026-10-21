[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$DecisionPath,
  [Parameter(Mandatory=$true)][string]$ReportPath,
  [Parameter(Mandatory=$true)][string]$TaskId,
  [Parameter(Mandatory=$true)][string]$AnalyzedCommit,
  [Parameter(Mandatory=$true)][int]$ReportVersion,
  [string]$DeduplicationLedger,
  [string]$OutFile
)
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "external decision rejected: $Message" }
function Read-Json([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "arquivo ausente: $Path" }
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
  catch { Fail "JSON inválido: $Path" }
}
function Assert-Keys([object]$Value, [string[]]$Allowed) {
  $names = @($Value.PSObject.Properties.Name)
  foreach ($name in $names) { if ($Allowed -notcontains $name) { Fail "campo extra: $name" } }
  foreach ($name in $Allowed) { if ($null -eq $Value.PSObject.Properties[$name]) { Fail "campo ausente: $name" } }
}
function Assert-Text([string]$Value, [string]$Name, [int]$Max) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Max) { Fail "$Name inválido" }
}
function Assert-ReportFile([string]$Path) {
  $item = Get-Item -LiteralPath $Path -ErrorAction Stop
  if (-not $item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Fail 'relatório em reparse point' }
}

Assert-Text $TaskId 'task_id' 64
if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail 'task_id inválido' }
if ($AnalyzedCommit -notmatch '^[0-9a-fA-F]{40}$') { Fail 'analyzed_commit inválido' }
if ($ReportVersion -lt 1 -or $ReportVersion -gt 9999) { Fail 'report_version inválido' }
Assert-ReportFile $ReportPath
$decision = Read-Json $DecisionPath
$allowed = @('schema_version','task_id','analyzed_commit','report_version','report_sha256','decision','reviewer_identity','reviewer_execution_id','reviewed_at','criteria_verified','findings','decision_id')
Assert-Keys $decision $allowed
if ([string]$decision.schema_version -ne '1.0') { Fail 'schema_version incompatível' }
if ([string]$decision.task_id -ne $TaskId) { Fail 'task_id divergente' }
if ([string]$decision.analyzed_commit -ne $AnalyzedCommit) { Fail 'commit divergente' }
if ([int]$decision.report_version -ne $ReportVersion) { Fail 'versão do relatório divergente' }
if ([string]$decision.report_sha256 -notmatch '^[0-9a-fA-F]{64}$') { Fail 'report_sha256 inválido' }
if ([string]$decision.decision -notin @('APPROVED','CHANGES_REQUESTED','BLOCKED','HUMAN_REVIEW_REQUIRED')) { Fail 'decisão desconhecida' }
Assert-Text ([string]$decision.reviewer_identity) 'reviewer_identity' 200
Assert-Text ([string]$decision.reviewer_execution_id) 'reviewer_execution_id' 200
Assert-Text ([string]$decision.decision_id) 'decision_id' 128
if ([string]$decision.decision_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$') { Fail 'decision_id inválido' }
try { [DateTimeOffset]::Parse([string]$decision.reviewed_at) | Out-Null } catch { Fail 'reviewed_at inválido' }
if ($decision.criteria_verified -isnot [bool]) { Fail 'criteria_verified deve ser booleano' }
if ($decision.findings -isnot [array] -or @($decision.findings).Count -gt 50) { Fail 'findings inválido' }
foreach ($finding in @($decision.findings)) { if ($finding -isnot [string] -or $finding.Length -gt 2000) { Fail 'finding inválido' } }

$actualSha = (Get-FileHash -LiteralPath $ReportPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$decision.report_sha256.ToLowerInvariant() -ne $actualSha) { Fail 'SHA do relatório divergente' }
$replay = $false
if ($DeduplicationLedger) {
  if (Test-Path -LiteralPath $DeduplicationLedger -PathType Leaf) {
    $ledger = Read-Json $DeduplicationLedger
    $entries = if ($ledger -is [array]) { @($ledger) } elseif ($ledger.PSObject.Properties['entries']) { @($ledger.entries) } else { @($ledger) }
    foreach ($entry in $entries) {
      if ([string]$entry.decision_id -eq [string]$decision.decision_id) {
        if ([string]$entry.report_sha256 -ne [string]$decision.report_sha256 -or [string]$entry.task_id -ne [string]$decision.task_id) { Fail 'conflito de decision_id' }
        $replay = $true
      }
    }
  }
}

# A GitHub JSON file has no proof of signer, permission, or non-replay by itself.
# This command is deliberately read-only and never maps the decision to a queue action.
$result = [ordered]@{
  schema_version='1.0'; status='validated-read-only'; task_id=$TaskId
  analyzed_commit=$AnalyzedCommit; report_version=$ReportVersion; report_sha256=$actualSha
  decision=[string]$decision.decision; decision_id=[string]$decision.decision_id
  replay=$replay; authenticity='UNVERIFIED'; authenticated=$false
  forwarded=$false; auto_release=$false; requires_authenticated_operator=$true
  execution_authorized=$false; findings=@($decision.findings)
}
$json = $result | ConvertTo-Json -Depth 12
if ($OutFile) { $json | Set-Content -LiteralPath $OutFile -Encoding UTF8 }
$json
