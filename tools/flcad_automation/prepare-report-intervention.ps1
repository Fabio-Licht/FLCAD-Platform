[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $ReportRoot,
  [Parameter(Mandatory = $true)] [string] $TaskId,
  [Parameter(Mandatory = $true)] [ValidateRange(1,9999)] [int] $Version,
  [Parameter(Mandatory = $true)] [string] $ReportUrl,
  [Parameter(Mandatory = $true)] [string] $Classification,
  [Parameter(Mandatory = $true)] [string] $Worktree,
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [ValidateSet('P0','P1','P2','P3')] [string] $Priority='P1',
  [string] $ReportSchema,
  [string] $InterventionSchema,
  [string] $ClassificationSchema,
  [switch] $MarkHandled,
  [string] $HandledBy,
  [string] $Resolution
)
$ErrorActionPreference='Stop'
$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path;if([string]::IsNullOrWhiteSpace($ReportSchema)){$ReportSchema=Join-Path $scriptDir 'report.schema.json'};if([string]::IsNullOrWhiteSpace($InterventionSchema)){$InterventionSchema=Join-Path $scriptDir 'report-intervention.schema.json'};if([string]::IsNullOrWhiteSpace($ClassificationSchema)){$ClassificationSchema=Join-Path $scriptDir 'classification.schema.json'}
function Fail([string]$Message){throw "AB-04C report intervention rejected: $Message"}
function Read-Json([string]$Path){if(!(Test-Path -LiteralPath $Path -PathType Leaf)){Fail "missing file: $([IO.Path]::GetFileName($Path))"};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{Fail "invalid JSON: $([IO.Path]::GetFileName($Path))"}}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Hash-Text([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','')).ToLowerInvariant()}finally{$sha.Dispose()}}
function Git-Run([string[]]$GitArguments,[string]$Root){$o=& git -C "$Root" @GitArguments 2>&1;[pscustomobject]@{Code=$LASTEXITCODE;Text=($o-join"`n").Trim()}}
function Safe-Id([string]$Value){if($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'){Fail 'unsafe task_id'};return $Value}
function Safe-Text([string]$Value,[string]$Name,[int]$Max=4000){if([string]::IsNullOrWhiteSpace($Value)-or$Value.Length-gt$Max-or$Value-match'(?i)(token\s*[:=]|password\s*[:=]|secret\s*[:=]|authorization\s*[:=]|bearer\s+|C:\\Users\\|[A-Za-z]:\\\\|\.stl\b|\.step\b|\.log\b)'){Fail "$Name is unsafe"};return $Value}
function Assert-Schema([object]$Value,[object]$Schema,[string]$Path='root'){
  if($Schema.type -eq 'object'){$props=@($Value.PSObject.Properties.Name);$declared=@($Schema.properties.PSObject.Properties.Name);foreach($n in @($Schema.required)){if($null -eq $Value.PSObject.Properties[$n]){Fail "$Path missing $n"}};if($Schema.additionalProperties -eq $false){foreach($n in $props){if($declared -notcontains $n){Fail "$Path unexpected $n"}}};foreach($n in $props){if($declared -contains $n){Assert-Schema $Value.$n $Schema.properties.$n "$Path.$n"}};return}
  if($Schema.type -eq 'array'){if($Value -isnot [array]){Fail "$Path must be array"};foreach($v in $Value){Assert-Schema $v $Schema.items "$Path[]"};return}
  if($null -ne $Schema.const -and $Value -ne $Schema.const){Fail "$Path const mismatch"};if($null -ne $Schema.enum -and $Value -notin @($Schema.enum)){Fail "$Path enum mismatch"}
  switch([string]$Schema.type){'string'{if($Value -isnot [string]){Fail "$Path must be string"};if($Schema.minLength-and$Value.Length-lt$Schema.minLength){Fail "$Path too short"};if($Schema.maxLength-and$Value.Length-gt$Schema.maxLength){Fail "$Path too long"};if($Schema.pattern-and$Value-notmatch$Schema.pattern){Fail "$Path pattern mismatch"}}'boolean'{if($Value -isnot [bool]){Fail "$Path must be boolean"}}'integer'{if($Value -isnot [int] -and $Value -isnot [long]){Fail "$Path must be integer"}}'number'{if($Value -isnot [ValueType]){Fail "$Path must be number"}}}
}
function Write-JsonAtomic([string]$Path,[object]$Object){$tmp="$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp";try{$Object|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $Path -Force}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}}}
function Acquire-Lock([string]$Path){
  for($i=0;$i-lt200;$i++){
    try{
      $stream=[IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
      $existing='';$stream.Position=0;$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,1024,$true);$existing=$reader.ReadToEnd();$reader.Dispose()
      if(-not [string]::IsNullOrWhiteSpace($existing)){
        try{$meta=$existing|ConvertFrom-Json}catch{$stream.Dispose();Fail 'residual lock metadata is invalid; human recovery required'}
        if($null -eq $meta.pid -or $null -eq $meta.start_ticks){$stream.Dispose();Fail 'residual lock owner is unknown; human recovery required'}
        try{$owner=Get-Process -Id ([int]$meta.pid) -ErrorAction Stop;$ownerTicks=$owner.StartTime.ToUniversalTime().Ticks}catch{$owner=$null}
        if($null -ne $owner -and $ownerTicks -eq [int64]$meta.start_ticks){$stream.Dispose();Start-Sleep -Milliseconds 50;continue}
        $stream.Dispose();Remove-Item -LiteralPath $Path -Force -ErrorAction Stop;continue
      }
      $current=Get-Process -Id $PID;$meta=[ordered]@{pid=$PID;start_ticks=$current.StartTime.ToUniversalTime().Ticks;created_at=(Get-Date).ToUniversalTime().ToString('o')};$bytes=[Text.Encoding]::UTF8.GetBytes(($meta|ConvertTo-Json -Compress));$stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);return $stream
    }catch [IO.IOException]{Start-Sleep -Milliseconds 50}
  }
  Fail 'deduplication lock unavailable'
}
$taskId=Safe-Id $TaskId;$root=(Resolve-Path -LiteralPath $ReportRoot).Path;$work=(Resolve-Path -LiteralPath $Worktree).Path;$reportSchema=Read-Json $ReportSchema;$interventionSchema=Read-Json $InterventionSchema;$classificationSchema=Read-Json $ClassificationSchema
if($ReportUrl-notmatch"^https://github\.com/Fabio-Licht/FLCAD-Platform/blob/automation/reports/reports/$([regex]::Escape($taskId))/v$Version/report\.json$"){Fail 'report URL must identify the exact allowed public report'}
$expectedFiles=@('report.json','review-request.json','manifest.json');$files=@(Get-ChildItem -LiteralPath $root -File);if($files.Count-ne3-or@($files|Where-Object{$_.Name-notin$expectedFiles}).Count){Fail 'published directory must contain exactly three public files'}
$reportPath=Join-Path $root 'report.json';$reviewPath=Join-Path $root 'review-request.json';$manifestPath=Join-Path $root 'manifest.json';$report=Read-Json $reportPath;$review=Read-Json $reviewPath;$manifest=Read-Json $manifestPath;Assert-Schema $report $reportSchema 'report'
if($report.task_id-ne$taskId-or$review.task_id-ne$taskId-or$manifest.task_id-ne$taskId){Fail 'task_id mismatch'};if($manifest.version-ne$Version){Fail 'report version mismatch'};if($manifest.manifest_scope-ne'public'){Fail 'manifest is not public'}
$publicNames=@($manifest.files|ForEach-Object{[string]$_.name});if($publicNames.Count-ne2-or@($publicNames|Select-Object -Unique).Count-ne2-or@($publicNames|Where-Object{$_-notin @('report.json','review-request.json')}).Count){Fail 'public manifest entries are inconsistent'}
foreach($entry in $manifest.files){if($entry.sha256-notmatch'^[0-9a-fA-F]{64}$'){Fail 'invalid public SHA-256'};$path=Join-Path $root $entry.name;if((Hash $path)-ne([string]$entry.sha256).ToLowerInvariant()){Fail "public hash mismatch: $($entry.name)"}}
$reportHash=Hash $reportPath;if($review.report_sha256-ne$reportHash){Fail 'review report hash mismatch'};if($review.analyzed_commit-ne$report.head){Fail 'review commit mismatch'};if($report.head-notmatch'^[0-9a-fA-F]{40}$'){Fail 'report commit invalid'}
$branch=Git-Run @('branch','--show-current') $work;$head=Git-Run @('rev-parse','HEAD') $work;if(($branch.Code -ne 0)-or($head.Code -ne 0)-or($head.Text.Trim()-ne([string]$report.head).Trim())){Fail 'worktree commit diverges from report'}
$classificationObject=Read-Json $Classification;Assert-Schema $classificationObject $classificationSchema 'classification';if($classificationObject.task_id-ne$taskId-or$classificationObject.classification-notin @('WAITING_FOR_USER','BLOCKED')-or$classificationObject.notification_required-ne$true){Fail 'classification does not require intervention'};$event=[string]$classificationObject.event;if($event-notin @('USER_TEST_REQUIRED','USER_APPROVAL_REQUIRED','AGENT_BLOCKED')){Fail 'event outside allowlist'};if(($classificationObject.classification-eq'BLOCKED')-and$event-ne'AGENT_BLOCKED'){Fail 'blocked classification/event mismatch'};if(($classificationObject.classification-eq'WAITING_FOR_USER')-and$event-eq'AGENT_BLOCKED'){Fail 'waiting classification/event mismatch'}
$reason=Safe-Text ([string]$classificationObject.reason) 'reason' 1000;$action=Safe-Text ([string]$classificationObject.action_requested) 'action_requested' 1000;$dedup="${taskId}.v${Version}.${event}";$payload=[ordered]@{task_id=$taskId;report_version=$Version;report_sha256=$reportHash;report_url=$ReportUrl;event=$event;reason=$reason;action_requested=$action;commit=$report.head};$payloadHash=Hash-Text (($payload|ConvertTo-Json -Compress -Depth 8))
$out=(Resolve-Path -LiteralPath $OutDir -ErrorAction SilentlyContinue);if($null-eq$out){New-Item -ItemType Directory -Force -Path $OutDir|Out-Null;$out=(Resolve-Path -LiteralPath $OutDir)}else{$out=$out.Path};$lockPath=Join-Path $out '.report-intervention.lock';$lock=Acquire-Lock $lockPath
try{$indexPath=Join-Path $out 'report-intervention-index.json';$index=if(Test-Path $indexPath){Read-Json $indexPath}else{[pscustomobject]@{entries=@()}};$existing=@($index.entries|Where-Object{$_.deduplication_id-eq$dedup})
 if($MarkHandled){if($existing.Count-ne1){Fail 'intervention not found'};if([string]::IsNullOrWhiteSpace($HandledBy)-or[regex]::IsMatch($Resolution,'(?i)(token\s*[:=]|password\s*[:=]|secret\s*[:=])')){Fail 'invalid handling data'};$existing[0].status='handled';$existing[0]|Add-Member -Force -NotePropertyName handled_by -NotePropertyValue $HandledBy;$existing[0]|Add-Member -Force -NotePropertyName resolution -NotePropertyValue $Resolution;Write-JsonAtomic $indexPath $index;Write-Output ([ordered]@{status='handled';deduplication_id=$dedup}|ConvertTo-Json);exit 0}
 if($existing.Count-gt0-and$existing[0].status-in @('active','handled')){if($existing[0].payload_sha256-ne$payloadHash){Fail 'deduplication conflict with different payload'};[ordered]@{status='deduplicated';task_id=$taskId;report_version=$Version;deduplication_id=$dedup}|ConvertTo-Json;exit 0}
 $intervention=[ordered]@{schema_version='1.0';task_id=$taskId;report_version=$Version;report_sha256=$reportHash;report_url=$ReportUrl;event=$event;state=if($event-eq'AGENT_BLOCKED'){'BLOCKED'}else{'WAITING_FOR_USER'};reason=$reason;priority=$Priority;action_requested=$action;technical_summary=('Intervention linked to verified report '+$taskId+' version '+$Version);branch=$report.branch;commit=$report.head;deduplication_id=$dedup;execution_mode='HEADLESS_DEVELOPMENT';gui_control_authorization='not-granted';notification_status='local'};Assert-Schema $intervention $interventionSchema 'intervention';$file=Join-Path $out "$dedup.json";if(Test-Path -LiteralPath $file){Fail 'orphan intervention file exists; human recovery required'};Write-JsonAtomic $file $intervention;$index.entries+=[pscustomobject]@{deduplication_id=$dedup;payload_sha256=$payloadHash;task_id=$taskId;report_version=$Version;event=$event;status='active';file=(Split-Path $file -Leaf)};Write-JsonAtomic $indexPath $index;[ordered]@{status='prepared-for-publication';notification_status='local';task_id=$taskId;report_version=$Version;report_sha256=$reportHash;event=$event;deduplication_id=$dedup;file=$file}|ConvertTo-Json
}finally{$lock.Dispose();Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue}
