# SKETCH-10C2 — Contextual Selection Panel

## Status

Implemented in the isolated `feat/sketch-10a-offset` worktree. Automated critical gates passed. The Windows Debug artifact was built for experimental manual evaluation; this is not a production integration approval.

## Diagnosis

The Sketch editing commands already used `selectedSketchEntityIds` as their effective selection. A second selection store was unnecessary and would risk divergence. The viewport pick callback first delivered the pick to `OperationalReverseEngineeringController`, then unconditionally wrote that one entity into the shared geometry-selection service. That write collapsed the command's ordered multi-selection after each pick. This was the concrete cause of the contextual selection not faithfully representing the command input.

## Changes for C2

- `lib/app/desktop/desktop_application.dart`: added a compact command selection section inside the existing Modify panel. It presents the active command, ordered entity IDs and types, command roles, validation feedback, per-entity removal, Clear, and row focus/highlight.
- `lib/app/engineering_bridge/operational_reverse_engineering_controller.dart`: exposed an immutable ordered view over the existing command-selection set and callbacks for validation, focus, removal, clearing, and stale-selection reconciliation. No duplicate selection model was introduced. History cleanup now reconciles selection after Undo/Redo; Sketch switching cancels the active editing tool; duplicate and missing picks produce visible diagnostics.
- `lib/app/engineering_bridge/operational_reverse_engineering_controller.dart`: after a successful Extend, clear the global viewport selection at the same time as the command selection. A new real-callback test reproduced stale viewport-highlight IDs after the command had completed; this was a confirmed panel/viewport synchronization defect.
- `lib/app/engineering_bridge/operational_reverse_engineering_controller.dart`: entity deletion now clears both command and runtime selection. Extend validation explicitly rejects more than two lines.
- `test/sketch_operator_functional_flow_test.dart`: added real viewport callback coverage for line, arc, spline, Fillet, Chamfer, Trim, and Extend selection; order/roles, removal, Clear, and tool switching are asserted. Added Extend cleanup and Delete→Undo regressions. Updated the two-Sketch helper to await the real asynchronous reopen callback rather than sleeping for a fixed interval.

No solver or geometric tolerance was changed for C2. Existing SKETCH-10A/B/C1 changes in this worktree remain present and were preserved.

## Evidence and tests

| Command / suite | Result |
|---|---|
| `flutter test --no-pub test/sketch_operator_functional_flow_test.dart` | PASS, 38/38, exit 0; final run includes Extend selection cleanup and Delete→Undo invariance |
| `flutter test --no-pub test/sketch_operator_functional_flow_test.dart --plain-name "Trim and Extend panel follow actual viewport picks and tool changes"` | PASS, 1/1, exit 0; isolated run after Extend and Delete corrections |
| `flutter test --no-pub test/sketch_offset_geometry_test.dart` | PASS, 21/21, exit 0 |
| `flutter test --no-pub test/g129_1_driving_dimensions_test.dart` | PASS, 25/25, exit 0 |
| `flutter test --no-pub test/sketch_editor_test.dart` | PASS, 11/11, exit 0 |
| `flutter analyze --no-pub` | PASS, no issues, exit 0 (final run: 148.8 s) |
| `git diff --check` | PASS, exit 0; Git emitted line-ending conversion warnings for generated Flutter registrants |
| Full repository Flutter suite | SKIPPED; the complete functional-flow file and focused relevant suites ran, but this is not a global-suite result |
| Panel-specific Escape selection cleanup, panel selection cleanup after switching Sketches, Extend >2 diagnostic, and 800×600 layout | SKIPPED as dedicated assertions; Escape behavior is covered for Offset preview, and existing Sketch-switch flows run, but panel cleanup at those exact boundaries was not separately asserted |
| Manual Windows interaction / multiple-monitor validation | SKIPPED; no UI automation was performed and no manual operator result is claimed |

The functional-flow suite uses a 1440×720 widget viewport. The contextual panel and its actions were exercised without layout exceptions in that suite; a distinct 800×600/manual desktop layout check was not run.

## Debug artifact

Built after the final production changes and critical tests with `flutter build windows --debug --no-pub` (PASS, exit 0, 61.8 s). The executable's native hash is unchanged from prior builds; the separately packaged Dart snapshot was regenerated after the Extend and Delete fixes.

- Executable: `build/windows/x64/runner/Debug/flcad_mobile.exe`
- Executable SHA-256: `6BA03EA304481768BC401222A07480C94C0A421018A5596FF1DF129688E2FE63`
- `kernel_blob.bin`: `build/windows/x64/runner/Debug/data/flutter_assets/kernel_blob.bin`
- Kernel SHA-256: `96A21459FA66588A58997CE84B804B42DBBB961D0C72024D09C306C97ADA447C`
- `cad_asset_fs.dll` SHA-256: `61D2A2349ECB726EAF1EEB5855F3653933FDB201F481D1805EB3992689EFA680`
- `flcad_opencascade.dll` SHA-256: `DD1673230E89F954DDF74335097C5F0B7CD309689CF405F35F16362D403FA102`
- `cad_occ_bridge.dll` SHA-256: `2E33B6D6E5E56B982698A87F1B4A7E273ECAEBF31790B8EDFD5BD908AE65BD75`

The native files were present in the Debug output and hashed. This run did not launch the application or independently exercise dynamic loading of each DLL.

## Review and decision

Internal diff review confirmed that the panel projects the existing ordered selection and delegates changes to the controller; viewport picks no longer overwrite that command selection. Independent read-only Codex review: **GO for experimental manual evaluation / NO-GO for production**. The reviewer confirmed Extend and Delete synchronize the command and runtime selections and that the new Delete→Undo test covers stale IDs. The reviewer did not execute tests or verify the build. Dedicated 800×600, Escape/lifecycle, and multi-monitor checks remain risks to assess manually; no new detached or multi-monitor behavior is claimed.

- Experimental manual evaluation: **GO**, limited to the isolated Debug build; ask the operator to verify selection, Extend/Delete cleanup, and compact 800×600 layout.
- Production integration: **NO-GO** pending manual confirmation, dedicated lifecycle/layout assertions, full repository-suite decision, and subsequent integration authorization.
- Git: no staging, commit, push, merge, PR, or release was performed.
