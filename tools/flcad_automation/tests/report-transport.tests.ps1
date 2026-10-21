$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$publisher = Join-Path $root 'publish-report.ps1'
$sandbox = Join-Path $env:TEMP ('flcad-ab04b-f1-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $sandbox 'package'; $repo = Join-Path $sandbox 'repo'; $remote = Join-Path $sandbox 'remote.git'
New-Item -ItemType Directory -Force -Path $package | Out-Null
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw "ASSERTION FAILED: $Message"}}
function Write-Json([string]$Path,[object]$Object){$Object|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding UTF8}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function New-Package([string]$Target,[string]$Objective='synthetic safe report',[string]$TaskId='AB04B-F1-DEMO'){
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  $report=[ordered]@{schema_version='1.0';task_id=$TaskId;lifecycle_status='prepared-for-publication';branch='automation/flcad-bridge';head=('a'*40);objective=$Objective;acceptance_criteria=@('safe transport');execution_status='completed';tests=@{passed=@('local');failed=@();not_run=@()};duration_ms=1;files_changed=@();limitations=@('no raw logs');evidence=@(@{kind='source-report';label='synthetic';sha256=('b'*64)});next_step='human review'}
  $review=[ordered]@{schema_version='1.0';task_id=$TaskId;report_sha256='';review_status='awaiting-review';reviewer='operator';tests_decision='insufficient';risk_decision='mitigate';acceptance_decision='pending';findings=@();required_actions=@()}
  $transport=[ordered]@{status='prepared-for-publication';simulated=$true;publish_performed=$false;push_performed=$false}
  Write-Json (Join-Path $Target 'report.json') $report; $review.report_sha256=Hash (Join-Path $Target 'report.json'); Write-Json (Join-Path $Target 'review-request.json') $review; Write-Json (Join-Path $Target 'transport.json') $transport
  $entries=@(); foreach($name in @('report.json','review-request.json','transport.json')){$entries += [ordered]@{name=$name;bytes=(Get-Item (Join-Path $Target $name)).Length;sha256=(Hash (Join-Path $Target $name))}}
  Write-Json (Join-Path $Target 'manifest.json') ([ordered]@{schema_version='1.0';task_id=$TaskId;package_status='prepared-for-publication';files=$entries;integrity='sha256'})
}
function Run-Rejected([string]$Pkg,[string]$Version='2'){$old=$ErrorActionPreference;$ErrorActionPreference='Continue';& powershell -NoProfile -ExecutionPolicy Bypass -File $publisher -Package $Pkg -Worktree $repo -Branch automation/reports -Version $Version 2>&1|Out-Null;$code=$LASTEXITCODE;$ErrorActionPreference=$old;Assert-True($code -ne 0)'invalid package must be rejected'}
try {
  git init --bare $remote | Out-Null; git init $repo | Out-Null; git -C $repo config user.email test@example.invalid; git -C $repo config user.name 'FLCAD Test'; git -C $repo remote add origin $remote; git -C $repo switch -c automation/reports | Out-Null
  New-Package $package
  $first=& powershell -NoProfile -ExecutionPolicy Bypass -File $publisher -Package $package -Worktree $repo -Branch automation/reports -Version 1 | ConvertFrom-Json
  Assert-True($first.status -eq 'prepared-for-publication')'first publication should be prepared'
  $dest=Join-Path $repo 'reports/AB04B-F1-DEMO/v1';$public=@(Get-ChildItem $dest -File);Assert-True($public.Count -eq 3)'public package must have three files';Assert-True(@($public.Name|Where-Object{$_ -notin @('report.json','review-request.json','manifest.json')}).Count -eq 0)'public names are exact'
  $pm=Get-Content (Join-Path $dest 'manifest.json') -Raw|ConvertFrom-Json;$names=@($pm.files|ForEach-Object{[string]$_.name});Assert-True($names.Count -eq 2)'public manifest must have two entries';Assert-True(@($names|Where-Object{$_ -notin @('report.json','review-request.json')}).Count -eq 0)'transport must not be public';foreach($entry in $pm.files){Assert-True($entry.sha256 -eq (Hash (Join-Path $dest $entry.name)))"public hash $($entry.name) must match bytes"}
  git -C $repo add -- reports/AB04B-F1-DEMO/v1/report.json reports/AB04B-F1-DEMO/v1/review-request.json reports/AB04B-F1-DEMO/v1/manifest.json; git -C $repo commit -m 'test: publish sanitized report' | Out-Null
  $replay=& powershell -NoProfile -ExecutionPolicy Bypass -File $publisher -Package $package -Worktree $repo -Branch automation/reports -Version 1 | ConvertFrom-Json;Assert-True($replay.status -eq 'idempotent')'identical replay must be idempotent'
  $bad=Join-Path $sandbox 'bad-sha';New-Package $bad; $badManifest=Get-Content (Join-Path $bad 'manifest.json') -Raw|ConvertFrom-Json;$badManifest.files[0].sha256=('c'*64);Write-Json (Join-Path $bad 'manifest.json') $badManifest;Run-Rejected $bad
  $bad=Join-Path $sandbox 'duplicate';New-Package $bad; $dup=Get-Content (Join-Path $bad 'manifest.json') -Raw|ConvertFrom-Json;$dup.files=@($dup.files[0],$dup.files[0],$dup.files[2]);Write-Json (Join-Path $bad 'manifest.json') $dup;Run-Rejected $bad
  $bad=Join-Path $sandbox 'unknown';New-Package $bad; $unk=Get-Content (Join-Path $bad 'manifest.json') -Raw|ConvertFrom-Json;$unk.files[2].name='unknown.json';Write-Json (Join-Path $bad 'manifest.json') $unk;Run-Rejected $bad
  $bad=Join-Path $sandbox 'missing';New-Package $bad; $mis=Get-Content (Join-Path $bad 'manifest.json') -Raw|ConvertFrom-Json;$mis.files=@($mis.files[0],$mis.files[1]);Write-Json (Join-Path $bad 'manifest.json') $mis;Run-Rejected $bad
  $bad=Join-Path $sandbox 'extra';New-Package $bad;Set-Content (Join-Path $bad 'extra.json') '{}' -Encoding UTF8;Run-Rejected $bad
  $bad=Join-Path $sandbox 'private';New-Package $bad 'C:\Users\private\client.stl';Run-Rejected $bad
  $bad=Join-Path $sandbox 'traversal';New-Package $bad; $trav=Get-Content (Join-Path $bad 'report.json') -Raw|ConvertFrom-Json;$trav.task_id='../escape';Write-Json (Join-Path $bad 'report.json') $trav;Run-Rejected $bad
  $partial=Join-Path $repo 'reports/AB04B-F1-DEMO/v2';New-Item -ItemType Directory -Force -Path $partial|Out-Null;Set-Content (Join-Path $partial 'unexpected.txt') 'sentinel';Run-Rejected $package '2';Assert-True((Test-Path (Join-Path $partial 'unexpected.txt')))'failed publication must preserve destination';Remove-Item -LiteralPath $partial -Recurse -Force
  Assert-True([string]::IsNullOrWhiteSpace((git -C $repo status --porcelain)))'no partial files may remain'
  Write-Output 'report-transport.tests.ps1: PASS'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
