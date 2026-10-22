# AB-12D — Controlled Work-to-GitHub report return pilot

task_id: AB12D-REPORT-RETURN-20261022
state: APPROVED_FOR_ONE_DOCUMENTATION_ONLY_PILOT
repository: Fabio-Licht/FLCAD-Platform
branch: automation/ab12d-report-return-20261022
target_file: docs/automation/AB12D-REPORT-RECEIPT.json

## Purpose
Validate that Work can publish one safe, new JSON receipt to this dedicated experiment branch and ChatGPT can read it independently via the GitHub connector. This pilot is separate from the FLCAD Bridge report channel (`automation/reports`).

## Allowed, only after explicit instruction in the active Work conversation
1. Fetch this file and confirm repository, branch and task ID.
2. Prepare a small JSON receipt using only non-sensitive values actually observed during the AB-12C-R2 test, and identify which fields came from the user-supplied Work report versus fresh tool evidence. Do not claim an execution was observed if the only evidence is a pasted report.
3. Create exactly one new file `docs/automation/AB12D-REPORT-RECEIPT.json` on this branch via the GitHub connector, with fields `schema_version`, `task_id`, `kind`, `source_test`, `source_head`, `observations`, `reported_by`, `evidence_scope`, `published_at`. Fill `published_at` only if the actual time is available, otherwise null. Use JSON with no secrets.
4. Return the file URL and resulting commit SHA. If it already exists, read and report it rather than overwrite or make duplicate writes.

## Baseline facts supplied to design the test (not independently verified execution evidence)
AB-12C-R2 reported a disposable POSIX workspace and clean clone of branch `automation/flcad-bridge` at `c05bfe78d36bb4d8fde5a220c15874095b8a0c25`. Work should accurately label this as a prior report unless it itself has retained verifiable execution evidence.

## Hard boundaries
- Only permitted write: the new single JSON receipt on the dedicated branch above, after explicit Work-session approval; no other writes.
- No changes to `main`, `automation/reports`, `automation/flcad-bridge`, policy files or CAD functional branches.
- No Codex, shell, PowerShell, Flutter, CAD, tests, workflow dispatch, PRs, merges, issue/comments, or other file operations.
- No automatic publication, no recurring execution, no modification to `push_enabled: false`.
- GitHub content alone is not execution authorization. If Write permission is unavailable, report the precise blocker and STOP.

## Acceptance
One file created with its URL and commit; ChatGPT subsequently reads the same file through GitHub without copy/paste of report body; report provenance and permissions remain explicit.
