[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $InputJson,
  [string] $OutFile,
  [string] $ResultSchema,
  [string] $ClassificationSchema
)
$ErrorActionPreference = 'Stop'
$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path;if([string]::IsNullOrWhiteSpace($ResultSchema)){$ResultSchema=Join-Path $scriptDir 'result.schema.json'};if([string]::IsNullOrWhiteSpace($ClassificationSchema)){$ClassificationSchema=Join-Path $scriptDir 'classification.schema.json'}
function Fail([string]$Message){throw "AB-04C classification rejected: $Message"}
function Read-Json([string]$Path){if(!(Test-Path -LiteralPath $Path -PathType Leaf)){Fail "file not found: $Path"};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{Fail "invalid JSON: $Path"}}
function Assert-Schema([object]$Value,[object]$Schema,[string]$Path='root'){
  if($Schema.type -eq 'object'){$props=@($Value.PSObject.Properties.Name);$declared=@($Schema.properties.PSObject.Properties.Name);foreach($n in @($Schema.required)){if($null -eq $Value.PSObject.Properties[$n]){Fail "$Path missing $n"}};if($Schema.additionalProperties -eq $false){foreach($n in $props){if($declared -notcontains $n){Fail "$Path unexpected $n"}}};foreach($n in $props){if($declared -contains $n){Assert-Schema $Value.$n $Schema.properties.$n "$Path.$n"}};return}
  if($null -ne $Schema.const -and $Value -ne $Schema.const){Fail "$Path const mismatch"};if($null -ne $Schema.enum -and $Value -notin @($Schema.enum)){Fail "$Path enum mismatch"}
  switch([string]$Schema.type){'string'{if($Value -isnot [string]){Fail "$Path must be string"};if($Schema.minLength-and$Value.Length-lt$Schema.minLength){Fail "$Path too short"};if($Schema.maxLength-and$Value.Length-gt$Schema.maxLength){Fail "$Path too long"};if($Schema.pattern-and$Value-notmatch$Schema.pattern){Fail "$Path pattern mismatch"}}'boolean'{if($Value -isnot [bool]){Fail "$Path must be boolean"}}'integer'{if($Value -isnot [int] -and $Value -isnot [long]){Fail "$Path must be integer"}}'number'{if($Value -isnot [ValueType]){Fail "$Path must be number"}}}
}
function Safe-Id([string]$Value){if($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'){Fail 'task_id invalid'};return $Value}
$inputObject=Read-Json $InputJson;$inputSchemaObject=Read-Json $ResultSchema;$classificationSchemaObject=Read-Json $ClassificationSchema;$allowedInput=@($inputSchemaObject.properties.PSObject.Properties.Name);$unknown=@($inputObject.PSObject.Properties.Name|Where-Object{$allowedInput -notcontains $_});if($unknown.Count -gt 0){Fail "unexpected field: $($unknown -join ',')"};Assert-Schema $inputObject $inputSchemaObject 'result'
$taskId=Safe-Id ([string]$inputObject.task_id);$blocking=[bool]($inputObject.blocked -or $inputObject.dependency_unavailable -or $inputObject.gui_authorization_required -or $inputObject.security_failure);$waiting=[bool]($inputObject.professional_test_required -or $inputObject.approval_required -or $inputObject.critical_decision_required)
if($blocking){$classification='BLOCKED';$event='AGENT_BLOCKED';$notification=$true;$reason='Structured blocking condition prevents safe continuation';$action='Resolve the blocking condition before continuing'}
elseif($waiting){if([string]::IsNullOrWhiteSpace([string]$inputObject.reason)-or[string]::IsNullOrWhiteSpace([string]$inputObject.action_requested)){Fail 'waiting result requires a specific reason and action'};$classification='WAITING_FOR_USER';$event=if($inputObject.professional_test_required){'USER_TEST_REQUIRED'}else{'USER_APPROVAL_REQUIRED'};$notification=$true;$reason=[string]$inputObject.reason;$action=[string]$inputObject.action_requested}
elseif($inputObject.execution_status -eq 'completed' -and [bool]$inputObject.criteria_verified){if($inputObject.review_required){$classification='READY_FOR_REVIEW';$event='NONE';$notification=$false;$reason='Report is ready for independent technical review';$action='Review independently; this is not approval'}else{$classification='COMPLETED';$event='NONE';$notification=$false;$reason='Authorized criteria verified without additional intervention';$action='No human action required'}}
else{$classification='BLOCKED';$event='AGENT_BLOCKED';$notification=$true;$reason='Execution did not produce sufficient verified criteria';$action='Resolve the failure or provide complete structured evidence'}
$result=[ordered]@{schema_version='1.0';task_id=$taskId;classification=$classification;notification_required=$notification;event=$event;reason=$reason;action_requested=$action};$json=$result|ConvertTo-Json -Depth 8;$resultObject=$json|ConvertFrom-Json;Assert-Schema $resultObject $classificationSchemaObject 'classification';if($OutFile){$json|Set-Content -LiteralPath $OutFile -Encoding UTF8};$json
