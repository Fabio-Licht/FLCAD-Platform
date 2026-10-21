$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$publisher = Join-Path $root 'publish-report.ps1'
$sandbox = Join-Path $env:TEMP ('flcad-ab04a-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $sandbox 'package'
$repo = Join-Path $sandbox 'repo'
$remote = Join-Path $sandbox 'remote.git'
New-Item -ItemType Directory -Force -Path $package | Out-Null
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw "ASSERTION FAILED: $Message"}}
function Write-Json([string]$Path,[object]$Object){$Object|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding UTF8}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function New-Package([string]$Target,[string]$Objective,[string]$TaskId='AB-04A-DEMO'){
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  $report=[ordered]@{schema_version='1.0';task_id=$TaskId;lifecycle_status='prepared-for-publication';branch='automation/flcad-bridge';head=('a'*40);objective=$Objective;acceptance_criteria=@('safe transport');execution_status='completed';tests=@{passed=@('local');failed=@();not_run=@()};duration_ms=1;files_changed=@();limitations=@('no raw logs');evidence=@(@{kind='source-report';label='synthetic';sha256=('b'*64)});next_step='human review';transport=@{status='prepared-for-publication';write_permission='not-verified'}}
  $review=[ordered]@{schema_version='1.0';task_id=$TaskId;report_sha256='';review_status='awaiting-review';reviewer='operator';tests_decision='insufficient';risk_decision='mitigate';acceptance_decision='pending';findings=@();required_actions=@()}
  $transport=[ordered]@{status='prepared-for-publication';simulated=$true;publish_performed=$false;push_performed=$false}
  Write-Json (Join-Path $Target 'report.json') $report; $review.report_sha256=Hash (Join-Path $Target 'report.json'); Write-Json (Join-Path $Target 'review-request.json') $review; Write-Json (Join-Path $Target 'transport.json') $transport
  $entries=@(); foreach($name in @('report.json','review-request.json','transport.json')){$entries += [ordered]@{name=$name;bytes=(Get-Item (Join-Path $Target $name)).Length;sha256=(Hash (Join-Path $Target $name))}}
  Write-Json (Join-Path $Target 'manifest.json') ([ordered]@{schema_version='1.0';task_id=$TaskId;package_status='prepared-for-publication';files=$entries;integrity='sha256'})
}
try {
  git init --bare $remote | Out-Null; git init $repo | Out-Null; git -C $repo config user.email test@example.invalid; git -C $repo config user.name 'FLCAD Test'; git -C $repo remote add origin $remote; git -C $repo switch -c automation/reports | Out-Null
  New-Package $package 'synthetic safe report'
  $first=& powershell -NoProfile -File $publisher -Package $package -Worktree $repo -Branch automation/reports -Version 1 | ConvertFrom-Json
  Assert-True ($first.status -eq 'prepared-for-publication') 'primeira publicação deve ser preparada'
  Assert-True (Test-Path (Join-Path $repo 'reports/AB-04A-DEMO/v1/report.json')) 'report não copiado'
  Assert-True ((@(Get-ChildItem (Join-Path $repo 'reports/AB-04A-DEMO/v1') -File)).Count -eq 3) 'somente três arquivos publicados devem existir'
  Assert-True ((@(git -C $repo status --porcelain | Where-Object { $_ -notmatch '^\?\? reports/$' })).Count -eq 0) 'nenhum caminho fora de reports deve estar pendente'
  git -C $repo add -- reports/AB-04A-DEMO/v1/report.json reports/AB-04A-DEMO/v1/review-request.json reports/AB-04A-DEMO/v1/manifest.json; git -C $repo commit -m 'test: publish sanitized report' | Out-Null
  $replay=& powershell -NoProfile -File $publisher -Package $package -Worktree $repo -Branch automation/reports -Version 1 | ConvertFrom-Json
  Assert-True ($replay.status -eq 'idempotent') 'replay idêntico deve ser idempotente'
  $conflict=Join-Path $sandbox 'conflict'; New-Package $conflict 'different objective'
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell -NoProfile -File $publisher -Package $conflict -Worktree $repo -Branch automation/reports -Version 1 2>&1|Out-Null;$code=$LASTEXITCODE;$ErrorActionPreference=$old;Assert-True($code -ne 0)'conflito de versão deve ser rejeitado'
  $bad=Join-Path $sandbox 'bad'; New-Package $bad 'C:\Users\fabio\private.stl'
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell -NoProfile -File $publisher -Package $bad -Worktree $repo -Branch automation/reports -Version 2 2>&1|Out-Null;$code=$LASTEXITCODE;$ErrorActionPreference=$old;Assert-True($code -ne 0)'conteúdo privado deve ser rejeitado'
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell -NoProfile -File $publisher -Package $package -Worktree $repo -Branch wrong-branch -Version 2 2>&1|Out-Null;$code=$LASTEXITCODE;$ErrorActionPreference=$old;Assert-True($code -ne 0)'branch divergente deve ser rejeitada'
  git -C $repo remote remove origin; $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell -NoProfile -File $publisher -Package $package -Worktree $repo -Branch automation/reports -Version 2 2>&1|Out-Null;$code=$LASTEXITCODE;$ErrorActionPreference=$old;Assert-True($code -ne 0)'ausência de autenticação/remoto deve ser rejeitada'
  Write-Output 'report-transport.tests.ps1: PASS'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
