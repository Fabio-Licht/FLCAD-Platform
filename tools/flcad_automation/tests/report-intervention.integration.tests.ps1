$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'prepare-report-intervention.ps1'
$tmp = Join-Path $env:TEMP ('flcad-ab04c-f2-integrated-' + [guid]::NewGuid().ToString('N'))
$pub1 = Join-Path $tmp 'published-1'
$pub2 = Join-Path $tmp 'published-2'
New-Item -ItemType Directory -Force $pub1, $pub2 | Out-Null

function Write-Json($Path, $Object) { $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Hash-File($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Invoke-Reject([array]$Arguments, [string]$Message) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe @Arguments 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    Assert-True ($code -ne 0) $Message
}
function New-PublicFixture([string]$Target, [string]$TaskId, [string]$Head, [string]$WorkBranch) {
    New-Item -ItemType Directory -Force $Target | Out-Null
    $report = [ordered]@{
        schema_version = '1.0'; task_id = $TaskId; lifecycle_status = 'prepared-for-publication'
        branch = $WorkBranch; head = $Head; objective = 'integrated'; acceptance_criteria = @('verify')
        execution_status = 'completed'; tests = @{ passed = @('local'); failed = @(); not_run = @() }
        duration_ms = 1; files_changed = @(); limitations = @('demo'); evidence = @(); next_step = 'review'
    }
    $reportPath = Join-Path $Target 'report.json'
    Write-Json $reportPath $report
    $review = [ordered]@{
        schema_version = '1.0'; task_id = $TaskId; report_sha256 = Hash-File $reportPath
        analyzed_commit = $Head; decision = 'HUMAN_REVIEW_REQUIRED'; reviewer = 'pending'
        findings = @(); required_actions = @()
    }
    $reviewPath = Join-Path $Target 'review-request.json'
    Write-Json $reviewPath $review
    $manifest = [ordered]@{
        schema_version = '1.0'; task_id = $TaskId; version = 1; manifest_scope = 'public'
        files = @(
            [ordered]@{ name = 'report.json'; bytes = (Get-Item $reportPath).Length; sha256 = Hash-File $reportPath },
            [ordered]@{ name = 'review-request.json'; bytes = (Get-Item $reviewPath).Length; sha256 = Hash-File $reviewPath }
        ); integrity = 'sha256'
    }
    Write-Json (Join-Path $Target 'manifest.json') $manifest
}
function New-Classification([string]$Path, [string]$TaskId) {
    Write-Json $Path ([ordered]@{
        schema_version = '1.0'; task_id = $TaskId; classification = 'WAITING_FOR_USER'
        notification_required = $true; event = 'USER_TEST_REQUIRED'; reason = 'professional test required'
        action_requested = 'Perform professional test'
    })
}
function New-Args([string]$Published, [string]$OutDir, [string]$TaskId, [string]$ClassPath, [string]$Work) {
    @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-ReportRoot',$Published,'-TaskId',$TaskId,
        '-Version','1','-ReportUrl',("https://github.com/Fabio-Licht/FLCAD-Platform/blob/automation/reports/reports/{0}/v1/report.json" -f $TaskId),
        '-Classification',$ClassPath,'-Worktree',$Work,'-OutDir',$OutDir)
}
$work = (Resolve-Path (Join-Path $root '....')).Path
$branch = (git -C $work branch --show-current).Trim()
$head = (git -C $work rev-parse HEAD).Trim()
$class1 = Join-Path $tmp 'class-1.json'
$class2 = Join-Path $tmp 'class-2.json'
New-PublicFixture $pub1 'INTEGRATED-DEMO' $head $branch
New-PublicFixture $pub2 'INTEGRATED-DEMO-2' $head $branch
New-Classification $class1 'INTEGRATED-DEMO'
New-Classification $class2 'INTEGRATED-DEMO-2'
$out = Join-Path $tmp 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$base1 = New-Args $pub1 $out 'INTEGRATED-DEMO' $class1 $work
$base2 = New-Args $pub2 $out 'INTEGRATED-DEMO-2' $class2 $work

try {
    $first = & powershell.exe @base1 | ConvertFrom-Json
    Assert-True ($first.status -eq 'prepared-for-publication') 'first intervention must prepare'
    $oneFile = Join-Path $out 'INTEGRATED-DEMO.v1.USER_TEST_REQUIRED.json'
    Assert-True (Test-Path $oneFile) 'intervention file missing'
    Assert-True ((Get-Content $oneFile -Raw | ConvertFrom-Json).event -eq 'USER_TEST_REQUIRED') 'wrong event'
    $replay = & powershell.exe @base1 | ConvertFrom-Json
    Assert-True ($replay.status -eq 'deduplicated') 'identical replay must deduplicate'
    $conflictClass = Join-Path $tmp 'class-conflict.json'
    New-Classification $conflictClass 'INTEGRATED-DEMO'
    $conflictObject = Get-Content $conflictClass -Raw | ConvertFrom-Json
    $conflictObject.reason = 'different payload'
    Write-Json $conflictClass $conflictObject
    Invoke-Reject (New-Args $pub1 $out 'INTEGRATED-DEMO' $conflictClass $work) 'conflicting replay must be rejected'

    $activeOut = Join-Path $tmp 'active-lock'
    New-Item -ItemType Directory -Force $activeOut | Out-Null
    $owner = Get-Process -Id $PID
    Write-Json (Join-Path $activeOut '.report-intervention.lock') ([ordered]@{ pid = $PID; start_ticks = $owner.StartTime.ToUniversalTime().Ticks; created_at = [datetime]::UtcNow.ToString('o') })
    Invoke-Reject (New-Args $pub1 $activeOut 'INTEGRATED-DEMO' $class1 $work) 'active lock must block a second process'
    Assert-True (Test-Path (Join-Path $activeOut '.report-intervention.lock')) 'active lock must be preserved'

    $badLockOut = Join-Path $tmp 'bad-lock'
    New-Item -ItemType Directory -Force $badLockOut | Out-Null
    '{malformed' | Set-Content (Join-Path $badLockOut '.report-intervention.lock') -Encoding UTF8
    Invoke-Reject (New-Args $pub1 $badLockOut 'INTEGRATED-DEMO' $class1 $work) 'malformed lock must require human recovery'
    Assert-True (Test-Path (Join-Path $badLockOut '.report-intervention.lock')) 'malformed lock must be preserved'

    $staleOut = Join-Path $tmp 'stale-lock'
    New-Item -ItemType Directory -Force $staleOut | Out-Null
    Write-Json (Join-Path $staleOut '.report-intervention.lock') ([ordered]@{ pid = 2147483647; start_ticks = 1; created_at = [datetime]::UtcNow.ToString('o') })
    $staleResult = & powershell.exe @(New-Args $pub1 $staleOut 'INTEGRATED-DEMO' $class1 $work) | ConvertFrom-Json
    Assert-True ($staleResult.status -eq 'prepared-for-publication') 'owner-absent lock may be recovered safely'
    Assert-True (-not (Test-Path (Join-Path $staleOut '.report-intervention.lock'))) 'recovered lock must be cleaned after completion'

    $orphanOut = Join-Path $tmp 'orphan'
    New-Item -ItemType Directory -Force $orphanOut | Out-Null
    '{}' | Set-Content (Join-Path $orphanOut 'INTEGRATED-DEMO.v1.USER_TEST_REQUIRED.json') -Encoding UTF8
    Invoke-Reject (New-Args $pub1 $orphanOut 'INTEGRATED-DEMO' $class1 $work) 'orphan intervention must block continuation'
    Assert-True (Test-Path (Join-Path $orphanOut 'INTEGRATED-DEMO.v1.USER_TEST_REQUIRED.json')) 'orphan must not be overwritten'

    $corruptOut = Join-Path $tmp 'corrupt-index'
    New-Item -ItemType Directory -Force $corruptOut | Out-Null
    '{not-json' | Set-Content (Join-Path $corruptOut 'report-intervention-index.json') -Encoding UTF8
    Invoke-Reject (New-Args $pub1 $corruptOut 'INTEGRATED-DEMO' $class1 $work) 'corrupt index must block continuation'
    Assert-True ((Get-Content (Join-Path $corruptOut 'report-intervention-index.json') -Raw) -match 'not-json') 'corrupt index must remain unchanged'

    $p1 = Join-Path $tmp 'same-1.out'; $p2 = Join-Path $tmp 'same-2.out'
    $e1 = Join-Path $tmp 'same-1.err'; $e2 = Join-Path $tmp 'same-2.err'
    $j1 = Start-Process powershell.exe -ArgumentList $base1 -RedirectStandardOutput $p1 -RedirectStandardError $e1 -PassThru
    $j2 = Start-Process powershell.exe -ArgumentList $base1 -RedirectStandardOutput $p2 -RedirectStandardError $e2 -PassThru
    Wait-Process -Id $j1.Id, $j2.Id
    Assert-True ($j1.HasExited -and $j2.HasExited) 'same-id processes must exit'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-Content $e1 -Raw)) -and [string]::IsNullOrWhiteSpace((Get-Content $e2 -Raw))) 'same-id processes must not error'
    Assert-True ((Get-Content $p1 -Raw) -match 'status' -and (Get-Content $p2 -Raw) -match 'status') 'same-id results must be emitted'
    $indexPath = Join-Path $out 'report-intervention-index.json'
    $index = Get-Content $indexPath -Raw | ConvertFrom-Json
    Assert-True (@($index.entries | Where-Object { $_.deduplication_id -eq 'INTEGRATED-DEMO.v1.USER_TEST_REQUIRED' }).Count -eq 1) 'same-id dedup must keep one entry'

    $distinctOut = Join-Path $tmp 'distinct'
    New-Item -ItemType Directory -Force $distinctOut | Out-Null
    $distinct1 = New-Args $pub1 $distinctOut 'INTEGRATED-DEMO' $class1 $work
    $distinct2 = New-Args $pub2 $distinctOut 'INTEGRATED-DEMO-2' $class2 $work
    $q1 = Start-Process powershell.exe -ArgumentList $distinct1 -RedirectStandardOutput (Join-Path $tmp 'distinct-1.txt') -RedirectStandardError (Join-Path $tmp 'distinct-1.err') -PassThru
    $q2 = Start-Process powershell.exe -ArgumentList $distinct2 -RedirectStandardOutput (Join-Path $tmp 'distinct-2.txt') -RedirectStandardError (Join-Path $tmp 'distinct-2.err') -PassThru
    Wait-Process -Id $q1.Id, $q2.Id
    Assert-True ($q1.HasExited -and $q2.HasExited) 'distinct-id processes must exit'
    $distinctErr1 = Get-Content (Join-Path $tmp 'distinct-1.err') -Raw
    $distinctErr2 = Get-Content (Join-Path $tmp 'distinct-2.err') -Raw
    Assert-True ([string]::IsNullOrWhiteSpace($distinctErr1) -and [string]::IsNullOrWhiteSpace($distinctErr2)) ("distinct-id processes must not error: {0} {1}" -f $distinctErr1, $distinctErr2)
    $distinctIndex = Get-Content (Join-Path $distinctOut 'report-intervention-index.json') -Raw | ConvertFrom-Json
    Assert-True (@($distinctIndex.entries).Count -eq 2) 'distinct IDs must both be recorded'

    $stale = Join-Path $tmp 'stale-report'; Copy-Item $pub1 $stale -Recurse
    $staleReport = Get-Content (Join-Path $stale 'report.json') -Raw | ConvertFrom-Json
    $staleReport.head = 'a' * 40
    Write-Json (Join-Path $stale 'report.json') $staleReport
    $staleReview = Get-Content (Join-Path $stale 'review-request.json') -Raw | ConvertFrom-Json
    $staleReview.report_sha256 = Hash-File (Join-Path $stale 'report.json')
    $staleReview.analyzed_commit = $staleReport.head
    Write-Json (Join-Path $stale 'review-request.json') $staleReview
    $staleManifest = Get-Content (Join-Path $stale 'manifest.json') -Raw | ConvertFrom-Json
    $staleManifest.files[0].bytes = (Get-Item (Join-Path $stale 'report.json')).Length
    $staleManifest.files[0].sha256 = Hash-File (Join-Path $stale 'report.json')
    $staleManifest.files[1].bytes = (Get-Item (Join-Path $stale 'review-request.json')).Length
    $staleManifest.files[1].sha256 = Hash-File (Join-Path $stale 'review-request.json')
    Write-Json (Join-Path $stale 'manifest.json') $staleManifest
    Invoke-Reject (New-Args $stale $out 'INTEGRATED-DEMO' $class1 $work) 'stale report must be rejected'

    $invalid = Join-Path $tmp 'invalid-manifest'; Copy-Item $pub1 $invalid -Recurse
    $invalidManifest = Get-Content (Join-Path $invalid 'manifest.json') -Raw | ConvertFrom-Json
    $invalidManifest.files[0].sha256 = '0' * 64
    Write-Json (Join-Path $invalid 'manifest.json') $invalidManifest
    Invoke-Reject (New-Args $invalid $out 'INTEGRATED-DEMO' $class1 $work) 'invalid manifest must be rejected'
    Write-Output 'report-intervention.integration.tests.ps1: PASS'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
