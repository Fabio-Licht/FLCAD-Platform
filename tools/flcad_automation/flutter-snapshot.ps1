[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [ValidateSet('Create','Verify','Remove')] [string] $Command,
  [string] $SourceRoot = 'C:\flcad_mobile',
  [string] $SnapshotRoot,
  [string] $ManifestPath,
  [string] $ExpectedBranch = 'feat/plane-axis-intersection-point',
  [string] $ExpectedCommit = '81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54'
)

$ErrorActionPreference='Stop'
function Fail([string]$Message){ throw "FLCAD snapshot rejected: $Message" }
function Full([string]$Path){ return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path) }
function Assert-ExactRoot([string]$Path){
  $resolved=Full $Path
  if($resolved.TrimEnd('\') -ne 'C:\flcad_mobile'){ Fail "origem não autorizada: $resolved" }
  return $resolved
}
function Invoke-GitSnapshot([ValidateSet('branch','head')][string]$Operation,[string]$Root){
  if($Operation -eq 'branch'){$o=& git -C $Root branch --show-current}else{$o=& git -C $Root rev-parse HEAD}
  [pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()}
}
function Assert-NoReparse([string]$Root){
  $items=Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop
  foreach($i in $items){ if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){ Fail "link/reparse point não permitido: $($i.FullName)" } }
}
function Hash([string]$Path){ return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Rel([string]$Root,[string]$Path){ return $Path.Substring($Root.Length).TrimStart('\','/') -replace '\\','/' }
function Get-SourceFiles([string]$Root){
  $fixed=@('pubspec.yaml','pubspec.lock','analysis_options.yaml','.dart_tool/package_config.json','.dart_tool/package_graph.json','.dart_tool/package_config_subset.json','test/selection_latency_diagnostics_test.dart','lib/app/cad_viewport/selection_latency_diagnostics.dart','test_assets/real_meshes/PARCIAL_FURO_18MM.stl','assets/branding/flcad_reverse_ai_mark.png','assets/icons/flcad_reverse_ai_icon.png','assets/splash/mesh_to_cad.png')
  $paths=@()
  foreach($p in $fixed){ $full=Join-Path $Root $p; if(Test-Path -LiteralPath $full -PathType Leaf){$paths+=$full} elseif($p -notin @('analysis_options.yaml','.dart_tool/package_config_subset.json')){Fail "arquivo necessário ausente: $p"} }
  $lib=Join-Path $Root 'lib'
  foreach($f in (Get-ChildItem -LiteralPath $lib -File -Recurse)){ $paths+=$f.FullName }
  $matrix=Join-Path $Root 'test/er_p2c_c4_f1_real_seed_matrix_test.dart'
  if(Test-Path $matrix){$paths+=$matrix}
  $paths=$paths|Sort-Object -Unique
  foreach($f in $paths){
    $item=Get-Item -LiteralPath $f -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Fail "link/reparse point não permitido: $(Rel $Root $f)"}
    $r=Rel $Root $f; if($r -match '(^|/)\.env($|\.)|credentials|id_rsa|private[-_]?key|artifacts/|test_assets/screenshots/'){Fail "caminho privado/artefato bloqueado: $r"}
  }
  return @($paths)
}
function Assert-TempDestination([string]$Path){
  $full=[IO.Path]::GetFullPath($Path); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()); $persistent=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'FLCAD\automation-bridge-runtime\snapshots'))
  if($full.StartsWith($persistent,[StringComparison]::OrdinalIgnoreCase)){if($full.TrimEnd('\\') -eq $persistent.TrimEnd('\\')){Fail 'destino persistente específico obrigatório'};return $full}
  if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){Fail 'destino deve estar sob o diretório temporário do usuário'}
  if($full.TrimEnd('\') -eq $temp.TrimEnd('\')){Fail 'destino temporário específico obrigatório'}
  return $full
}
function Read-Manifest([string]$Path){ if(!(Test-Path -LiteralPath $Path -PathType Leaf)){Fail "manifesto ausente: $Path"}; try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{Fail 'manifesto JSON inválido'} }
function Verify-Snapshot([string]$Path){
  $m=Read-Manifest $Path
  foreach($n in @('schema_version','snapshot_id','source_branch','source_commit','destination_root','files','created_by')){if($null -eq $m.PSObject.Properties[$n]){Fail "manifesto incompleto: $n"}}
  if($m.schema_version -ne '1.0' -or $m.created_by -ne 'flcad-automation'){Fail 'identidade do snapshot inválida'}
  $dest=[IO.Path]::GetFullPath([string]$m.destination_root); if(!(Test-Path -LiteralPath $dest -PathType Container)){Fail 'destino do snapshot ausente'}
  Assert-TempDestination $dest; Assert-NoReparse $dest
  $seen=@{}
  foreach($e in @($m.files)){
    if([string]$e.path -notmatch '^[^/].*$' -or [IO.Path]::IsPathRooted([string]$e.path) -or [string]$e.path -match '(^|/)\.\.') {Fail "caminho de manifesto inválido: $($e.path)"}
    $p=Join-Path $dest ([string]$e.path); if(!(Test-Path -LiteralPath $p -PathType Leaf)){Fail "arquivo ausente no snapshot: $($e.path)"}
    if((Hash $p) -ne ([string]$e.sha256).ToLowerInvariant()){Fail "hash divergente: $($e.path)"}
    $seen[[IO.Path]::GetFullPath($p)]=$true
  }
  $actual=@()
  foreach($item in (Get-ChildItem -LiteralPath $dest -File -Recurse)){
    $relative=Rel $dest $item.FullName
    if($item.Name -ne 'snapshot-manifest.json' -and $relative -notlike 'artifacts/*' -and $relative -notlike 'build/*' -and $relative -notlike '.dart_tool/flutter_build/*' -and $relative -notlike '.dart_tool/hooks_runner/*'){$actual+=$item.FullName}
  }
  if($actual.Count -ne $seen.Count -or @($actual|Where-Object{!$seen.ContainsKey($_)}).Count -gt 0){Fail 'arquivo inesperado no snapshot'}
  return $m
}

if($Command -eq 'Create'){
  $src=Assert-ExactRoot $SourceRoot
  $b=Invoke-GitSnapshot branch $src; $h=Invoke-GitSnapshot head $src
  if($b.Code -ne 0 -or $b.Text -ne $ExpectedBranch){Fail "branch divergente: $($b.Text)"}
  if($h.Code -ne 0 -or $h.Text -ne $ExpectedCommit){Fail "commit divergente: $($h.Text)"}
  if([string]::IsNullOrWhiteSpace($SnapshotRoot)){$SnapshotRoot=Join-Path ([IO.Path]::GetTempPath()) ('flcad-flutter-snapshot-'+[guid]::NewGuid().ToString('N'))}
  $dest=Assert-TempDestination $SnapshotRoot
  if(Test-Path -LiteralPath $dest){Fail 'destino já existe'}
  New-Item -ItemType Directory -Path $dest -Force|Out-Null
  $sourceFiles=Get-SourceFiles $src; $entries=@()
  foreach($f in $sourceFiles){$r=Rel $src $f;$to=Join-Path $dest $r;New-Item -ItemType Directory -Force -Path (Split-Path $to)|Out-Null;Copy-Item -LiteralPath $f -Destination $to -Force;$entries+=[ordered]@{path=$r;bytes=(Get-Item $f).Length;sha256=(Hash $f)}}
  Assert-NoReparse $dest
  $before=@{}; foreach($e in $entries){$before[$e.path]=[string]$e.sha256}
  foreach($e in $entries){$to=Join-Path $dest $e.path;if((Hash $to) -ne $before[$e.path]){Fail "verificação pós-cópia falhou: $($e.path)"}}
  $m=[ordered]@{schema_version='1.0';snapshot_id=([guid]::NewGuid().ToString('N'));created_by='flcad-automation';created_at=(Get-Date).ToUniversalTime().ToString('o');source_profile='flcad-functional';source_branch=$b.Text;source_commit=$h.Text;destination_root=$dest;excluded_paths=@('artifacts/','test_assets/screenshots/','.git/');mutable_paths=@('artifacts/','build/','.dart_tool/flutter_build/','.dart_tool/hooks_runner/');files=$entries;source_file_count=$entries.Count;write_linkage='none';snapshot_status='verified'}
  $mp=Join-Path $dest 'snapshot-manifest.json';$m|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $mp -Encoding UTF8
  $verified=Verify-Snapshot $mp
  $verified|ConvertTo-Json -Depth 10
  exit 0
}
if($Command -eq 'Verify'){$m=Verify-Snapshot (Full $ManifestPath);$m|ConvertTo-Json -Depth 10;exit 0}
if($Command -eq 'Remove'){
  $m=Verify-Snapshot (Full $ManifestPath);$dest=[IO.Path]::GetFullPath([string]$m.destination_root);if($m.created_by -ne 'flcad-automation'){Fail 'limpeza não autorizada'};Remove-Item -LiteralPath $dest -Recurse -Force;Write-Output "REMOVED: $dest";exit 0
}
