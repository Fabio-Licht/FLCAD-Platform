[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Package,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [string] $Branch = 'automation/reports',
  [ValidateRange(1, 9999)] [int] $Version = 1
)

$ErrorActionPreference = 'Stop'
function Fail([string] $Message) { throw "AB-04A report transport rejected: $Message" }
function Read-Json([string] $Path) { try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { Fail "JSON inválido: $([IO.Path]::GetFileName($Path))" } }
function Hash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Git-Run([string[]] $Arguments, [string] $Root) { $out = & git -C $Root @Arguments 2>&1; [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim() } }
function Assert-SafeId([string] $Value, [string] $Name) { if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail "$Name inválido" } }
function Assert-NoPrivate([string] $Text, [string] $Name) {
  if ($Text -match '(?i)(ghp_[A-Za-z0-9]|github_pat_[A-Za-z0-9]|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|token\s*[:=]|password\s*[:=]|secret\s*[:=]|api[_-]?key\s*[:=]|authorization\s*[:=]|bearer\s+|C:\\Users\\|[A-Za-z]:\\\\|\\\\\\\\|file://|\.(stl|step|stp|iges|igs|dxf|dwg|pdb|dll|exe|log)\b)') { Fail "$Name contém conteúdo privado ou credencial" }
}

$packageRoot = (Resolve-Path -LiteralPath $Package).Path
$worktreeRoot = (Resolve-Path -LiteralPath $Worktree).Path
$branchResult = Git-Run @('branch','--show-current') $worktreeRoot
if ($branchResult.Code -ne 0 -or $branchResult.Text -ne $Branch) { Fail "branch divergente: esperado [$Branch], obtido [$($branchResult.Text)]" }
$statusBefore = Git-Run @('status','--porcelain') $worktreeRoot
if ($statusBefore.Code -ne 0) { Fail 'worktree Git inválido' }
if (-not [string]::IsNullOrWhiteSpace($statusBefore.Text)) { Fail 'worktree de transporte precisa estar limpo' }
$remote = Git-Run @('remote','get-url','origin') $worktreeRoot
if ($remote.Code -ne 0 -or [string]::IsNullOrWhiteSpace($remote.Text)) { Fail 'remote origin não configurado' }

$packageFiles = @(Get-ChildItem -LiteralPath $packageRoot -File)
$allowedPackageFiles = @('report.json','review-request.json','manifest.json','transport.json')
if ($packageFiles.Count -ne 4 -or @($packageFiles | Where-Object { $_.Name -notin $allowedPackageFiles }).Count -gt 0) { Fail 'pacote contém arquivos não permitidos' }
foreach ($file in $packageFiles) { if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'links simbólicos não são aceitos no pacote' }; Assert-NoPrivate (Get-Content $file.FullName -Raw) $file.Name }

$reportPath = Join-Path $packageRoot 'report.json'; $reviewPath = Join-Path $packageRoot 'review-request.json'; $manifestPath = Join-Path $packageRoot 'manifest.json'; $transportPath = Join-Path $packageRoot 'transport.json'
$report = Read-Json $reportPath; $review = Read-Json $reviewPath; $manifest = Read-Json $manifestPath; [void](Read-Json $transportPath)
$requiredReport = @('schema_version','task_id','lifecycle_status','branch','head','objective','acceptance_criteria','execution_status','tests','duration_ms','files_changed','limitations','evidence','next_step')
foreach ($field in $requiredReport) { if ($null -eq $report.PSObject.Properties[$field]) { Fail "report.json sem campo: $field" } }
Assert-SafeId ([string]$report.task_id) 'task_id'
if ($report.schema_version -ne '1.0' -or $report.lifecycle_status -ne 'prepared-for-publication') { Fail 'report.json não está preparado para publicação' }
if ($report.head -notmatch '^[0-9a-fA-F]{40}$') { Fail 'commit do relatório inválido' }
if ($report.execution_status -notin @('completed','failed','timed-out','cancelled')) { Fail 'execution_status inválido' }
if ($null -eq $review.PSObject.Properties['task_id'] -or $review.task_id -ne $report.task_id) { Fail 'review-request não corresponde ao relatório' }
if ($null -eq $review.PSObject.Properties['report_sha256'] -or $review.report_sha256 -ne (Hash $reportPath)) { Fail 'hash do relatório na revisão não confere' }
if ($null -eq $manifest.PSObject.Properties['task_id'] -or $manifest.task_id -ne $report.task_id) { Fail 'manifesto não corresponde ao relatório' }
foreach ($entry in @($manifest.files)) {
  if ($entry.name -notin @('report.json','review-request.json','transport.json')) { Fail "manifesto contém arquivo não permitido: $($entry.name)" }
  $source = Join-Path $packageRoot $entry.name
  if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or $entry.sha256 -ne (Hash $source)) { Fail "hash inválido: $($entry.name)" }
}
Assert-NoPrivate (Get-Content $reportPath -Raw) 'report.json'
Assert-NoPrivate (Get-Content $reviewPath -Raw) 'review-request.json'

$destinationRelative = Join-Path (Join-Path 'reports' ([string]$report.task_id)) "v$Version"
$destinationRelative = $destinationRelative -replace '\\','/'
$destinationRoot = Join-Path $worktreeRoot $destinationRelative
New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
$publishFiles = @('report.json','review-request.json','manifest.json')
$existing = @(Get-ChildItem -LiteralPath $destinationRoot -File -ErrorAction SilentlyContinue)
if (@($existing | Where-Object { $_.Name -notin $publishFiles }).Count -gt 0) { Fail 'destino contém arquivos não gerenciados' }
$allSame = $true
foreach ($name in $publishFiles) {
  $source = Join-Path $packageRoot $name; $destination = Join-Path $destinationRoot $name
  if (Test-Path -LiteralPath $destination) { if ((Hash $source) -ne (Hash $destination)) { Fail "conflito de versão para $name" } } else { $allSame = $false; Copy-Item -LiteralPath $source -Destination $destination }
}
$status = if ($allSame) { 'idempotent' } else { 'prepared-for-publication' }
[ordered]@{schema_version='1.0';status=$status;task_id=$report.task_id;version=$Version;branch=$Branch;destination=$destinationRelative;files=$publishFiles;publish_performed=$false;push_performed=$false;remote=$remote.Text}|ConvertTo-Json -Depth 8
