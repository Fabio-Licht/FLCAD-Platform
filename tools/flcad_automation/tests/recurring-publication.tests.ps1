$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exporter = Join-Path $root 'export-report.ps1'
$batch = Join-Path $root 'publish-reports.ps1'
$runtime = 'C:\Users\fabio\AppData\Local\FLCAD\automation-bridge-runtime'
$sourceReport = Join-Path $runtime 'reports\AB08C-occt-validation.json'
$sourceReview = Join-Path $runtime 'reviews\AB08C-occt-validation.json'
$sandbox = Join-Path $env:TEMP ('flcad-ab09c-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $sandbox 'repo'; $remote = Join-Path $sandbox 'remote.git'; $outbox = Join-Path $sandbox 'outbox'; $task = Join-Path $sandbox 'task.json'; $policyPath = Join-Path $sandbox 'policy.json'
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw "ASSERTION FAILED: $Message"}}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
try {
  New-Item -ItemType Directory -Force -Path $sandbox,$outbox | Out-Null
  $source = Get-Content -LiteralPath $sourceReport -Raw | ConvertFrom-Json
  $taskObject = [ordered]@{id=$source.taskId;objective=$source.task.objective;sourceBranch=$source.task.sourceBranch;baseCommit=$source.task.baseCommit;acceptanceCriteria=@($source.task.acceptanceCriteria);requiredTests=@($source.task.requiredTests)}
  $taskObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $task -Encoding UTF8
  $exportResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exporter -Report $sourceReport -Task $task -Review $sourceReview -Worktree 'C:\flcad_mobile' -OutDir $outbox -SimulatePublication | ConvertFrom-Json
  Assert-True ($exportResult.task_id -eq 'AB08C-ER-P2C-OCCT-VALIDATION') 'AB-08C package must be exported'
  $package = Join-Path $outbox $exportResult.task_id
  $report = Get-Content (Join-Path $package 'report.json') -Raw | ConvertFrom-Json
  Assert-True (@($report.files_changed).Count -eq 4) 'files_changed must match sanitized changed_files'
  $kinds = @($report.technical_evidence | ForEach-Object {[string]$_.kind})
  Assert-True ($kinds -contains 'native-brep-cases') 'native BRep cases must be included'
  Assert-True ($kinds -contains 'flutter-results') 'Flutter metrics must be included'
  Assert-True ($report.execution_status -eq 'completed') 'AB-08C status must remain completed'

  git init --bare $remote | Out-Null; git init $repo | Out-Null
  git -C $repo config user.email test@example.invalid; git -C $repo config user.name 'FLCAD Test'
  git -C $repo remote add origin $remote; git -C $repo switch -c automation/reports | Out-Null
  Set-Content -LiteralPath (Join-Path $repo '.keep') -Value 'base' -Encoding UTF8
  git -C $repo add .keep; git -C $repo commit -m 'base' | Out-Null; git -C $repo push origin automation/reports | Out-Null
  $policy = [ordered]@{schema_version='1.0';policy_id='test-policy';enabled=$true;destination_branch='automation/reports';allowed_files=@('report.json','review-request.json','manifest.json');max_packages_per_run=2;max_total_bytes=10485760;max_package_bytes=2097152;push_mode='operator-authorized-only';push_enabled=$false}
  $policy | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $policyPath -Encoding UTF8
  $prepared = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batch -Command Prepare -Outbox $outbox -Worktree $repo -Policy $policyPath | ConvertFrom-Json
  Assert-True ($prepared.status -eq 'prepared-for-publication') 'batch must prepare eligible package'
  $destination = Join-Path $repo 'reports\AB08C-ER-P2C-OCCT-VALIDATION\v1'
  Assert-True ((Get-ChildItem -LiteralPath $destination -File).Count -eq 3) 'public destination must contain exactly three files'
  $replay = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batch -Command Prepare -Outbox $outbox -Worktree $repo -Policy $policyPath | ConvertFrom-Json
  Assert-True ($replay.packages[0].status -eq 'idempotent') 'replay must be idempotent'
  $bad = Join-Path $repo 'unexpected.txt'; Set-Content -LiteralPath $bad -Value 'dirty' -Encoding UTF8
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batch -Command Prepare -Outbox $outbox -Worktree $repo -Policy $policyPath *> $null; $code=$LASTEXITCODE;$ErrorActionPreference=$old
  Assert-True ($code -ne 0) 'unexpected worktree content must stop recurring publication'
  Remove-Item -LiteralPath $bad -Force
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batch -Command Prepare -Outbox $outbox -Worktree $repo -Policy $policyPath -AuthorizePush *> $null; $code=$LASTEXITCODE;$ErrorActionPreference=$old
  Assert-True ($code -ne 0) 'push must remain disabled until policy authorization'
  Write-Output 'recurring-publication.tests.ps1: PASS'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
