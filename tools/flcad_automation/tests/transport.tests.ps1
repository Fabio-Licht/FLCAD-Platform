$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exporter = Join-Path $root 'export-report.ps1'
$task = Join-Path $root 'demo-task.json'
$sourceReport = Join-Path $root 'reports\AB-01-DRYRUN-ENV.json'
$worktree = (Resolve-Path (Join-Path $root '..\..')).Path
$sandbox = Join-Path $env:TEMP ('flcad-ab02-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
function Assert-True([bool] $Condition, [string] $Message) { if (!$Condition) { throw "ASSERTION FAILED: $Message" } }
try {
  $result = & powershell -NoProfile -File $exporter -Report $sourceReport -Task $task -Worktree $worktree -OutDir $sandbox -SimulatePublication | ConvertFrom-Json
  Assert-True ($result.package_status -eq 'prepared-for-publication') 'pacote deve estar preparado'
  Assert-True ($result.transport.write_permission -eq 'not-verified') 'publicação sem permissão verificada deve ser bloqueada'
  Assert-True ($result.transport.push_performed -eq $false) 'simulação não pode fazer push'
  $package = Join-Path $sandbox 'AB-01-DRYRUN-ENV'
  $safe = Get-Content (Join-Path $package 'report.json') -Raw
  Assert-True ($safe -notmatch '(?i)(token|password|secret|authorization|bearer)') 'relatório sanitizado não pode conter segredos'
  Assert-True (Test-Path (Join-Path $package 'manifest.json')) 'manifesto deve existir'
  $manifestObject = Get-Content (Join-Path $package 'manifest.json') -Raw|ConvertFrom-Json
  foreach($file in Get-ChildItem $package -File | Where-Object Name -ne 'manifest.json'){$hash=(Get-FileHash $file.FullName -Algorithm SHA256).Hash; $entry=$manifestObject.files|?{$_.name -eq $file.Name}; Assert-True ($entry.sha256 -eq $hash) "hash inválido: $($file.Name)"}
  $review = Get-Content (Join-Path $package 'review-request.json') -Raw | ConvertFrom-Json
  Assert-True ($review.task_id -eq 'AB-01-DRYRUN-ENV') 'revisão deve referenciar a tarefa'
  Assert-True ($review.report_sha256 -eq $result.report_sha256) 'revisão deve referenciar o relatório'

  $malicious = Join-Path $sandbox 'malicious.json'; $maliciousObj=Get-Content $sourceReport -Raw|ConvertFrom-Json; $maliciousObj|Add-Member -NotePropertyName secretToken -NotePropertyValue 'DO_NOT_EXPORT'; $maliciousObj|Add-Member -NotePropertyName privatePath -NotePropertyValue 'C:\Users\fabio\private.txt'; $maliciousObj|ConvertTo-Json -Depth 10|Set-Content $malicious -Encoding UTF8
  & powershell -NoProfile -File $exporter -Report $malicious -Task $task -Worktree $worktree -OutDir (Join-Path $sandbox 'sanitized-out') -SimulatePublication | Out-Null
  $sanitized = Get-Content (Join-Path $sandbox 'sanitized-out\AB-01-DRYRUN-ENV\report.json') -Raw
  Assert-True ($sanitized -notmatch 'DO_NOT_EXPORT|private.txt|C:\\Users') 'campos sensíveis devem ser removidos'

  $oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
  & powershell -NoProfile -File $exporter -Report $sourceReport -Task $task -Worktree $worktree -OutDir $sandbox 2>&1 | Out-Null
  $duplicateExit=$LASTEXITCODE; $ErrorActionPreference=$oldPreference
  Assert-True ($duplicateExit -ne 0) 'task_id duplicado deve ser rejeitado'

  $stale = Join-Path $sandbox 'stale.json'; $staleObj=Get-Content $sourceReport -Raw|ConvertFrom-Json; $staleObj.head='0000000000000000000000000000000000000000'; $staleObj|ConvertTo-Json -Depth 10|Set-Content $stale -Encoding UTF8
  $oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
  & powershell -NoProfile -File $exporter -Report $stale -Task $task -Worktree $worktree -OutDir (Join-Path $sandbox 'stale-out') 2>&1 | Out-Null
  $staleExit=$LASTEXITCODE; $ErrorActionPreference=$oldPreference
  Assert-True ($staleExit -ne 0) 'resultado obsoleto deve ser rejeitado'

  $invalid = Join-Path $sandbox 'invalid.json'; '{"taskId":"AB-01-DRYRUN-ENV","status":"completed"}'|Set-Content $invalid -Encoding UTF8
  $oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
  & powershell -NoProfile -File $exporter -Report $invalid -Task $task -Worktree $worktree -OutDir (Join-Path $sandbox 'invalid-out') 2>&1 | Out-Null
  $invalidExit=$LASTEXITCODE; $ErrorActionPreference=$oldPreference
  Assert-True ($invalidExit -ne 0) 'relatório inválido deve ser rejeitado'
  Write-Output 'transport.tests.ps1: PASS'
} finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
