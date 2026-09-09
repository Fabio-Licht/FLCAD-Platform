param([Parameter(Mandatory = $true)][string]$BundlePath)
$ErrorActionPreference = 'Stop'
$bundle = (Resolve-Path -LiteralPath $BundlePath).Path
$executable = Join-Path $bundle 'flcad_mobile.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Missing application executable' }
$gateRoot = Join-Path $env:TEMP ('flcad-caf-app-gate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $gateRoot -ErrorAction Stop | Out-Null
$previousRoot = $env:FLCAD_CAD_SMOKE_ROOT
$previousHelper = $env:FLCAD_CAD_ASSET_FS_DLL
$appProcess = $null
try {
    $env:FLCAD_CAD_SMOKE_ROOT = $gateRoot
    $env:FLCAD_CAD_ASSET_FS_DLL = $null
    $appProcess = Start-Process -FilePath $executable -WorkingDirectory $bundle -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $gateRoot 'app.stdout.log') -RedirectStandardError (Join-Path $gateRoot 'app.stderr.log')
    # Retain the process handle to observe its exit code after the window closes.
    $null = $appProcess.Handle
    Write-Output "SMOKE_ROOT=$gateRoot"
    Write-Output "SMOKE_PID=$($appProcess.Id)"
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while (-not (Test-Path -LiteralPath (Join-Path $gateRoot 'smoke-complete'))) {
        if ($appProcess.HasExited) { throw "App exited before report: $($appProcess.ExitCode)" }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Smoke report timed out' }
        Start-Sleep -Milliseconds 100
    }
    $report = Get-Content -LiteralPath (Join-Path $gateRoot 'smoke-result.json') -Raw | ConvertFrom-Json
    if ($report.status -ne 'PASS') { throw "Smoke failed: $($report.error)" }
    $modules = @($appProcess.Modules | Where-Object { $_.ModuleName -eq 'cad_asset_fs.dll' })
    if ($modules.Count -ne 1 -or $modules[0].FileName -ne (Join-Path $bundle 'cad_asset_fs.dll')) { throw 'Unexpected loaded helper module' }
    if (@($appProcess.Modules | Where-Object { $_.ModuleName -eq 'flcad_opencascade.dll' }).Count -ne 0) { throw 'OpenCascade must not be loaded by filesystem smoke' }
    $payloadPath = Join-Path $report.project ('CAD\Assets\v1\' + $report.asset + '\source\original.bin')
    $bytes = [IO.File]::ReadAllBytes($payloadPath)
    if ($bytes.Length -ne 131079) { throw 'Independent payload size mismatch' }
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne ($index % 251)) { throw "Independent payload mismatch at $index" }
    }
    if ((Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $report.payload.sha256) { throw 'Independent SHA-256 mismatch' }
    $handlesBeforeClose = $appProcess.HandleCount
    if (-not $appProcess.CloseMainWindow()) { throw 'Cannot send WM_CLOSE to owned app window' }
    if (-not $appProcess.WaitForExit(10000)) { throw 'Owned app did not exit after WM_CLOSE' }
    if ($appProcess.ExitCode -ne 0) { throw "App exit code: $($appProcess.ExitCode)" }
    $evidence = [ordered]@{ status = 'PASS'; pid = $appProcess.Id; exitCode = $appProcess.ExitCode; handlesBeforeWindowClose = $handlesBeforeClose; processExited = $appProcess.HasExited; helper = $modules[0].FileName; openCascadeLoaded = $false; independentPayloadVerified = $true; root = $gateRoot }
    $json = $evidence | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $gateRoot 'process-result.json'), $json)
    Write-Output $json
} finally {
    if ($null -ne $appProcess) {
        if (-not $appProcess.HasExited) {
            $null = $appProcess.CloseMainWindow()
            $null = $appProcess.WaitForExit(10000)
        }
        $appProcess.Dispose()
    }
    $env:FLCAD_CAD_SMOKE_ROOT = $previousRoot
    $env:FLCAD_CAD_ASSET_FS_DLL = $previousHelper
}
