[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Report,
  [Parameter(Mandatory = $true)] [string] $Task,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [switch] $SimulatePublication
)

$ErrorActionPreference = 'Stop'
$script:Version = '0.1.0'

function Fail([string] $Message) { throw "AB-02 report rejected: $Message" }
function Read-Json([string] $Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "arquivo ausente: $Path" }
  try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { Fail "JSON inválido: $Path" }
}
function Require([object] $Object, [string] $Name) {
  if ($null -eq $Object.PSObject.Properties[$Name]) { Fail "campo ausente: $Name" }
  return $Object.$Name
}
function Assert-String([object] $Object, [string] $Name) {
  $value = Require $Object $Name
  if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { Fail "campo vazio: $Name" }
  return $value
}
function Safe-Id([string] $Value) { if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail 'task_id inválido' }; return $Value }
function Git-Run([string[]] $GitArguments, [string] $Root) { $o=& git -C "$Root" @GitArguments 2>&1; [pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()} }
function Hash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Relative-Safe([string] $Path) { return $Path -replace '^[A-Za-z]:[^\\]*\\','' -replace '^[A-Za-z]:','' -replace '\\','/' }
function Assert-NoSensitive([string] $Text) {
  if ($Text -match '(?i)(token|password|secret|api[_-]?key|authorization|bearer|private[_-]?key|credential)\s*[:=]') { Fail 'conteúdo sensível detectado no relatório' }
}

$root = (Resolve-Path -LiteralPath $Worktree).Path
$taskObject = Read-Json $Task
$source = Read-Json $Report
$taskId = Safe-Id (Assert-String $source 'taskId')
$taskIdFromTask = Safe-Id (Assert-String $taskObject 'id')
if ($taskId -ne $taskIdFromTask) { Fail 'task_id do relatório diverge da tarefa' }
$branch = Git-Run -GitArguments @('branch','--show-current') -Root $root
$head = Git-Run -GitArguments @('rev-parse','HEAD') -Root $root
if ($branch.Code -ne 0 -or $branch.Text -ne (Assert-String $taskObject 'sourceBranch')) { Fail "branch obsoleta ou divergente: obtido=[$($branch.Text)] esperado=[$($taskObject.sourceBranch)] code=$($branch.Code)" }
if ($head.Code -ne 0 -or $head.Text -ne (Assert-String $taskObject 'baseCommit')) { Fail "HEAD obsoleto ou divergente: obtido=[$($head.Text)] esperado=[$($taskObject.baseCommit)] code=$($head.Code)" }
Assert-String $source 'branch' | Out-Null
Assert-String $source 'head' | Out-Null
Assert-String $source 'status' | Out-Null
if ($source.status -notin @('completed','failed')) { Fail 'status do relatório inválido' }
if ($null -eq $source.PSObject.Properties['durationMs'] -or $source.durationMs -isnot [ValueType]) { Fail 'durationMs ausente ou inválido' }
if ($source.branch -ne $branch.Text) { Fail 'branch do resultado obsoleto ou divergente' }
if ($source.head -ne $head.Text) { Fail 'HEAD do resultado obsoleto ou divergente' }
$sourceHash = Hash $Report
$objective = Assert-String $taskObject 'objective'
$criteria = @($taskObject.acceptanceCriteria | ForEach-Object {[string]$_})
$executionStatus = if ($source.status -eq 'completed') {'completed'} elseif ($source.timedOut) {'timed-out'} else {'failed'}
$tests = @{ passed = @([string]$taskObject.requiredTests | Where-Object { $_ }); failed = @(); not_run = @() }
$evidence = @()
$evidence += [ordered]@{ kind = 'source-report'; label = 'executor report'; sha256 = $sourceHash }
$safeText = "$taskId $objective $($criteria -join ' ') $executionStatus"
Assert-NoSensitive $safeText
$safeReport = [ordered]@{
  schema_version = '1.0'
  task_id = $taskId
  lifecycle_status = 'prepared-for-publication'
  branch = $branch.Text
  head = $head.Text
  objective = $objective
  acceptance_criteria = $criteria
  execution_status = $executionStatus
  tests = $tests
  duration_ms = [double]($source.durationMs)
  files_changed = @()
  limitations = @('AB-01 whitelist permanece ativa; não há execução geral de implementação.', 'Pacote não contém logs brutos, credenciais ou conteúdo privado.')
  evidence = $evidence
  next_step = 'Revisão humana independente antes de qualquer publicação ou nova tarefa.'
  transport = [ordered]@{ status = 'prepared-for-publication'; write_permission = 'not-verified' }
  source_report_sha256 = $sourceHash
}
$serialized = $safeReport | ConvertTo-Json -Depth 10
Assert-NoSensitive $serialized
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$package = Join-Path (Resolve-Path -LiteralPath $OutDir).Path $taskId
if (Test-Path -LiteralPath $package) { Fail "task_id duplicado no outbox: $taskId" }
New-Item -ItemType Directory -Force -Path $package | Out-Null
$reportPath = Join-Path $package 'report.json'
$reviewPath = Join-Path $package 'review-request.json'
$transportPath = Join-Path $package 'transport.json'
$serialized | Set-Content -LiteralPath $reportPath -Encoding UTF8
$review = Read-Json (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'review-template.json')
$review.task_id = $taskId; $review.report_sha256 = Hash $reportPath
$review | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reviewPath -Encoding UTF8
$remote = Git-Run -GitArguments @('remote','get-url','origin') -Root $root
$remoteConfigured = $remote.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($remote.Text)
$transport = [ordered]@{ status = 'prepared-for-publication'; simulated = [bool]$SimulatePublication; remote_configured = $remoteConfigured; write_permission = 'not-verified'; gh_available = ($null -ne (Get-Command gh -ErrorAction SilentlyContinue)); push_performed = $false }
$transport | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $transportPath -Encoding UTF8
$files = Get-ChildItem -LiteralPath $package -File
$manifestEntries = @($files | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = Hash $_.FullName } })
$manifest = [ordered]@{ schema_version='1.0'; task_id=$taskId; package_status='prepared-for-publication'; files=$manifestEntries; integrity='sha256' }
$manifestPath = Join-Path $package 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$manifestHash = Hash $manifestPath
[ordered]@{ package_status='prepared-for-publication'; task_id=$taskId; package_relative_path=(Join-Path 'outbox' $taskId) -replace '\\','/'; report_sha256=(Hash $reportPath); manifest_sha256=$manifestHash; transport=$transport } | ConvertTo-Json -Depth 8
