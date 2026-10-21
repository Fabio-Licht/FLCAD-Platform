[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Package,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [string] $Branch = 'automation/reports',
  [ValidateRange(1, 9999)] [int] $Version = 1
)

$ErrorActionPreference = 'Stop'
function Fail([string] $Message) { throw "AB-04B-F1 report transport rejected: $Message" }
function Read-Json([string] $Path) { try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { Fail "invalid JSON: $([IO.Path]::GetFileName($Path))" } }
function Hash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-Hash([string] $Value, [string] $Name) { if ($Value -notmatch '^[0-9a-fA-F]{64}$') { Fail "$Name is not a valid SHA-256" } }
function Git-Run([string[]] $Arguments, [string] $Root) { $out = & git -C $Root @Arguments 2>&1; [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim() } }
function Assert-SafeId([string] $Value, [string] $Name) { if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail "$Name is invalid" } }
function Assert-NoPrivate([string] $Text, [string] $Name) {
  if ($Text -match '(?i)(ghp_[A-Za-z0-9]|github_pat_[A-Za-z0-9]|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|token\s*[:=]|password\s*[:=]|secret\s*[:=]|api[_-]?key\s*[:=]|authorization\s*[:=]|bearer\s+|C:\\Users\\|[A-Za-z]:\\\\|\\\\\\\\|file://|\.(stl|step|stp|iges|igs|dxf|dwg|pdb|dll|exe|log)\b)') { Fail "$Name contains private or credential content" }
}

$packageRoot = (Resolve-Path -LiteralPath $Package).Path
$worktreeRoot = (Resolve-Path -LiteralPath $Worktree).Path
$branchResult = Git-Run @('branch','--show-current') $worktreeRoot
if ($branchResult.Code -ne 0 -or $branchResult.Text -ne $Branch) { Fail 'branch mismatch' }
$statusBefore = Git-Run @('status','--porcelain') $worktreeRoot
if ($statusBefore.Code -ne 0 -or -not [string]::IsNullOrWhiteSpace($statusBefore.Text)) { Fail 'transport worktree must be clean' }
$remote = Git-Run @('remote','get-url','origin') $worktreeRoot
if ($remote.Code -ne 0 -or [string]::IsNullOrWhiteSpace($remote.Text)) { Fail 'origin is not configured' }

$allowedLocal = @('report.json','review-request.json','manifest.json','transport.json')
$packageFiles = @(Get-ChildItem -LiteralPath $packageRoot -File)
if ($packageFiles.Count -ne 4 -or @($packageFiles | Where-Object { $_.Name -notin $allowedLocal }).Count -gt 0 -or @($packageFiles.Name | Select-Object -Unique).Count -ne 4) { Fail 'local package must contain exactly four files' }
foreach ($file in $packageFiles) { if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'symbolic links are not accepted' }; Assert-NoPrivate (Get-Content -LiteralPath $file.FullName -Raw) $file.Name }

$reportPath = Join-Path $packageRoot 'report.json'; $reviewPath = Join-Path $packageRoot 'review-request.json'; $localManifestPath = Join-Path $packageRoot 'manifest.json'; $transportPath = Join-Path $packageRoot 'transport.json'
$report = Read-Json $reportPath; $review = Read-Json $reviewPath; $localManifest = Read-Json $localManifestPath; [void](Read-Json $transportPath)
$requiredReport = @('schema_version','task_id','lifecycle_status','branch','head','objective','acceptance_criteria','execution_status','tests','duration_ms','files_changed','limitations','evidence','next_step')
foreach ($field in $requiredReport) { if ($null -eq $report.PSObject.Properties[$field]) { Fail "report.json missing $field" } }
Assert-SafeId ([string]$report.task_id) 'task_id'
if ($report.schema_version -ne '1.0' -or $report.lifecycle_status -ne 'prepared-for-publication') { Fail 'report is not prepared for publication' }
if ($report.head -notmatch '^[0-9a-fA-F]{40}$') { Fail 'report commit is invalid' }
if ($report.execution_status -notin @('completed','failed','timed-out','cancelled')) { Fail 'execution_status is invalid' }
if ($null -eq $review.PSObject.Properties['task_id'] -or $review.task_id -ne $report.task_id) { Fail 'review task_id mismatch' }
Assert-Hash ([string]$review.report_sha256) 'review report_sha256'
if ($review.report_sha256 -ne (Hash $reportPath)) { Fail 'review report hash mismatch' }
if ($null -eq $localManifest.PSObject.Properties['task_id'] -or $localManifest.task_id -ne $report.task_id) { Fail 'local manifest task_id mismatch' }
$localNames = @($localManifest.files | ForEach-Object { [string]$_.name })
if ($localNames.Count -ne 3 -or @($localNames | Select-Object -Unique).Count -ne 3 -or @($localNames | Where-Object { $_ -notin @('report.json','review-request.json','transport.json') }).Count -gt 0) { Fail 'local manifest must reference report, review and transport' }
foreach ($entry in @($localManifest.files)) { Assert-Hash ([string]$entry.sha256) "local hash $($entry.name)"; $source = Join-Path $packageRoot $entry.name; if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or $entry.sha256 -ne (Hash $source)) { Fail "local hash mismatch: $($entry.name)" } }
Assert-NoPrivate (Get-Content -LiteralPath $reportPath -Raw) 'report.json'; Assert-NoPrivate (Get-Content -LiteralPath $reviewPath -Raw) 'review-request.json'

$destinationRelative = (Join-Path (Join-Path 'reports' ([string]$report.task_id)) "v$Version") -replace '\\','/'
$destinationRoot = Join-Path $worktreeRoot $destinationRelative
$publishFiles = @('report.json','review-request.json','manifest.json')
$publicManifest = [ordered]@{ schema_version='1.0'; task_id=[string]$report.task_id; version=$Version; manifest_scope='public'; files=@([ordered]@{name='report.json';bytes=(Get-Item -LiteralPath $reportPath).Length;sha256=(Hash $reportPath)},[ordered]@{name='review-request.json';bytes=(Get-Item -LiteralPath $reviewPath).Length;sha256=(Hash $reviewPath)}); integrity='sha256' }
$stageRoot = Join-Path $worktreeRoot ('.flcad-report-stage-' + [guid]::NewGuid().ToString('N'))
$stageMoved = $false
try {
  if (Test-Path -LiteralPath $destinationRoot) {
    if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) { Fail 'existing destination is not a directory' }
    $existing = @(Get-ChildItem -LiteralPath $destinationRoot -File -ErrorAction SilentlyContinue)
    if ($existing.Count -ne 3 -or @($existing | Where-Object { $_.Name -notin $publishFiles }).Count -gt 0) { Fail 'existing destination is not exactly the public package' }
    $tempManifest = Join-Path $env:TEMP ('flcad-public-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    try { $publicManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempManifest -Encoding UTF8; foreach ($name in $publishFiles) { $source = if ($name -eq 'manifest.json') { $tempManifest } else { Join-Path $packageRoot $name }; if ((Hash $source) -ne (Hash (Join-Path $destinationRoot $name))) { Fail "version conflict: $name" } } } finally { Remove-Item -LiteralPath $tempManifest -Force -ErrorAction SilentlyContinue }
    $status = 'idempotent'
  } else {
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    Copy-Item -LiteralPath $reportPath -Destination (Join-Path $stageRoot 'report.json')
    Copy-Item -LiteralPath $reviewPath -Destination (Join-Path $stageRoot 'review-request.json')
    $stageManifestPath = Join-Path $stageRoot 'manifest.json'; $publicManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageManifestPath -Encoding UTF8
    $stageFiles = @(Get-ChildItem -LiteralPath $stageRoot -File)
    if ($stageFiles.Count -ne 3 -or @($stageFiles.Name | Where-Object { $_ -notin $publishFiles }).Count -gt 0) { Fail 'public staging is incomplete' }
    foreach ($entry in $publicManifest.files) { Assert-Hash ([string]$entry.sha256) "public hash $($entry.name)"; if ($entry.sha256 -ne (Hash (Join-Path $stageRoot $entry.name))) { Fail "public hash mismatch: $($entry.name)" } }
    $publicCheck = Read-Json $stageManifestPath; $publicNames = @($publicCheck.files | ForEach-Object { [string]$_.name })
    if ($publicCheck.manifest_scope -ne 'public' -or $publicNames.Count -ne 2 -or @($publicNames | Select-Object -Unique).Count -ne 2 -or @($publicNames | Where-Object { $_ -notin @('report.json','review-request.json') }).Count -gt 0) { Fail 'public manifest is invalid' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationRoot) | Out-Null
    Move-Item -LiteralPath $stageRoot -Destination $destinationRoot
    $stageMoved = $true; $status = 'prepared-for-publication'
  }
} finally { if (-not $stageMoved -and (Test-Path -LiteralPath $stageRoot)) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue } }
[ordered]@{schema_version='1.0';status=$status;task_id=$report.task_id;version=$Version;branch=$Branch;destination=$destinationRelative;files=$publishFiles;public_manifest_sha256=(Hash (Join-Path $destinationRoot 'manifest.json'));publish_performed=$false;push_performed=$false;remote=$remote.Text}|ConvertTo-Json -Depth 8
