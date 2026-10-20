[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $TaskId,
  [Parameter(Mandatory = $true)] [ValidateSet('USER_TEST_REQUIRED','USER_APPROVAL_REQUIRED','AGENT_BLOCKED')] [string] $Event,
  [Parameter(Mandatory = $true)] [string] $Reason,
  [Parameter(Mandatory = $true)] [ValidateSet('P0','P1','P2','P3')] [string] $Priority,
  [Parameter(Mandatory = $true)] [string] $ActionRequested,
  [Parameter(Mandatory = $true)] [string] $TechnicalSummary,
  [Parameter(Mandatory = $true)] [string] $ReportReference,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [Parameter(Mandatory = $true)] [string] $DeduplicationId,
  [ValidateSet('HEADLESS_DEVELOPMENT','GUI_TEST_REQUESTED')] [string] $ExecutionMode = 'HEADLESS_DEVELOPMENT',
  [switch] $GuiAuthorizationGranted,
  [string] $OutDir = 'tools/flcad_automation/notifications',
  [switch] $MarkHandled,
  [string] $HandledBy,
  [string] $Resolution
)

$ErrorActionPreference = 'Stop'
function Fail([string] $Message) { throw "AB-03 intervention rejected: $Message" }
function Git-Run([string[]] $GitArguments, [string] $Root) { $o=& git -C "$Root" @GitArguments 2>&1; [pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()} }
function Assert-Text([string] $Value, [string] $Name, [int] $Max=4000) { if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Max){Fail "$Name inválido"} }
function Assert-SafeText([string] $Value, [string] $Name) { Assert-Text $Value $Name; if($Value -match '(?i)(token|password|secret|api[_-]?key|authorization|bearer|private[_-]?key|credential)\s*[:=]'){Fail "$Name contém possível credencial"} }
function Safe-Id([string] $Value) { if($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$'){Fail 'identificador inválido'}; return $Value }

Safe-Id $TaskId | Out-Null; Safe-Id $DeduplicationId | Out-Null
Assert-SafeText $Reason 'reason'; Assert-SafeText $ActionRequested 'action_requested'; Assert-SafeText $TechnicalSummary 'technical_summary'; Assert-SafeText $ReportReference 'report_reference'
$root=(Resolve-Path -LiteralPath $Worktree).Path
$branch=Git-Run -GitArguments @('branch','--show-current') -Root $root; $commit=Git-Run -GitArguments @('rev-parse','HEAD') -Root $root
if($branch.Code -ne 0 -or [string]::IsNullOrWhiteSpace($branch.Text)){Fail 'branch indisponível'}
if($commit.Code -ne 0 -or $commit.Text -notmatch '^[0-9a-fA-F]{40}$'){Fail 'commit indisponível'}
$state=if($Event -eq 'AGENT_BLOCKED'){'BLOCKED'}else{'WAITING_FOR_USER'}
$guiAuth=if($GuiAuthorizationGranted){'granted-explicitly'}else{'not-granted'}
if($ExecutionMode -eq 'GUI_TEST_REQUESTED' -and $GuiAuthorizationGranted){Fail 'a autorização GUI não pode iniciar controle nesta preparação; ela exige uma etapa explícita separada'}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outRoot=(Resolve-Path -LiteralPath $OutDir).Path; $indexPath=Join-Path $outRoot 'notification-index.json'; $index=@{entries=@()}
if(Test-Path $indexPath){$index=Get-Content $indexPath -Raw|ConvertFrom-Json}
$existing=@($index.entries|Where-Object {$_.deduplication_id -eq $DeduplicationId})
if($MarkHandled){
  if($existing.Count -ne 1){Fail 'intervenção não encontrada para atendimento'}
  Assert-Text $HandledBy 'handled_by' 200; Assert-SafeText $Resolution 'resolution' 1000
  $entry=$existing[0]; $entry.status='handled'; $handledAt=(Get-Date).ToUniversalTime().ToString('o'); $entry|Add-Member -Force -NotePropertyName handled_by -NotePropertyValue $HandledBy; $entry|Add-Member -Force -NotePropertyName handled_at -NotePropertyValue $handledAt; $entry|Add-Member -Force -NotePropertyName resolution -NotePropertyValue $Resolution
  $index|ConvertTo-Json -Depth 8|Set-Content $indexPath -Encoding UTF8
  $file=Join-Path $outRoot "$DeduplicationId.json"; if(Test-Path $file){$obj=Get-Content $file -Raw|ConvertFrom-Json; $obj.notification_status='handled'; $obj|Add-Member -Force -NotePropertyName handled -NotePropertyValue @{handled_by=$HandledBy;handled_at=$handledAt;resolution=$Resolution}; $obj|ConvertTo-Json -Depth 10|Set-Content $file -Encoding UTF8}; Write-Output '{"status":"handled"}'; exit 0
}
if($existing.Count -gt 0 -and $existing[0].status -in @('active','handled')){[ordered]@{status='deduplicated';task_id=$TaskId;deduplication_id=$DeduplicationId}|ConvertTo-Json; exit 0}
$intervention=[ordered]@{schema_version='1.0';task_id=$TaskId;event=$Event;state=$state;reason=$Reason;priority=$Priority;action_requested=$ActionRequested;technical_summary=$TechnicalSummary;report_reference=$ReportReference;branch=$branch.Text;commit=$commit.Text;deduplication_id=$DeduplicationId;execution_mode=$ExecutionMode;gui_control_authorization=$guiAuth;notification_status='local'}
$file=Join-Path $outRoot "$DeduplicationId.json"; if(Test-Path $file){Fail 'arquivo de intervenção já existe'}
$intervention|ConvertTo-Json -Depth 10|Set-Content $file -Encoding UTF8
$index.entries += [pscustomobject]@{deduplication_id=$DeduplicationId;task_id=$TaskId;event=$Event;status='active';file=(Split-Path $file -Leaf);created_at=(Get-Date).ToUniversalTime().ToString('o')}
$index|ConvertTo-Json -Depth 8|Set-Content $indexPath -Encoding UTF8
[ordered]@{status='prepared-for-publication';notification_status='local';task_id=$TaskId;event=$Event;state=$state;deduplication_id=$DeduplicationId;file=$file}|ConvertTo-Json
