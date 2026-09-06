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
  $requestedPaths = @(
    "test/core/metric_reference_test.dart",
    "test/core/metric_reference_system_test.dart",
    "test/reference_geometry_test.dart"
  )
} else {
  $requestedPaths = @($TestPath)
}
$files = @(
  foreach ($requestedPath in $requestedPaths) {
    $target = Join-Path $root $requestedPath
    if (-not (Test-Path $target)) {
      throw "Test path not found: $requestedPath"
    }
    if ((Get-Item $target).PSIsContainer) {
      Get-ChildItem $target -File -Recurse -Filter "*_test.dart"
    } else {
      Get-Item $target
    }
  }
)
$files = @($files | Sort-Object FullName -Unique)
$requestedDescription = $requestedPaths -join ", "
$totalExecuted = 0
$totalPassed = 0
$totalFailed = 0
$totalSkipped = 0
$totalFiles = 0
$files = @($files)
$files = if ($files.Count -gt 0) {
  $files
} else {
  @()
}
Write-Host "Import completed"
Write-Host "Bootstrap ready"
Write-Host "Tests discovered: $($files.Count)"
if ($files.Count -eq 0) {
  throw "No test files discovered under: $requestedDescription"
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
    $lines = @(Get-Content $stdout.FullName | Where-Object { $_.Trim() })
    $first = $lines | Select-Object -First 1
    $last = $lines | Select-Object -Last 1
    $events = @(
      $lines | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
      } | Where-Object { $null -ne $_ }
    )
    $startEvents = @($events | Where-Object { $_.type -eq "start" })
    $doneEvents = @($events | Where-Object { $_.type -eq "done" })
    $testStarts = @($events | Where-Object {
      $_.type -eq "testStart" -and $null -ne $_.test -and $null -ne $_.test.id
    })
    $testDones = @($events | Where-Object {
      $_.type -eq "testDone" -and $null -ne $_.testID
    })
    $testIds = @($testStarts | ForEach-Object { $_.test.id } | Sort-Object -Unique)
    $completedIds = @($testDones | ForEach-Object { $_.testID } | Sort-Object -Unique)
    $passed = @($testDones | Where-Object {
      $_.result -eq "success" -and $_.skipped -ne $true
    }).Count
    $failed = @($testDones | Where-Object { $_.result -eq "failure" -or $_.result -eq "error" }).Count
    $skipped = @($testDones | Where-Object { $_.skipped -eq $true }).Count
    Write-Host "Running first test: $relative"
    Write-Host "  first-event-ms=$($timer.ElapsedMilliseconds)"
    Write-Host "  first=$first"
    Write-Host "  last=$last"
    Write-Host "  tests-executed=$($testIds.Count)"
    Write-Host "  tests-passed=$passed tests-failed=$failed tests-skipped=$skipped"
    if ($startEvents.Count -eq 0) {
      throw "NO PROTOCOL START EVENT: $relative"
    }
    if ($testIds.Count -eq 0) {
      throw "NO TEST START EVENTS: $relative"
    }
    $unmatchedIds = @(Compare-Object $testIds $completedIds)
    if ($unmatchedIds.Count -ne 0) {
      throw "INCOMPLETE TEST EVENTS: $relative; started=$($testIds.Count), completed=$($completedIds.Count)"
    }
    $done = $doneEvents | Select-Object -Last 1
    if ($doneEvents.Count -eq 0 -or $done.success -ne $true -or $exitCode -ne 0) {
      $errorText = ""
      if (Test-Path -LiteralPath $stderr.FullName) {
        $rawErrorText = Get-Content -LiteralPath $stderr.FullName -Raw
        if ($null -ne $rawErrorText) {
          $errorText = $rawErrorText.Trim()
        }
      }
      throw "FAILED ($exitCode): $relative; done-success=$($done.success); stderr=$errorText"
    }
    $totalFiles++
    $totalExecuted += $testIds.Count
    $totalPassed += $passed
    $totalFailed += $failed
    $totalSkipped += $skipped
  } finally {
    Remove-Item $stdout.FullName, $stderr.FullName -Force
  }
}

Write-Host "TEST RUNNER SUMMARY"
Write-Host "  files=$totalFiles"
Write-Host "  tests-executed=$totalExecuted"
Write-Host "  tests-passed=$totalPassed tests-failed=$totalFailed tests-skipped=$totalSkipped"
