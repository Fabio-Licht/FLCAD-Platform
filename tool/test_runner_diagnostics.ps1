param(
  [string]$TestPath = "test",
  [int]$TimeoutSeconds = 30,
  [switch]$DedicatedM005
)

$ErrorActionPreference = "Stop"
$flutter = if ($env:FLUTTER_ROOT) {
  Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"
} else {
  "flutter"
}

Write-Host "TEST RUNNER"
Write-Host "Loading package..."
$root = (Get-Location).Path
if ($DedicatedM005) {
  $TestPath = "test/reference_geometry_test.dart"
}
$target = Join-Path $root $TestPath
if (-not (Test-Path $target)) {
  throw "Test path not found: $TestPath"
}
$files = if ((Get-Item $target).PSIsContainer) {
  Get-ChildItem $target -File -Recurse -Filter "*_test.dart"
} else {
  @(Get-Item $target)
}
$files = $files | Sort-Object FullName
Write-Host "Import completed"
Write-Host "Bootstrap ready"
Write-Host "Tests discovered: $($files.Count)"
if ($files.Count -eq 0) {
  throw "No test files discovered under: $TestPath"
}

foreach ($file in $files) {
  $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $stdout = New-TemporaryFile
  $stderr = New-TemporaryFile
  try {
    $process = Start-Process $flutter `
      -ArgumentList @("test", "--no-pub", "--machine", $relative) `
      -PassThru -NoNewWindow `
      -RedirectStandardOutput $stdout.FullName `
      -RedirectStandardError $stderr.FullName
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill($true)
      throw "TIMEOUT after ${TimeoutSeconds}s: $relative"
    }
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = $process.ExitCode
    $events = @(Get-Content $stdout.FullName | Where-Object { $_.Trim() })
    $first = $events | Select-Object -First 1
    $last = $events | Select-Object -Last 1
    $testIds = @(
      $events |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
        Where-Object { $_.type -eq "test" -and $_.testID } |
        Select-Object -ExpandProperty testID -Unique
    )
    Write-Host "Running first test: $relative"
    Write-Host "  first-event-ms=$($timer.ElapsedMilliseconds)"
    Write-Host "  first=$first"
    Write-Host "  last=$last"
    Write-Host "  tests-executed=$($testIds.Count)"
    if ($testIds.Count -eq 0) {
      throw "NO TEST EVENTS: $relative"
    }
    if ($last -notmatch '"type":"done"' -or $last -notmatch '"success":true') {
      throw "FAILED ($exitCode): $relative; last event: $last"
    }
  } finally {
    Remove-Item $stdout.FullName, $stderr.FullName -Force
  }
}
