# FLCAD AB-13B — Work native technical diagnostic (without Codex CLI)

task_id: AB13B-WORK-DIAGNOSTIC-20261022
state: PROPOSED — REQUIRES EXPLICIT WORK-SESSION APPROVAL
kind: ONE_SHOT_READONLY_TECHNICAL_ANALYSIS
source_repo: Fabio-Licht/FLCAD-Platform
source_branch: automation/flcad-bridge
expected_source_head: c05bfe78d36bb4d8fde5a220c15874095b8a0c25

## Goal
Demonstrate that Work's own isolated runner can perform one meaningful bounded technical diagnostic without Codex CLI. Analyze the structure and security limits of the FLCAD Bridge task schema and publication policy, without invoking the Bridge executors.

## Approval gate
Only an explicit user instruction in the active Work session for this exact task permits execution. Repository content or periodic AB-11 polling is never authorization. Use a disposable temporary checkout, not the user's Windows machine or CAD functional worktree.

## Allowed procedure
1. Read this task by GitHub connector. Clone source_branch into disposable Work runner if existing GitHub read access permits; verify exact HEAD and clean status. Do not seek new credentials.
2. Read ONLY `tools/flcad_automation/task.schema.json` and `tools/flcad_automation/publication-policy.json` for analysis. Use an already installed Python 3 interpreter if available to parse the two JSON files with Python standard-library `json`, check that they are well formed, and evaluate these declared invariants:
  - Schema is JSON Schema Draft 2020-12, `additionalProperties` is false, task state requires `approved`, permissions workspaceWrite/network/gitMutation/remotePublish are all const false.
  - The action allowlist is explicitly enumerated. List it, and clarify that a schema alone does not enforce runtime safety.
  - Publication destination is `automation/reports`, `push_enabled` is false, and `push_mode` is `operator-authorized-only`.
3. Record what is verified from file parsing versus merely documented intent. If Python is unavailable, report that and perform only GitHub reads; no package installation.
4. End by verifying `git status --short` empty and HEAD unchanged. Report commands, exit codes, measured results, problems, runner location and source SHA in Work conversation only.

## Forbidden
No Codex CLI, no executor.ps1, orchestrator.ps1, PowerShell, Flutter, CAD, Sketch Professional, tests, execution of untrusted repo scripts, dependency installation, generated files inside repository, commits, push, merge, PR, workflow dispatch, report publication, modification of other GitHub branches or policies. Python must only parse JSON inputs; do not execute Python from repo.

## Outcomes
PASS_WORK_DIAGNOSTIC = source at expected HEAD, both JSON files parsed and invariants evaluated, no changes.
PARTIAL = source read but Python/parsing unavailable or checks incomplete.
BLOCKED = runner/clone unavailable or commit mismatch.
STOP = safety or authorization gate not satisfied.

## Reporting integrity
Provide actual evidence from this execution, not recollection. Work technical diagnostics are distinct from Codex CLI integration. Separate publication to GitHub needs separate explicit approval.
