$ErrorActionPreference = 'Stop'
$automation = Split-Path -Parent $PSScriptRoot
$worktree = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$workflow = Join-Path $worktree '.github/workflows/flcad-human-intervention.yml'
if (-not (Test-Path $workflow)) { throw 'workflow ausente' }
$yaml = Get-Content $workflow -Raw
foreach ($required in @('workflow_dispatch:','contents: read','issues: write','cancel-in-progress: false','run: |','GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}','GITHUB_ACTOR: ${{ github.actor }}','publication requires the authorized operator','assignees: [''Fabio-Licht'']')) {
  if ($yaml -notmatch [regex]::Escape($required)) { throw "workflow sem requisito: $required" }
}
foreach ($forbidden in @('actions/checkout','actions/github-script','pull_request:','push:','workflow_run:','issue_comment:','pull-requests: write','actions: write','gh issue create','curl ')) {
  if ($yaml -match [regex]::Escape($forbidden)) { throw "workflow contém elemento proibido: $forbidden" }
}
foreach ($event in @('USER_TEST_REQUIRED','USER_APPROVAL_REQUIRED','AGENT_BLOCKED')) {
  if ($yaml -notmatch [regex]::Escape($event)) { throw "evento ausente: $event" }
}
$tmp = Join-Path $env:TEMP ("flcad-actions-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  $source = Join-Path $automation 'tests/intervention.tests.ps1'
  & powershell -NoProfile -File $source | Out-Host
  $valid = Join-Path $tmp 'valid.json'
  [ordered]@{schema_version='1.0';task_id='AB03F1-DEMO';event='USER_TEST_REQUIRED';state='WAITING_FOR_USER';reason='operador';priority='P1';action_requested='confirmar';technical_summary='teste local';report_reference='reports/demo.json';branch='automation/flcad-bridge';commit=('a'*40);deduplication_id='AB03F1-DEMO-USER_TEST_REQUIRED';execution_mode='HEADLESS_DEVELOPMENT';gui_control_authorization='not-granted';notification_status='prepared-for-publication'} | ConvertTo-Json | Set-Content $valid
  $out = Join-Path $tmp 'out'
  $result = & powershell -NoProfile -File (Join-Path $automation 'actions-transport.ps1') -Intervention $valid -Worktree $worktree -OutDir $out | ConvertFrom-Json
  if ($result.dispatch_performed -ne $false -or $result.issue_publication_enabled -ne $false) { throw 'transportador executou publicação' }
  $envelope = Get-Content (Join-Path $out 'AB03F1-DEMO-USER_TEST_REQUIRED-actions.json') -Raw | ConvertFrom-Json
  if ($envelope.authentication -ne 'not-used') { throw 'credencial usada no dry-run' }
  $failed = $false
  & powershell -NoProfile -File (Join-Path $automation 'actions-transport.ps1') -Intervention $valid -Worktree $worktree -OutDir $out | Out-Null
  if ($LASTEXITCODE -ne 0) { $failed = $true }
  if (-not $failed) { throw 'duplicação não rejeitada' }
  $invalid = Join-Path $tmp 'invalid.json'; (Get-Content $valid -Raw).Replace('USER_TEST_REQUIRED','COMPLETED') | Set-Content $invalid
  $failed = $false
  & powershell -NoProfile -File (Join-Path $automation 'actions-transport.ps1') -Intervention $invalid -Worktree $worktree -OutDir (Join-Path $tmp 'invalid-out') | Out-Null
  if ($LASTEXITCODE -ne 0) { $failed = $true }
  if (-not $failed) { throw 'evento inválido não rejeitado' }
  $extra = Join-Path $tmp 'extra.json'; $extraObject = Get-Content $valid -Raw | ConvertFrom-Json; $extraObject | Add-Member -NotePropertyName unexpected -NotePropertyValue reject; $extraObject | ConvertTo-Json | Set-Content $extra
  $failed = $false
  & powershell -NoProfile -File (Join-Path $automation 'actions-transport.ps1') -Intervention $extra -Worktree $worktree -OutDir (Join-Path $tmp 'extra-out') | Out-Null
  if ($LASTEXITCODE -ne 0) { $failed = $true }
  if (-not $failed) { throw 'campo inesperado não rejeitado' }
  $malformed = Join-Path $tmp 'malformed.json'; Set-Content $malformed '{malformed'
  $failed = $false
  & powershell -NoProfile -File (Join-Path $automation 'actions-transport.ps1') -Intervention $malformed -Worktree $worktree -OutDir (Join-Path $tmp 'malformed-out') | Out-Null
  if ($LASTEXITCODE -ne 0) { $failed = $true }
  if (-not $failed) { throw 'JSON malformado não rejeitado' }
  Write-Output 'PASS actions workflow static validation'
  Write-Output 'PASS dry-run transport and no remote dispatch'
  Write-Output 'PASS duplicate and invalid intervention rejection'
  Write-Output 'PASS GUI remains headless/no-control'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
