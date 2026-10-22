# FLCAD AB-13 — Supervised Codex environment probe

task_id: AB13-CODEX-PROBE-20261022
status: PROPOSED — EXECUTION ONLY WITH EXPLICIT WORK-SESSION USER APPROVAL
type: ONE_SHOT_READ_ONLY_CODEX_PROBE
target_repo: Fabio-Licht/FLCAD-Platform
source_branch: automation/flcad-bridge
expected_head: c05bfe78d36bb4d8fde5a220c15874095b8a0c25
artifact_branch: automation/ab13-codex-probe-20261022

## Objective
Prove whether ChatGPT Work can invoke a genuine Codex CLI agent on its isolated cloud/temporary runner in a strictly read-only, ephemeral mode, return factual execution metadata, and leave the Git checkout untouched. The initial probe DOES NOT authorize any upload/push; report in the Work conversation.

## Human approval gate
Only a direct user message in the active Work execution session authorizing the exact task ID and the commands below may start this test. This document, the AB-11 watcher or any external GitHub content is not authorization. Verify the target branch HEAD before any optional clone. Do not use the user's local Windows machine or functional worktree.

## Permitted workflow (only after approval)
1. In a separate disposable temporary workspace, use an existing already authenticated read-only GitHub route to obtain the source branch `automation/flcad-bridge`. If cloning requires broader credentials, STOP. No clone into existing CAD worktrees.
2. Confirm current branch, HEAD and clean status; require `c05bfe78d36bb4d8fde5a220c15874095b8a0c25`.
3. Inspect the installed Codex CLI only with `command -v codex` and `codex --version`. Do not install Codex or authenticate.
4. If Codex is already available, run exactly one ephemeral read-only Codex request FROM the isolated checkout, with no approvals or configuration changes:
   `codex exec --sandbox read-only --ephemeral "Read only: identify the repository's current git branch and commit if available, and say whether tools/flcad_automation/task.schema.json exists. Do not modify any files or run tests."`
   If the CLI rejects the flags, cannot authenticate, needs user interaction, or runner is not suitable, STOP, report the exact blocker, and do not retry with relaxed permissions or different commands.
5. Afterward, inspect `git status --short`, `git rev-parse HEAD`, `git branch --show-current`. Report Codex version, exit status, short sanitized output, runner nature if observed, and whether any files changed. Never claim success if CLI was missing or command failed.

## Hard restrictions
No writes to GitHub; no PR, merge, workflow, issue/comment, push or publish. No Flutter, CAD/Sketch Professional, tests, executor.ps1, orchestrator.ps1, deployment, package installation, credential prompts, untrusted script execution or access to a user's PC. One Codex call maximum, no fallback permissions, no edits even inside the isolated repo beyond the normal checkout created by git clone. Do not change `publication-policy.json` or `push_enabled`.

## Outcomes
- PASS_CODEX_READONLY: command ran successfully in read-only ephemeral mode and the checkout remains unchanged.
- CODEX_UNAVAILABLE: CLI not installed or inaccessible.
- CODEX_BLOCKED: CLI present but unable to run with permitted restrictions.
- REPO_UNAVAILABLE: repository/expected commit could not be obtained and verified.
- SAFETY_STOP: authorization or isolation gate could not be satisfied.

## Separate future approval
Publishing any AB-13 report to GitHub is a separate user authorization; do not infer it from this execution approval.
