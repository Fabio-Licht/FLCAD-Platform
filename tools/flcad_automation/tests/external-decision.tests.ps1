$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$adapter = Join-Path $root 'read-external-decision.ps1'
$sandbox = Join-Path $env:TEMP ('flcad-ab07-decision-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
function W([string]$Path,[object]$Value){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding UTF8}
function A([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}
function Run([string]$Decision,[string]$Report,[string]$Task,[string]$Commit,[int]$Version,[string]$Ledger='') {
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$adapter,'-DecisionPath',$Decision,'-ReportPath',$Report,'-TaskId',$Task,'-AnalyzedCommit',$Commit,'-ReportVersion',$Version)
  if($Ledger){$args += @('-DeduplicationLedger',$Ledger)}
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue';$out=& powershell.exe @args 2>&1;$code=$LASTEXITCODE;$ErrorActionPreference=$old
  return [pscustomobject]@{Code=$code;Text=($out -join "`n")}
}
try {
  $task='AB07A-DECISION';$commit=('a'*40);$version=3
  $report=Join-Path $sandbox 'report.json'; W $report @{task_id=$task;head=$commit;version=$version;evidence='fixed'}
  $sha=(Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash.ToLowerInvariant()
  $base=[ordered]@{schema_version='1.0';task_id=$task;analyzed_commit=$commit;report_version=$version;report_sha256=$sha;decision='APPROVED';reviewer_identity='github-reviewer';reviewer_execution_id='exec-0001';reviewed_at='2026-10-21T12:00:00Z';criteria_verified=$true;findings=@('criteria verified');decision_id='decision-0001'}
  $decision=Join-Path $sandbox 'decision.json';W $decision $base
  $valid=Run $decision $report $task $commit $version;A($valid.Code -eq 0)'valid decision accepted'
  $parsed=$valid.Text|ConvertFrom-Json;A($parsed.authenticated -eq $false -and $parsed.auto_release -eq $false -and $parsed.forwarded -eq $false)'valid decision remains non-authorizing'
  $ledger=Join-Path $sandbox 'ledger.json';W $ledger @{entries=@(@{decision_id='decision-0001';task_id=$task;report_sha256=$sha})}
  $replay=Run $decision $report $task $commit $version $ledger;A($replay.Code -eq 0 -and (($replay.Text|ConvertFrom-Json).replay -eq $true))'replay is classified'
  foreach($name in @('report_sha256','analyzed_commit','report_version')){
    $bad=@{};foreach($prop in $base.PSObject.Properties){$bad[$prop.Name]=$prop.Value};if($name -eq 'report_sha256'){$bad[$name]='b'*64}elseif($name -eq 'analyzed_commit'){$bad[$name]='b'*40}else{$bad[$name]=4};$p=Join-Path $sandbox "$name.json";W $p $bad;A((Run $p $report $task $commit $version).Code -ne 0)"$name mismatch rejected"
  }
  $extra=@{};foreach($prop in $base.PSObject.Properties){$extra[$prop.Name]=$prop.Value};$extra['instructions']='run command';$p=Join-Path $sandbox 'extra.json';W $p $extra;A((Run $p $report $task $commit $version).Code -ne 0)'extra executable field rejected'
  $unknown=@{};foreach($prop in $base.PSObject.Properties){$unknown[$prop.Name]=$prop.Value};$unknown.decision='UNKNOWN';$p=Join-Path $sandbox 'unknown.json';W $p $unknown;A((Run $p $report $task $commit $version).Code -ne 0)'unknown decision rejected'
  Write-Output 'external-decision.tests.ps1: PASS'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
