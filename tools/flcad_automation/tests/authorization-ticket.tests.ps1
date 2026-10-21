$ErrorActionPreference = 'Stop'

$root = 'C:\flcad_worktrees\flcad-bridge\tools\flcad_automation'
$issuer = Join-Path $root 'issue-publication-authorization.ps1'
$recovery = Join-Path $root 'recover-publication-authorization.ps1'
$publisher = Join-Path $root 'publish-reports.ps1'

$package = 'C:\Users\fabio\AppData\Local\FLCAD\automation-bridge-runtime\outbox-ab09c-ab08c\AB08C-ER-P2C-OCCT-VALIDATION'
$reports = 'C:\flcad_worktrees\flcad-reports-ab09h-final'
$localCandidateCommit = 'e871fd892b44bd9b90b27638f1032f7014168232'
$sandbox = Join-Path $env:TEMP ('flcad-ab09g-ticket-' + [guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Write-Json([string]$Path, [object]$Value) {
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Rejected([string[]]$PublisherArgs) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $publisher @PublisherArgs *> $null
    $code = $LASTEXITCODE

    $ErrorActionPreference = $oldPreference
    Assert-True ($code -ne 0) 'invalid authorization input must be rejected'
}

try {
    if (-not (Test-Path -LiteralPath $package -PathType Container)) {
        throw "Pacote de teste nÃ£o encontrado: $package"
    }

    if (-not (Test-Path -LiteralPath $reports -PathType Container)) {
        throw "Worktree de reports nÃ£o encontrado: $reports"
    }

    if (-not (Test-Path -LiteralPath $issuer -PathType Leaf)) {
        throw "Script emissor nÃ£o encontrado: $issuer"
    }

    if (-not (Test-Path -LiteralPath $recovery -PathType Leaf)) {
        throw "Script de recuperaÃ§Ã£o nÃ£o encontrado: $recovery"
    }

    if (-not (Test-Path -LiteralPath $publisher -PathType Leaf)) {
        throw "Script publicador nÃ£o encontrado: $publisher"
    }

    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

    # EmissÃ£o de bilhete vÃ¡lido
    $valid = Join-Path $sandbox 'valid.json'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $issuer `
        -Package $package `
        -TaskId 'AB08C-ER-P2C-OCCT-VALIDATION' `
        -Worktree $reports `
        -OutFile $valid `
        -ExpiresAt ([DateTime]::UtcNow.AddMinutes(10))

    if ($LASTEXITCODE -ne 0) {
        throw 'O emissor nÃ£o conseguiu criar o bilhete vÃ¡lido.'
    }

    if (-not (Test-Path -LiteralPath $valid -PathType Leaf)) {
        throw 'O emissor terminou sem criar o arquivo do bilhete.'
    }

    $ticket = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    Assert-True ($ticket.state -eq 'issued' -and $ticket.max_publications -eq 1) 'valid ticket fields'

    # Garante persistÃªncia dos campos quando eles ainda nÃ£o existem no JSON
    $bare = Join-Path $sandbox 'bare.json'
    $bareObject = [ordered]@{
        schema_version      = '1.0'
        authorization_id    = 'AB09G-test-bare'
        task_id             = 'AB08C-ER-P2C-OCCT-VALIDATION'
        package_path        = $package
        package_sha256      = $ticket.package_sha256
        branch              = 'automation/reports'
        expected_remote_sha = $ticket.expected_remote_sha
        max_publications    = 1
        expires_at          = $ticket.expires_at
        state               = 'issued'
    }

    Write-Json $bare $bareObject

    $bareTicket = Get-Content -LiteralPath $bare -Raw | ConvertFrom-Json
    $candidate = '2222222222222222222222222222222222222222'

    if ($null -eq $bareTicket.PSObject.Properties['candidate_commit']) {
        $bareTicket | Add-Member -NotePropertyName candidate_commit -NotePropertyValue $candidate
    } else {
        $bareTicket.candidate_commit = $candidate
    }

    $consumedAt = [DateTime]::UtcNow.ToString('o')

    if ($null -eq $bareTicket.PSObject.Properties['consumed_at']) {
        $bareTicket | Add-Member -NotePropertyName consumed_at -NotePropertyValue $consumedAt
    } else {
        $bareTicket.consumed_at = $consumedAt
    }

    $bareTicket.state = 'consumed'
    Write-Json $bare $bareTicket

    $persisted = Get-Content -LiteralPath $bare -Raw | ConvertFrom-Json
    Assert-True ($persisted.candidate_commit -eq $candidate -and $persisted.state -eq 'consumed') 'candidate_commit must persist when absent from JSON'

    $publisherText = Get-Content -LiteralPath $publisher -Raw
    Assert-True ($publisherText -match "PSObject\.Properties\['candidate_commit'\].*Add-Member") 'consumer must initialize candidate_commit safely'

    # Rejeita ticket vÃ¡lido sem autorizaÃ§Ã£o de push
    Invoke-Rejected @(
        '-Command', 'Prepare',
        '-Outbox', (Split-Path -Parent $package),
        '-Worktree', $reports,
        '-AuthorizationTicket', $valid,
        '-AuthorizePush'
    )

    # Rejeita ticket expirado
    $expired = Join-Path $sandbox 'expired.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.expires_at = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    Write-Json $expired $copy

    Invoke-Rejected @(
        '-Command', 'Prepare',
        '-Outbox', (Split-Path -Parent $package),
        '-Worktree', $reports,
        '-AuthorizationTicket', $expired,
        '-AuthorizePush'
    )

    # Rejeita ticket jÃ¡ consumido
    $reused = Join-Path $sandbox 'reused.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.state = 'consumed'
    Write-Json $reused $copy

    Invoke-Rejected @(
        '-Command', 'Prepare',
        '-Outbox', (Split-Path -Parent $package),
        '-Worktree', $reports,
        '-AuthorizationTicket', $reused,
        '-AuthorizePush'
    )

    # Rejeita hash incorreto
    $badSha = Join-Path $sandbox 'bad-sha.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.package_sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
    Write-Json $badSha $copy

    Invoke-Rejected @(
        '-Command', 'Prepare',
        '-Outbox', (Split-Path -Parent $package),
        '-Worktree', $reports,
        '-AuthorizationTicket', $badSha,
        '-AuthorizePush'
    )

    # Rejeita branch incorreta
    $badBranch = Join-Path $sandbox 'bad-branch.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.branch = 'main'
    Write-Json $badBranch $copy

    Invoke-Rejected @(
        '-Command', 'Prepare',
        '-Outbox', (Split-Path -Parent $package),
        '-Worktree', $reports,
        '-AuthorizationTicket', $badBranch,
        '-AuthorizePush'
    )

    # Rejeita SHA remoto incorreto
    $badRemote = Join-Path $sandbox 'bad-remote.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.expected_remote_sha = '1111111111111111111111111111111111111111'
    Write-Json $badRemote $copy

    Invoke-Rejected @(
        '-Command', 'Prepare',
        '-Outbox', (Split-Path -Parent $package),
        '-Worktree', $reports,
        '-AuthorizationTicket', $badRemote,
        '-AuthorizePush'
    )

    # RecuperaÃ§Ã£o sem confirmaÃ§Ã£o do remoto: deve ficar unconfirmed
    $unconfirmed = Join-Path $sandbox 'unconfirmed.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.state = 'consumed'
    $copy | Add-Member -NotePropertyName candidate_commit -NotePropertyValue '1111111111111111111111111111111111111111' -Force
    Write-Json $unconfirmed $copy

    $recoveryResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recovery `
        -Ticket $unconfirmed `
        -Worktree $reports | ConvertFrom-Json

    Assert-True ($recoveryResult.status -eq 'unconfirmed') 'unconfirmed recovery must not reuse ticket'
    Assert-True ((Get-Content -LiteralPath $unconfirmed -Raw | ConvertFrom-Json).state -eq 'unconfirmed') 'unconfirmed state persisted'

    # RecuperaÃ§Ã£o confirmada pelo remoto: deve ficar published
    $published = Join-Path $sandbox 'published.json'
    $remoteOutput = & git -C $reports ls-remote origin refs/heads/automation/reports
    if ($LASTEXITCODE -ne 0) {
        throw 'NÃ£o foi possÃ­vel consultar a branch remota automation/reports.'
    }

    $remoteSha = (($remoteOutput -join "`n") -split '\s+')[0].ToLowerInvariant()
    if ($remoteSha -notmatch '^[0-9a-f]{40}$') {
        throw "SHA remoto invÃ¡lido: $remoteSha"
    }

    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.state = 'consumed'
    $copy | Add-Member -NotePropertyName candidate_commit -NotePropertyValue $remoteSha -Force
    Write-Json $published $copy

    $recoveryResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recovery `
        -Ticket $published `
        -Worktree $reports | ConvertFrom-Json

    Assert-True ($recoveryResult.status -eq 'published') 'remote-confirmed recovery must be published'
    Assert-True ((Get-Content -LiteralPath $published -Raw | ConvertFrom-Json).state -eq 'published') 'published state persisted'

    # Commit local antigo nÃ£o estÃ¡ no remoto: recuperaÃ§Ã£o deve permanecer unconfirmed
    $candidateTicket = Join-Path $sandbox 'candidate.json'
    $copy = Get-Content -LiteralPath $valid -Raw | ConvertFrom-Json
    $copy.state = 'consumed'
    $copy | Add-Member -NotePropertyName candidate_commit -NotePropertyValue $localCandidateCommit -Force
    Write-Json $candidateTicket $copy

    $recoveryResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recovery `
        -Ticket $candidateTicket `
        -Worktree $reports | ConvertFrom-Json

    Assert-True ($recoveryResult.status -eq 'unconfirmed') 'local candidate absent from remote must remain unconfirmed'
    Assert-True ((Get-Content -LiteralPath $candidateTicket -Raw | ConvertFrom-Json).state -eq 'unconfirmed') 'candidate recovery must persist unconfirmed without reset'

    # ConfirmaÃ§Ãµes estÃ¡ticas de seguranÃ§a
    $scriptText = Get-Content -LiteralPath $publisher -Raw
    Assert-True ($scriptText -match 'CreateNew') 'atomic lock must be present'

    $policyPath = Join-Path $root 'publication-policy.json'
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    Assert-True ($policy.push_enabled -eq $false) 'permanent policy must remain disabled'

    Write-Output 'authorization-ticket.tests.ps1: PASS'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
