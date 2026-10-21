[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Task,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [string] $ReportRoot,
  [string] $SnapshotManifest,
  [switch] $Cancel,
  [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$script:ExecutorVersion = '0.2.0'

function Fail([string] $Message) {
  throw "FLCAD automation rejected: $Message"
}

function Get-RequiredString([object] $Object, [string] $Name) {
  $value = $Object.$Name
  if ($null -eq $value -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
    Fail "campo obrigatório inválido: $Name"
  }
  return $value
}

function Assert-Property([object] $Object, [string] $Name) {
  if ($null -eq $Object.PSObject.Properties[$Name]) { Fail "campo obrigatório ausente: $Name" }
}

function Test-RelativeJsonPath([string] $Path) {
  return $Path -match '^(?![A-Za-z]:)(?![/\\])(?!.*(?:^|[/\\])\.\.(?:[/\\]|$)).+\.json$'
}
function Quote-Arg([string] $Value) { return '"' + ($Value -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1') + '"' }

function Read-Task([string] $Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "tarefa não encontrada: $Path" }
  try { $task = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { Fail "JSON inválido: $($_.Exception.Message)" }
  $allowedTaskProperties = @('schemaVersion','id','objective','sourceBranch','baseCommit','allowedPaths','requiredTests','acceptanceCriteria','limits','permissions','state','reportPath','action')
  foreach ($property in $task.PSObject.Properties.Name) { if ($property -notin $allowedTaskProperties) { Fail "campo de tarefa não permitido: $property" } }
  foreach ($name in @('schemaVersion','id','objective','sourceBranch','baseCommit','allowedPaths','requiredTests','acceptanceCriteria','limits','permissions','state','reportPath','action')) { Assert-Property $task $name }
  foreach ($name in @('schemaVersion','id','objective','sourceBranch','baseCommit','state','reportPath','action')) { [void](Get-RequiredString $task $name) }
  if ($task.schemaVersion -ne '1.0') { Fail 'schemaVersion não suportada' }
  if ($task.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail 'id fora do contrato' }
  if ($task.baseCommit -notmatch '^[0-9a-fA-F]{40}$') { Fail 'baseCommit inválido' }
  if ($task.allowedPaths.Count -lt 1) { Fail 'allowedPaths vazio' }
  if ($task.acceptanceCriteria.Count -lt 1) { Fail 'acceptanceCriteria vazio' }
  if ($task.state -ne 'approved') { Fail 'a tarefa precisa estar no estado approved' }
  if ($task.action -notin @('environment','codex-environment-probe','flutter-selection-latency','flutter-real-seed-matrix')) { Fail 'action não permitida nesta versão' }
  if ($task.action -in @('flutter-selection-latency','flutter-real-seed-matrix') -and $task.sourceBranch -ne 'feat/plane-axis-intersection-point') { Fail 'ação Flutter exige a branch funcional autorizada' }
  if (!(Test-RelativeJsonPath $task.reportPath)) { Fail 'reportPath deve ser JSON relativo sem traversal' }
  if ($task.limits.maxDurationSeconds -isnot [int] -or $task.limits.maxDurationSeconds -lt 1 -or $task.limits.maxDurationSeconds -gt 3600) { Fail 'limite de duração inválido' }
  if ($task.limits.maxOutputBytes -isnot [int] -or $task.limits.maxOutputBytes -lt 1024 -or $task.limits.maxOutputBytes -gt 10485760) { Fail 'limite de saída inválido' }
  foreach ($permission in @('workspaceWrite','network','gitMutation','remotePublish')) { if ($task.permissions.$permission -ne $false) { Fail "permissão proibida: $permission" } }
  foreach ($path in $task.allowedPaths) { if ($path -match '(^|[/\\])\.\.(?:[/\\]|$)' -or [IO.Path]::IsPathRooted($path)) { Fail "allowedPaths inseguro: $path" } }
  return $task
}

function Invoke-Git([string[]] $Arguments, [string] $Root) {
  $output = & git -C $Root @Arguments 2>&1
  return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine).Trim() }
}

function Get-ToolSnapshot {
  $names = @('git','flutter','dart','codex','cmake','msbuild','cl','gh')
  $result = @()
  foreach ($name in $names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    $result += [pscustomobject]@{ Name = $name; Available = ($null -ne $command); Path = if($command){$command.Source}else{$null} }
  }
  return $result
}

function Write-JsonReport([string] $Path, [object] $Report) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-CodexProbe([object] $TaskObject, [string] $Root, [string] $LogPath) {
  $prompt = 'Read-only environment probe. Report the current git branch, HEAD, and available git/flutter/dart/codex tools. Do not modify files, do not run git mutation commands, do not access the network, and do not change configuration.'
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'codex'
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $quote = { param([string] $Value) '"' + ($Value -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1') + '"' }
  $psi.Arguments = "exec --cd $(& $quote $Root) --sandbox read-only --ephemeral --json $(& $quote $prompt)"
  $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  if (!$process.WaitForExit($TaskObject.limits.maxDurationSeconds * 1000)) {
    $process.Kill()
    $content = "timeout after $($TaskObject.limits.maxDurationSeconds)s`n$($stdout.Result)`n$($stderr.Result)"
    Set-Content -LiteralPath $LogPath -Value $content -Encoding UTF8
    return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; Output = $content }
  }
  $content = "$($stdout.Result)`n$($stderr.Result)"
  if ($content.Length -gt $TaskObject.limits.maxOutputBytes) { $content = $content.Substring(0, $TaskObject.limits.maxOutputBytes) + "`n[output truncated]" }
  Set-Content -LiteralPath $LogPath -Value $content -Encoding UTF8
  return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false; Output = $content }
}

function Get-FlutterAction([string] $Action) {
  if ($Action -eq 'flutter-selection-latency') {
    return [pscustomobject]@{ TestPath='test/selection_latency_diagnostics_test.dart'; Criteria=@('monotonic structured stages','disabled operation is inert') }
  }
  if ($Action -eq 'flutter-real-seed-matrix') {
    return [pscustomobject]@{ TestPath='test/er_p2c_c4_f1_real_seed_matrix_test.dart'; Criteria=@('real cylinder seed matrix completes','dimensional and convergence evidence preserved') }
  }
  return $null
}

function Invoke-FlutterFixed([object] $TaskObject, [string] $Root, [string] $LogPath) {
  $definition = Get-FlutterAction $TaskObject.action
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $flutter) { return [pscustomobject]@{ ExitCode=127; TimedOut=$false; Output='flutter executable unavailable' } }
  $psi = [Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$flutter.Source; $psi.WorkingDirectory=$Root
  $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
  $psi.Arguments = 'test --no-pub --reporter expanded ' + (Quote-Arg $definition.TestPath)
  $process = [Diagnostics.Process]::new(); $process.StartInfo=$psi; [void]$process.Start()
  $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
  if (!$process.WaitForExit($TaskObject.limits.maxDurationSeconds * 1000)) {
    try {$process.Kill()} catch {}
    $content = "timeout after $($TaskObject.limits.maxDurationSeconds)s"
    Set-Content -LiteralPath $LogPath -Value $content -Encoding UTF8
    return [pscustomobject]@{ ExitCode=124; TimedOut=$true; Output=$content }
  }
  $content = "$($stdout.Result)`n$($stderr.Result)"
  Set-Content -LiteralPath $LogPath -Value $content -Encoding UTF8
  $summary = if ($content.Length -gt 4000) { $content.Substring($content.Length - 4000) } else { $content }
  return [pscustomobject]@{ ExitCode=$process.ExitCode; TimedOut=$false; Output=$content; Summary=$summary }
}

function Get-FlutterEvidence([object] $TaskObject, [string] $Output, [int] $ExitCode, [double] $DurationMs) {
  $definition = Get-FlutterAction $TaskObject.action
  $metrics = [ordered]@{}
  foreach ($name in @('input_triangles','reference_selected','reference_transitions','diameter','rms','c2_ms','c3_ms','converged','quality')) {
    $match = [regex]::Match($Output, "(?:^|\s)$name=([^\s]+)", [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($match.Success) { $metrics[$name] = $match.Groups[1].Value }
  }
  $convergence = if ($Output -match 'convergence-failed') { 'convergence-failed' } elseif ($Output -match 'converged=true') { 'converged' } else { 'not-observed' }
  return [ordered]@{
    fixed_test=$definition.TestPath; command='flutter test --no-pub --reporter expanded <fixed-test-path>'
    exit_code=$ExitCode; duration_ms=$DurationMs; criteria=$definition.Criteria
    criteria_verified=($ExitCode -eq 0); metrics=$metrics; convergence_status=$convergence
    output_summary=if($Output.Length -gt 4000){$Output.Substring($Output.Length - 4000)}else{$Output}
  }
}

$root = (Resolve-Path -LiteralPath $Worktree).Path
$reportRoot = if ([string]::IsNullOrWhiteSpace($ReportRoot)) { $root } else { (Resolve-Path -LiteralPath $ReportRoot).Path }
$taskObject = Read-Task $Task
$snapshotRoot = $null
if ($taskObject.action -in @('flutter-selection-latency','flutter-real-seed-matrix')) {
  if ([string]::IsNullOrWhiteSpace($SnapshotManifest)) { Fail 'Flutter action requires a verified snapshot manifest' }
  $manifestScript = Join-Path $PSScriptRoot 'flutter-snapshot.ps1'
  $manifestFull = (Resolve-Path -LiteralPath $SnapshotManifest -ErrorAction Stop).Path
  $verify = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manifestScript -Command Verify -ManifestPath $manifestFull 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "snapshot invalid: $($verify -join ' ')" }
  $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
  if ($manifest.sourceBranch -and $manifest.sourceBranch -ne $taskObject.sourceBranch) { Fail 'snapshot branch mismatch' }
  if ($manifest.source_branch -ne $taskObject.sourceBranch -or $manifest.source_commit -ne $taskObject.baseCommit) { Fail 'snapshot origin mismatch' }
  $snapshotRoot = [IO.Path]::GetFullPath([string]$manifest.destination_root)
  if ($snapshotRoot -ne [IO.Path]::GetFullPath($root)) { Fail 'worktree is not the verified snapshot destination' }
  if ($taskObject.action -eq 'flutter-real-seed-matrix') {
    $matrixPath = Join-Path $snapshotRoot 'test/er_p2c_c4_f1_real_seed_matrix_test.dart'
    if ((Get-Content -LiteralPath $matrixPath -Raw) -match '[A-Za-z]:\\') { Fail 'real seed test has non-relocatable absolute paths' }
  }
  $root = 'C:\flcad_mobile'
}
$branch = Invoke-Git @('branch','--show-current') $root
$head = Invoke-Git @('rev-parse','HEAD') $root
if ($branch.ExitCode -ne 0 -or $branch.Output -ne $taskObject.sourceBranch) { Fail "branch divergente: esperado $($taskObject.sourceBranch), obtido $($branch.Output)" }
if ($head.ExitCode -ne 0 -or $head.Output -ne $taskObject.baseCommit) { Fail "HEAD divergente: esperado $($taskObject.baseCommit), obtido $($head.Output)" }
if ($taskObject.action -in @('flutter-selection-latency','flutter-real-seed-matrix')) {
  if ($root -ne 'C:\flcad_mobile') { Fail 'ações Flutter só podem executar em C:\flcad_mobile' }
  if ($taskObject.sourceBranch -ne 'feat/plane-axis-intersection-point') { Fail 'branch funcional não autorizada' }
}
if ($null -ne $snapshotRoot) {
  $root = $snapshotRoot
  $branch = [pscustomobject]@{ ExitCode=0; Output=$taskObject.sourceBranch }
  $head = [pscustomobject]@{ ExitCode=0; Output=$taskObject.baseCommit }
}

$lockPath = Join-Path $root '.flcad_automation.lock'
if ($Cancel) {
  if (Test-Path -LiteralPath $lockPath) { $lockData = Get-Content $lockPath -Raw | ConvertFrom-Json; if ($lockData.pid) { Stop-Process -Id ([int]$lockData.pid) -Force -ErrorAction SilentlyContinue } }
  exit 0
}
$lock = $null
try {
  try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) } catch { Fail 'já existe uma execução neste worktree' }
  $lockData = @{ pid = $PID; taskId = $taskObject.id; startedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json
  $bytes = [Text.Encoding]::UTF8.GetBytes($lockData); $lock.Write($bytes,0,$bytes.Length); $lock.Flush()
  if ($ValidateOnly) { Write-Output "VALID: $($taskObject.id)"; exit 0 }
  $started = Get-Date
  $reportPath = Join-Path $reportRoot $taskObject.reportPath
  $logPath = [IO.Path]::ChangeExtension($reportPath, '.log')
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
  $result = $null
  if ($taskObject.action -eq 'environment') {
    $result = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = 'environment probe completed' }
    $extra = @{ tools = @(Get-ToolSnapshot); gitStatus = (Invoke-Git @('status','--short') $root).Output }
  } elseif ($taskObject.action -eq 'codex-environment-probe') {
    $result = Invoke-CodexProbe $taskObject $root $logPath
    $extra = @{ codexOutputLog = $logPath }
  } else {
    $result = Invoke-FlutterFixed $taskObject $root $logPath
    $extra = @{ evidence = Get-FlutterEvidence $taskObject $result.Output $result.ExitCode ([math]::Round(((Get-Date) - $started).TotalMilliseconds, 2)); rawLog = $logPath }
  }
  $report = [ordered]@{
    executorVersion = $script:ExecutorVersion
    taskId = $taskObject.id
    action = $taskObject.action
    startedAt = $started.ToUniversalTime().ToString('o')
    finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    durationMs = [math]::Round(((Get-Date) - $started).TotalMilliseconds, 2)
    worktree_profile = if($taskObject.action -in @('flutter-selection-latency','flutter-real-seed-matrix')){'flcad-functional'}else{'bridge'}
    branch = $branch.Output
    head = $head.Output
    analyzed_commit = $head.Output
    exitCode = $result.ExitCode
    timedOut = $result.TimedOut
    status = if($result.ExitCode -eq 0){'completed'}else{'failed'}
    task = $taskObject
    evidence = if($taskObject.action -in @('flutter-selection-latency','flutter-real-seed-matrix')){$extra.evidence}else{$null}
    details = $extra
  }
  Write-JsonReport $reportPath $report
  Write-Output ($report | ConvertTo-Json -Depth 10)
  if ($result.ExitCode -ne 0) { exit $result.ExitCode }
} finally {
  if ($null -ne $lock) { $lock.Dispose() }
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
