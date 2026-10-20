[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Task,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [switch] $Cancel,
  [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$script:ExecutorVersion = '0.1.0'

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

function Read-Task([string] $Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "tarefa não encontrada: $Path" }
  try { $task = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { Fail "JSON inválido: $($_.Exception.Message)" }
  foreach ($name in @('schemaVersion','id','objective','sourceBranch','baseCommit','allowedPaths','requiredTests','acceptanceCriteria','limits','permissions','state','reportPath','action')) { Assert-Property $task $name }
  foreach ($name in @('schemaVersion','id','objective','sourceBranch','baseCommit','state','reportPath','action')) { [void](Get-RequiredString $task $name) }
  if ($task.schemaVersion -ne '1.0') { Fail 'schemaVersion não suportada' }
  if ($task.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') { Fail 'id fora do contrato' }
  if ($task.baseCommit -notmatch '^[0-9a-fA-F]{40}$') { Fail 'baseCommit inválido' }
  if ($task.allowedPaths.Count -lt 1) { Fail 'allowedPaths vazio' }
  if ($task.acceptanceCriteria.Count -lt 1) { Fail 'acceptanceCriteria vazio' }
  if ($task.state -ne 'approved') { Fail 'a tarefa precisa estar no estado approved' }
  if ($task.action -notin @('environment','codex-environment-probe')) { Fail 'action não permitida nesta versão' }
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

$root = (Resolve-Path -LiteralPath $Worktree).Path
$taskObject = Read-Task $Task
$branch = Invoke-Git @('branch','--show-current') $root
$head = Invoke-Git @('rev-parse','HEAD') $root
if ($branch.ExitCode -ne 0 -or $branch.Output -ne $taskObject.sourceBranch) { Fail "branch divergente: esperado $($taskObject.sourceBranch), obtido $($branch.Output)" }
if ($head.ExitCode -ne 0 -or $head.Output -ne $taskObject.baseCommit) { Fail "HEAD divergente: esperado $($taskObject.baseCommit), obtido $($head.Output)" }

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
  $reportPath = Join-Path $root $taskObject.reportPath
  $logPath = [IO.Path]::ChangeExtension($reportPath, '.log')
  $result = $null
  if ($taskObject.action -eq 'environment') {
    $result = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = 'environment probe completed' }
    $extra = @{ tools = @(Get-ToolSnapshot); gitStatus = (Invoke-Git @('status','--short') $root).Output }
  } else {
    $result = Invoke-CodexProbe $taskObject $root $logPath
    $extra = @{ codexOutputLog = $logPath }
  }
  $report = [ordered]@{
    executorVersion = $script:ExecutorVersion
    taskId = $taskObject.id
    action = $taskObject.action
    startedAt = $started.ToUniversalTime().ToString('o')
    finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    durationMs = [math]::Round(((Get-Date) - $started).TotalMilliseconds, 2)
    worktree = $root
    branch = $branch.Output
    head = $head.Output
    exitCode = $result.ExitCode
    timedOut = $result.TimedOut
    status = if($result.ExitCode -eq 0){'completed'}else{'failed'}
    task = $taskObject
    details = $extra
  }
  Write-JsonReport $reportPath $report
  Write-Output ($report | ConvertTo-Json -Depth 10)
  if ($result.ExitCode -ne 0) { exit $result.ExitCode }
} finally {
  if ($null -ne $lock) { $lock.Dispose() }
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
