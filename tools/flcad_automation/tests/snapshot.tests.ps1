$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$script=Join-Path $root 'flutter-snapshot.ps1'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ab06f-snapshot-test-'+[guid]::NewGuid().ToString('N'))
function Invoke-Snapshot([string[]]$Arguments){ & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @Arguments 2>&1; return $LASTEXITCODE }
try {
  $out=Invoke-Snapshot @('-Command','Create','-SnapshotRoot',$temp)
  if($LASTEXITCODE -ne 0){throw 'create failed'}
  $manifest=Join-Path $temp 'snapshot-manifest.json'
  if(!(Test-Path $manifest)){throw 'manifest missing'}
  $verify=Invoke-Snapshot @('-Command','Verify','-ManifestPath',$manifest)
  if($LASTEXITCODE -ne 0){throw 'valid snapshot rejected'}
  Set-Content -LiteralPath (Join-Path $temp 'unexpected.txt') -Value 'unexpected'
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Command Verify -ManifestPath $manifest *> $null; $unexpected=$LASTEXITCODE; $ErrorActionPreference=$old
  if($unexpected -eq 0){throw 'unexpected snapshot file accepted'}
  Remove-Item -LiteralPath (Join-Path $temp 'unexpected.txt') -Force
  $entry=Get-Content $manifest -Raw|ConvertFrom-Json|Select-Object -ExpandProperty files|Select-Object -First 1
  $target=Join-Path $temp $entry.path; Add-Content -LiteralPath $target -Value 'tamper'
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Command Verify -ManifestPath $manifest *> $null; $bad=$LASTEXITCODE; $ErrorActionPreference=$old
  if($bad -eq 0){throw 'tampered snapshot accepted'}
  Remove-Item -LiteralPath $temp -Recurse -Force
  Write-Output 'PASS: snapshot integrity and restricted cleanup'
  exit 0
} catch { Write-Error $_; if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}; exit 1 }
