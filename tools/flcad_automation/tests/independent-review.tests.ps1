$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$reviewer = Join-Path $root 'independent-review.ps1'
$sandbox = Join-Path $env:TEMP ('flcad-ab06-review-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
function Write-Json([string]$Path,[object]$Value){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding UTF8}
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}
try {
  $head=(git -C (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) rev-parse HEAD).Trim()
  $report=Join-Path $sandbox 'report.json'; $out=Join-Path $sandbox 'review.json'
  $value=[ordered]@{executorVersion='test';taskId='AB06B-REVIEW';action='environment';startedAt='2026-01-01T00:00:00Z';finishedAt='2026-01-01T00:00:01Z';durationMs=1;worktree=$sandbox;branch='automation/flcad-bridge';head=$head;exitCode=0;timedOut=$false;status='completed';task=@{id='AB06B-REVIEW'};details=@{criteria=@('report generated')}}
  Write-Json $report $value; $sha=(Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash
  $old=$ErrorActionPreference; $ErrorActionPreference='Continue'; $null=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reviewer -Report $report -TaskId AB06B-REVIEW -AnalyzedCommit $head -ReportSha256 $sha -OutFile $out 2>&1; $ErrorActionPreference=$old
  $code=$LASTEXITCODE; Assert-True ($code -eq 0) 'reviewer process should complete'; $review=Get-Content $out -Raw|ConvertFrom-Json
  Assert-True ($review.task_id -eq 'AB06B-REVIEW') 'review must bind task'; Assert-True ($review.report_sha256 -eq $sha) 'review must bind SHA'; Assert-True ($review.analyzed_commit -eq $head) 'review must bind commit'; Assert-True ($review.reviewer_execution_id.Length -gt 0) 'review must identify execution'
  $badOut=Join-Path $sandbox 'bad-review.json'; $old=$ErrorActionPreference; $ErrorActionPreference='Continue'; $null=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reviewer -Report $report -TaskId AB06B-REVIEW -AnalyzedCommit $head -ReportSha256 ('0'*64) -OutFile $badOut 2>&1; $badCode=$LASTEXITCODE; $ErrorActionPreference=$old; Assert-True ($badCode -ne 0) 'bad SHA must be rejected'
  Write-Output "independent-review.tests.ps1: PASS decision=$($review.decision)"
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
