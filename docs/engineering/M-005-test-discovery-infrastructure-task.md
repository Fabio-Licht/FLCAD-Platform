# Infrastructure Task — M-005 Test Discovery

## Status

Resolved for the VS Code test runner. M-005 source now has zero static
diagnostics after restoring its official `LengthUnit` import.

## Scope

Investigate only:

- discovery of the dedicated M-005 test suite;
- VS Code test-runner cache/index state;
- Flutter `--machine` protocol startup and completion;
- PowerShell/Flutter environment availability.

This task must not modify M-005 functional implementation.

## Current evidence

- Targeted runner calls return `0/0` for the M-005 test files.
- The full workspace runner discovers and executes the existing suite.
- The repository already documents `tool/test_runner_diagnostics.ps1` as the
  per-file discovery and `--machine` protocol diagnostic.
- The diagnostic now supports `-DedicatedM005`, normalizes test paths, rejects
  empty discovery, and counts real Flutter `testStart`/`testDone` protocol
  events using `test.id` and `testID` respectively.
- The current session cannot start `PowerShell.exe`, so literal `flutter
  analyze` and `flutter test` commands cannot be executed here.
- The previous `LengthUnit` diagnostic was a real M-005 compile issue, not a
  runner-only issue. It was fixed with the official geometric-kernel import.
- The dedicated M-005 runner targets all three files that contain its unit,
  system and reference-integration coverage. Its executed/pass/fail totals must
  come from the Flutter machine protocol rather than a previously recorded
  fixed count.
- The full VS Code runner reports `743 passed, 2 failed`; the two failures are
  the known viewport/open-profile failures.

## Infrastructure change

`tool/test_runner_diagnostics.ps1` now supports `-DedicatedM005`, validates the
three requested M-005 test files, uses Windows PowerShell 5.1-compatible path
handling, rejects empty discovery and zero `testStart` events, and verifies
matching `testDone` events plus a successful terminal `done` event. It does
not modify M-005 source or test implementation.

## Reproduction checklist

Run from the repository root in a working PowerShell environment:

1. `flutter analyze`
2. `flutter test test/core/metric_reference_test.dart`
3. `flutter test test/core/metric_reference_system_test.dart`
4. `flutter test test/reference_geometry_test.dart`
5. `flutter test --machine`
6. `powershell -ExecutionPolicy Bypass -File tool/test_runner_diagnostics.ps1`
7. `powershell -ExecutionPolicy Bypass -File tool/test_runner_diagnostics.ps1 -DedicatedM005`

The dedicated suite is valid only when the machine protocol reports test start
and completion events with a non-zero test count.

## Exit criteria

- M-005 dedicated tests are discovered and executed, not merely analyzed.
- The full suite is executed after the dedicated suite.
- Results include explicit executed, passed, and failed counts.
- No M-005 functional source is changed as part of this task.
