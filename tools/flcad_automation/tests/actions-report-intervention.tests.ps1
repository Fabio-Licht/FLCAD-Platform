$ErrorActionPreference = 'Stop'
$automation = Split-Path -Parent $PSScriptRoot
$worktree = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$adapter = Join-Path $automation 'actions-transport.ps1'
$tmp = Join-Path $env:TEMP ('flcad-ab05a-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null

function Write-Json([string]$Path, [object]$Object) { $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Invoke-Reject([string]$InputPath, [string]$OutPath, [string]$Message) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter -Intervention $InputPath -Worktree $worktree -OutDir $OutPath 2>&1 | Out-Null
  $code = $LASTEXITCODE; $ErrorActionPreference = $old
  Assert-True ($code -ne 0) $Message
}

try {
  $head = (git -C $worktree rev-parse HEAD).Trim()
  $validPath = Join-Path $tmp 'valid-v3.json'
  $valid = [ordered]@{
    schema_version = '1.0'; task_id = 'AB05A-DRYRUN'; report_version = 3
    report_sha256 = ('a' * 64)
    report_url = 'https://github.com/Fabio-Licht/FLCAD-Platform/blob/automation/reports/reports/AB05A-DRYRUN/v3/report.json'
    event = 'USER_TEST_REQUIRED'; state = 'WAITING_FOR_USER'; reason = 'professional test required'
    priority = 'P1'; action_requested = 'Perform the supervised test'; technical_summary = 'Synthetic v3 intervention'
    branch = 'automation/flcad-bridge'; commit = $head; deduplication_id = 'AB05A-DRYRUN.v3.USER_TEST_REQUIRED'
    execution_mode = 'HEADLESS_DEVELOPMENT'; gui_control_authorization = 'not-granted'; notification_status = 'local'
  }
  Write-Json $validPath $valid
  $out = Join-Path $tmp 'out'
  $first = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter -Intervention $validPath -Worktree $worktree -OutDir $out | ConvertFrom-Json
  Assert-True ($first.status -eq 'prepared-for-publication') 'evento válido deve ser preparado'
  Assert-True ($first.dispatch_performed -eq $false) 'dry-run não pode disparar workflow'
  $envelope = Get-Content (Join-Path $out 'AB05A-DRYRUN.v3.USER_TEST_REQUIRED-actions.json') -Raw | ConvertFrom-Json
  Assert-True ($envelope.authentication -eq 'not-used') 'dry-run não pode usar autenticação'
  Assert-True ($envelope.inputs.report_version -eq '3') 'report_version deve ser transportado'
  Assert-True ($envelope.inputs.report_sha256 -eq ('a' * 64)) 'report_sha256 deve ser transportado'
  Assert-True ($envelope.inputs.report_url -eq $valid.report_url) 'report_url deve ser transportado'
  Assert-True ($envelope.inputs.report_reference -eq $valid.report_url) 'report_reference deve ser derivado sem perder compatibilidade'
  Assert-True ($envelope.ref -eq 'main') 'ref de dispatch deve apontar para main por padrão'
  Assert-True ($envelope.source_branch -eq $valid.branch) 'branch de origem deve permanecer no payload'

  $customOut = Join-Path $tmp 'custom-ref-out'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter -Intervention $validPath -Worktree $worktree -OutDir $customOut -DispatchRef 'automation/workflow-published' | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) 'ref explícita deve ser aceita'
  $customEnvelope = Get-Content (Join-Path $customOut 'AB05A-DRYRUN.v3.USER_TEST_REQUIRED-actions.json') -Raw | ConvertFrom-Json
  Assert-True ($customEnvelope.ref -eq 'automation/workflow-published') 'ref explícita deve ser preservada'

  $replay = Join-Path $tmp 'replay-out'
  Invoke-Reject $validPath $out 'replay deve ser rejeitado pelo envelope local existente'

  $conflict = Join-Path $tmp 'conflict.json'; $valid.report_sha256 = ('b' * 64); Write-Json $conflict $valid
  Invoke-Reject $conflict $out 'conflito de payload deve ser rejeitado'

  $unauthorized = Join-Path $tmp 'unauthorized.json'; $valid.event = 'COMPLETED'; $valid.report_sha256 = ('a' * 64); Write-Json $unauthorized $valid
  Invoke-Reject $unauthorized (Join-Path $tmp 'unauthorized-out') 'evento não autorizado deve ser rejeitado'

  $badSha = Join-Path $tmp 'bad-sha.json'; $valid.event = 'USER_TEST_REQUIRED'; $valid.report_sha256 = 'not-a-sha'; Write-Json $badSha $valid
  Invoke-Reject $badSha (Join-Path $tmp 'bad-sha-out') 'SHA inválido deve ser rejeitado'

  $partial = Join-Path $tmp 'partial.json'; $valid.report_sha256 = ('a' * 64); $partialObject = [pscustomobject]$valid; $partialObject.PSObject.Properties.Remove('report_url'); Write-Json $partial $partialObject
  Invoke-Reject $partial (Join-Path $tmp 'partial-out') 'payload sem report_url deve ser rejeitado'

  $gui = Join-Path $tmp 'gui.json'; $valid.gui_control_authorization = 'granted-explicitly'; Write-Json $gui $valid
  Invoke-Reject $gui (Join-Path $tmp 'gui-out') 'autorização GUI implícita deve ser rejeitada'

  Write-Output 'actions-report-intervention.tests.ps1: PASS'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
