[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Report,
  [Parameter(Mandatory = $true)] [string] $Task,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [string] $Review,
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

function Safe-PublicPath([string] $Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value) -or $Value -match '(^|[\\/])\.\.([\\/]|$)' -or $Value -match '(?i)\.(stl|step|stp|iges|igs|dxf|dwg|pdb|dll|exe|log)$') { return $null }
  $normalized = $Value -replace '\\','/'
  if ($normalized -match '(?i)(^|/)(artifacts|screenshots|credentials|secrets|private|\.git)(/|$)') { return $null }
  return $normalized
}
function Safe-PublicText([string] $Value, [int] $Max = 2000) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Max) { return $null }
  if ($Value -match '(?i)(C:\\|[A-Za-z]:/|\\\\|file://|\.stl\b|\.step\b|\.log\b|token\s*[:=]|password\s*[:=]|secret\s*[:=]|authorization\s*[:=]|bearer\s+)') { return $null }
  return $Value
}
function Read-Review([string] $Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $value = Read-Json $Path
  foreach ($name in @('decision','reviewer_identity','reviewer_execution_id','criteria_verified')) { if ($null -eq $value.PSObject.Properties[$name]) { Fail "review field missing: $name" } }
  if ([string]$value.decision -notin @('APPROVED','CHANGES_REQUESTED','BLOCKED','HUMAN_REVIEW_REQUIRED')) { Fail 'invalid review decision' }
  if ($null -eq (Safe-PublicText ([string]$value.reviewer_identity) 200) -or $null -eq (Safe-PublicText ([string]$value.reviewer_execution_id) 200)) { Fail 'review identity is not public' }
  return [ordered]@{ decision=[string]$value.decision; reviewer_identity=[string]$value.reviewer_identity; reviewer_execution_id=[string]$value.reviewer_execution_id; criteria_verified=[bool]$value.criteria_verified; findings=@(@($value.findings) | ForEach-Object { $v=Safe-PublicText ([string]$_); if($null -ne $v){$v} }) }
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
$technicalEvidence = @()
$safeChangedFiles = @()
$redactions = @('absolute/private paths', 'authentication material', 'CAD payload files', 'raw execution logs')
if ($null -ne $source.PSObject.Properties['evidence'] -and $source.evidence -is [pscustomobject]) {
  $rawEvidence = $source.evidence
  foreach ($name in @('diagnostic_type','native_brep_validation','correction_scope','known_metrics')) {
    if ($null -ne $rawEvidence.PSObject.Properties[$name]) {
      $value = $rawEvidence.$name
      if ($value -is [string]) { $safe = Safe-PublicText $value; if ($null -ne $safe) { $technicalEvidence += [ordered]@{ kind=$name; value=$safe } } }
      elseif ($value -is [ValueType] -or $value -is [bool]) { $technicalEvidence += [ordered]@{ kind=$name; value=$value } }
      else { $technicalEvidence += [ordered]@{ kind=$name; value=$value } }
    }
  }
  if ($null -ne $rawEvidence.PSObject.Properties['changed_files']) {
    $safeChangedFiles = @($rawEvidence.changed_files | ForEach-Object { Safe-PublicPath ([string]$_) } | Where-Object { $null -ne $_ })
    if ($safeChangedFiles.Count -gt 0) { $technicalEvidence += [ordered]@{ kind='changed-files'; value=$safeChangedFiles } }
  }
  if ($null -ne $rawEvidence.PSObject.Properties['tests']) {
    $tests = @($rawEvidence.tests | ForEach-Object {
      if ($null -eq $_.command -or $null -eq $_.exitCode) { return }
      $command = Safe-PublicText ([string]$_.command) 500
      if ($null -eq $command) { return }
      $item = [ordered]@{ command=$command; exit_code=[int]$_.exitCode }
      if ($null -ne $_.durationMs) { $item.duration_ms=[double]$_.durationMs }
      $item
    })
    if ($tests.Count -gt 0) { $technicalEvidence += [ordered]@{ kind='test-results'; value=$tests } }
  }
  if ($null -ne $rawEvidence.PSObject.Properties['native_tests']) {
    $nativeCases = @($rawEvidence.native_tests | ForEach-Object {
      if ($null -eq $_.case -or $null -eq $_.valid -or $null -eq $_.topology -or $null -eq $_.measured_axial) { return }
      $case = [ordered]@{
        case = Safe-PublicText ([string]$_.case) 100
        valid = [bool]$_.valid
        topology = [bool]$_.topology
        measured_axial = [double]$_.measured_axial
      }
      foreach ($name in @('radius','lower','upper','measured_radius_error')) {
        if ($null -ne $_.PSObject.Properties[$name]) { $case[$name] = [double]($_.$name) }
      }
      $case
    })
    if ($nativeCases.Count -gt 0) { $technicalEvidence += [ordered]@{ kind='native-brep-cases'; value=$nativeCases } }
  }
  if ($null -ne $rawEvidence.PSObject.Properties['native_exit_codes']) {
    $nativeExitCodes = [ordered]@{}
    foreach ($property in $rawEvidence.native_exit_codes.PSObject.Properties) {
      if ($property.Name -match '^[A-Za-z0-9_.-]+$') {
        $publicName = $property.Name -replace '(?i)\.exe$',''
        $nativeExitCodes[$publicName] = [int]$property.Value
      }
    }
    if ($nativeExitCodes.Count -gt 0) { $technicalEvidence += [ordered]@{ kind='native-exit-codes'; value=$nativeExitCodes } }
  }
  if ($null -ne $rawEvidence.PSObject.Properties['flutter_tests']) {
    $flutterEvidence = @($rawEvidence.flutter_tests | ForEach-Object {
      if ($null -eq $_.command -or $null -eq $_.exitCode) { return }
      $command = Safe-PublicText ([string]$_.command) 500
      if ($null -eq $command) { return }
      $item = [ordered]@{ command=$command; exit_code=[int]$_.exitCode }
      foreach ($name in @('durationMs','diameter','rms','c2_ms','c3_ms','testsPassed')) {
        if ($null -ne $_.PSObject.Properties[$name]) { $item[$name] = $_.$name }
      }
      if ($null -ne $_.PSObject.Properties['status']) { $item.status = Safe-PublicText ([string]$_.status) 100 }
      $item
    })
    if ($flutterEvidence.Count -gt 0) { $technicalEvidence += [ordered]@{ kind='flutter-results'; value=$flutterEvidence } }
  }
}
$reviewObject = Read-Review $Review
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
  files_changed = $safeChangedFiles
  limitations = @('AB-01 whitelist permanece ativa; não há execução geral de implementação.', 'Pacote não contém logs brutos, credenciais ou conteúdo privado.')
  evidence = $evidence
  technical_evidence = $technicalEvidence
  redactions = $redactions
  review_decision = $reviewObject
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
$reviewTemplate = Read-Json (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'review-template.json')
$reviewPayload = [pscustomobject]@{
  schema_version = '1.0'
  task_id = $taskId
  report_sha256 = Hash $reportPath
  review_status = [string]$reviewTemplate.review_status
  reviewer = [string]$reviewTemplate.reviewer
  tests_decision = [string]$reviewTemplate.tests_decision
  risk_decision = [string]$reviewTemplate.risk_decision
  acceptance_decision = [string]$reviewTemplate.acceptance_decision
  findings = @($reviewTemplate.findings)
  required_actions = @($reviewTemplate.required_actions)
  reviewed_at = [string]$reviewTemplate.reviewed_at
}
[IO.File]::WriteAllText($reviewPath, (ConvertTo-Json -InputObject $reviewPayload -Depth 8), [Text.UTF8Encoding]::new($false))
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
