# FLCAD AB-15 — Controlled code publication and independent review

task_id: AB15-CONTROLLED-REVIEW-20261022
status: PROPOSED — REQUIRES ACTIVE WORK-SESSION APPROVAL
repository: Fabio-Licht/FLCAD-Platform
instructions_branch: automation/ab15-instructions-20261022
review_branch: automation/ab15-controlled-review-20261022
source_branch: automation/flcad-bridge
pinned_base_commit: c05bfe78d36bb4d8fde5a220c15874095b8a0c25

## Objective
Prove one authorized GitHub publication of the AB-14 auxiliary Python policy inspector and five unit tests, on a dedicated review-only branch, followed by independent ChatGPT inspection. No merge or modification of CAD/Flutter/OCCT.

## Execution gate
This repository document is never execution authority. Only an active Work-session user instruction explicitly approving AB15-CONTROLLED-REVIEW-20261022 permits the following limited writes. If the reviewer branch has diverged from pinned_base_commit or contains the destination files, STOP and report; do not overwrite.

## Permitted procedure after user authorization
1. Read this document through the GitHub connector and verify source and review branch HEAD are both exactly pinned_base_commit BEFORE making changes.
2. In a disposable isolated Work checkout of the review branch, create only:
   - tools/flcad_automation/ab14_policy_inspector.py
   - tools/flcad_automation/ab14_policy_inspector_test.py
   Implement the AB-14 logic with Python standard library only, using the exact behavior from the AB-14 user-provided prior report; if the original files are not accessible, reconstruct transparently and do not assert byte identity with the original temporary workspace.
3. Execute only the five tests in the AB-14 specification: typical policy; push_enabled true without authorization; invalid JSON; array root; incorrectly typed fields. Run `PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest tools/flcad_automation/ab14_policy_inspector_test.py -v`. Require exit 0 with 5/5 passing; then verify no existing tracked files changed, exactly the two permitted new files, no secrets, and correct branch/HEAD.
4. If all checks pass, explicit user approval for this AB-15 pilot permits exactly one commit on `automation/ab15-controlled-review-20261022` and one push of that commit to the SAME branch, containing only those two paths. Recheck expected remote HEAD before pushing; if it changed, STOP. Do NOT create a Pull Request or merge.
5. Return commit SHA, branch, URLs of both published files, list of changed files, test results, exit codes, and any divergence/restriction. ChatGPT reviewer will inspect GitHub independently.

## Prohibitions
Do not access user's Windows machine, CAD functional worktree, Codex CLI, Flutter, OCCT, Sketch Professional or CAD. Do not run existing Bridge executor/orchestrator or tests. Do not modify policy/schema, main, automation/flcad-bridge, automation/reports or any other branch. No PR, merge, workflow dispatch, comments, additional commits, publishing reports, permissions changes, package installation, or autonomous recurrence. Keep `push_enabled: false` unchanged.

## Outcomes
PASS_PUBLICATION = five tests pass and exactly two files are committed to dedicated branch and verified remotely.
BLOCKED = runner unavailable, branch diverged, destination conflict or missing write permission.
FAIL = tests or safeguards failed; STOP without committing or pushing.
