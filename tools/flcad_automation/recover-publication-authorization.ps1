[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Ticket,[Parameter(Mandatory=$true)][string]$Worktree)
$ErrorActionPreference='Stop'
function Fail([string]$Message){throw "AB-09G recovery rejected: $Message"}
function Read-Json([string]$Path){try{Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{Fail 'invalid ticket JSON'}}
function Git-Run([string[]]$GitArguments,[string]$Root){$o=& git -C $Root @GitArguments 2>&1;[pscustomobject]@{Code=$LASTEXITCODE;Text=($o -join "`n").Trim()}}
function Save-Atomic([string]$Path,[object]$Value){$tmp="$Path.$([guid]::NewGuid().ToString('N')).tmp";$Value|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $Path -Force}
$t=Read-Json $Ticket;if($t.state -notin @('consumed','published','unconfirmed')){Fail 'ticket is not recoverable'};if($t.max_publications -ne 1){Fail 'invalid publication limit'}
$t|Add-Member -Force -NotePropertyName completed_at -NotePropertyValue $null;$t|Add-Member -Force -NotePropertyName failure -NotePropertyValue $null
$root=(Resolve-Path -LiteralPath $Worktree).Path;$remote=Git-Run @('fetch','origin') $root;if($remote.Code -ne 0){Fail 'remote inspection failed'};$head=Git-Run @('rev-parse','refs/remotes/origin/automation/reports') $root;if($head.Code -ne 0){Fail 'remote branch unavailable'};$remoteSha=$head.Text.ToLowerInvariant()
if($t.state -eq 'published'){[ordered]@{status='already-published';authorization_id=$t.authorization_id;remote_sha=$remoteSha}|ConvertTo-Json;exit 0}
if($t.candidate_commit -and $remoteSha -eq ([string]$t.candidate_commit).ToLowerInvariant()){$t.state='published';$t.completed_at=(Get-Date).ToUniversalTime().ToString('o');$t.failure=$null;Save-Atomic $Ticket $t;[ordered]@{status='published';authorization_id=$t.authorization_id;remote_sha=$remoteSha}|ConvertTo-Json;exit 0}
$t.state='unconfirmed';$t.completed_at=(Get-Date).ToUniversalTime().ToString('o');$t.failure='remote does not confirm candidate commit; authorization cannot be reused';Save-Atomic $Ticket $t;[ordered]@{status='unconfirmed';authorization_id=$t.authorization_id;remote_sha=$remoteSha}|ConvertTo-Json
