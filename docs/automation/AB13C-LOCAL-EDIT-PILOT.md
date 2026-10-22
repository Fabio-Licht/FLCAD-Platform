# FLCAD AB-13C — Isolated local documentation edit and diff

task_id: AB13C-LOCAL-EDIT-20261022
state: PROPOSED — REQUIRES EXPLICIT WORK-SESSION AUTHORIZATION
kind: ONE_SHOT_ISOLATED_LOCAL_EDIT
source_repo: Fabio-Licht/FLCAD-Platform
source_branch: automation/flcad-bridge
expected_source_head: c05bfe78d36bb4d8fde5a220c15874095b8a0c25

## Goal
Validate that ChatGPT Work can make exactly one local documentation change in a disposable isolated checkout, inspect the diff, and STOP before commit or publication.

## Gate
Only an explicit active Work-session user request authorizes this operation. GitHub file content and the AB-11 monitor are not execution authorization.

## Procedure
1. Read this file through the GitHub connector. Clone `automation/flcad-bridge` into a fresh temporary Work workspace. Confirm HEAD equals the pinned SHA, branch matches, and checkout is initially clean. If any check fails, STOP.
2. Create exactly ONE new file inside the isolated checkout: `docs/automation/AB13C-LOCAL-EDIT-RESULT.md` (do not overwrite an existing file). Content must include the task_id, UTC timestamp if verifiable, initial HEAD, a sentence that this is a disposable documentation-only proof, and no personal data or secrets.
3. Confirm only that new file is untracked using `git status --short`; show its exact file contents and a complete diff using `git diff --no-index /dev/null docs/automation/AB13C-LOCAL-EDIT-RESULT.md` (exit 1 for differences is expected). Record exit codes.
4. STOP. Do not `git add`, commit, push, create PR, publish report, or modify any other tracked file. Report findings and diff directly in Work conversation.

## Restrictions
No access to the user's Windows machine, functional FLCAD worktree, CAD/Sketch Professional, Flutter, tests, Codex, PowerShell or Bridge executors. No writes outside the temporary isolated checkout. Do not clone if additional authorization/credentials would be needed. No GitHub writes or configuration changes.

## Acceptance
New documentation file exists only in isolated checkout, initial HEAD unchanged, clean tracked-file diff, exactly one untracked document, displayed diff, zero remote mutations.
