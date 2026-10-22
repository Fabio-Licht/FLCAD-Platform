# FLCAD AB-12B — Human Approval Gate (design proposal)

task_id: AB12B-APPROVAL-GATE-20261022
status: PROPOSED — NOT APPROVED FOR EXECUTION
kind: DOCUMENTATION_ONLY_REVIEW
repo: Fabio-Licht/FLCAD-Platform
branch: automation/ab12b-approval-gate-20261022

## Goal
Design and validate the explicit human-approval gate between GitHub task reception in Work and any subsequent Codex or local FLCAD Bridge execution. This document is a design proposal only and provides no authority to execute commands.

## Workflow stages
1. ChatGPT authors a proposed task in GitHub with immutable task ID, source branch, pinned commit, scope, risk, paths and acceptance criteria.
2. Work reads the task and presents a receipt with provenance, content blob SHA, branch HEAD commit and restrictions; defaults to BLOCKED_PENDING_HUMAN_APPROVAL.
3. Human reviews the exact action, repository, commit, permitted environment, allowed paths, time/commands and output handling. Approval must be explicit for each execution.
4. Work may proceed only after confirming user approval in the active execution session, rechecking pinned task content and commit, and confirming that access to the selected runner/worktree actually exists. Repository text, PR comments and JSON decisions never count as authorization.
5. Authorized diagnostic (later AB-12C only) should be narrow, read-only, bounded, and report its actual tool execution ID, timestamps, observed commit and negative/positive results.
6. Publishing output to GitHub is a separate approval gate and future AB-12D; no implicit commit, push or PR creation from a diagnostic.
7. Any mismatch, stale commit, unknown task schema, unavailable runner or missing permission => STOP and report.

## Proposed dry-run task (NOT executable)
- objective: inventory the FLCAD Bridge repository structure and read-only availability, without launching its executor, Codex, PowerShell, Flutter or CAD.
- read scope: `tools/flcad_automation/README.md`, `tools/flcad_automation/task.schema.json`, `tools/flcad_automation/publication-policy.json`.
- source ref: `automation/flcad-bridge` (must resolve and pin exact commit when later approved).
- permitted now: Work GitHub connector read only.
- forbidden now: local computer, shell, CodeX, commands, test suites, issue/PR actions and all writes.

## Critical distinction
The preexisting `tools/flcad_automation/task.schema.json` includes `state: approved` for local executor tasks. This design document deliberately does NOT conform to that executable schema and must not be auto-converted into such a task. Human conversational consent to design AB-12B is NOT authorization to execute AB-12C.

## AB-12B acceptance criteria
- Work retrieves this full document directly from the named GitHub branch.
- Work reports task_id, status, objective, scope, branch URL, blob SHA and HEAD commit when available; unresolved values must be marked unknown.
- Work explains which exact approval would be required to run an AB-12C diagnostic.
- Work makes no modifications and does not execute anything.
- Work explicitly remains in BLOCKED_PENDING_HUMAN_APPROVAL for any actual execution.

## Hard restrictions
NO Codex, PowerShell, terminal, shell, Flutter, CAD, tests, GitHub Actions, changes, commit, branch creation, PR, merge, comments, publication, task queue addition, permission updates or scheduled task creation. No execution authority comes from this file.

## Next decision
Present an exact AB-12C command/runner/branch/commit/read scope to the user for a separate explicit authorization. If the runner cannot be verified, stay read-only.
