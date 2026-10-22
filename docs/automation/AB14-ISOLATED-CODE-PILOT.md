# FLCAD AB-14 — Isolated Python code edit and test (no CAD)

task_id: AB14-ISOLATED-CODE-20261022
state: PROPOSED — EXECUTION REQUIRES EXPLICIT USER REQUEST IN ACTIVE WORK SESSION
kind: ONE_SHOT_TEMPORARY_CODE_CHANGE
source_repo: Fabio-Licht/FLCAD-Platform
source_branch: automation/flcad-bridge
expected_source_HEAD: c05bfe78d36bb4d8fde5a220c15874095b8a0c25

## Objective
Verify Work can author and test a small Python standard-library-only policy-inspection function in an isolated temporary clone, provide the diff and evidence, and stop before Git publication. This is a NON-PRODUCTION auxiliary experiment, not a change to the existing Bridge policy or authorization decisions.

## Authorization and isolation
Only after the user explicitly asks Work to execute AB14-ISOLATED-CODE-20261022 in that active Work session, clone the source branch into a NEW disposable temporary directory. Verify branch, exact HEAD, clean Git status; otherwise STOP. Do not access the user's Windows computer or functional CAD worktree.

## Exactly allowed new files in the disposable checkout
- tools/flcad_automation/ab14_policy_inspector.py
- tools/flcad_automation/ab14_policy_inspector_test.py
Do NOT modify any preexisting file, especially publication-policy.json, task.schema.json, scripts or CAD files. Do NOT import or execute repository scripts.

## Code behavior
Implement `inspect_policy_text(raw: str) -> dict` using only Python standard library `json`. Parse a JSON string and return a data summary with these four keys only:
- `destination_branch`: policy's destination_branch when a string, else null;
- `push_enabled`: true/false only when policy's push_enabled has boolean type, else null;
- `push_mode`: string value or null;
- `allowed_file_count`: length of allowed_files only when it is a list, else null.
Raise `ValueError` when JSON is invalid or root is not an object.
This is reporting only: must NEVER change policy, authorize publishing, infer approval from values, modify files, or make network calls.

Implement isolated unittest tests using `unittest` and JSON fixture strings inline, covering:
1. Typical policy with push_enabled=false, operator-authorized-only, 3 allowed_files;
2. true value is reported truthfully WITHOUT granting permission;
3. invalid JSON raises ValueError;
4. JSON array as root raises ValueError;
5. wrongly typed fields return null rather than coercion (e.g., string "false").
No extra dependencies.

## Only permitted commands
Existing git clone/checkout inspection in the temporary clone; `python3 -B -m unittest tools/flcad_automation/ab14_policy_inspector_test.py -v` from repository root, using stdlib only; `git diff --no-index /dev/null <newfile>` for each file (exit 1 is expected); `git status --short`, `git diff --exit-code`, `git rev-parse HEAD`, `git branch --show-current`. For avoiding `__pycache__`, export `PYTHONDONTWRITEBYTECODE=1`. If the module import requires path setup, use explicit sys.path insertion only inside the new test file to import the new module from the same folder. Do not run other tests. No installation.

## Expected evidence
Report commands and exit codes, tests passed/failed, both full new-file diffs, exactly two untracked Python files and zero tracked modifications, original HEAD unchanged. Provide source of findings, do not assert production runtime enforcement.

## Forbidden
Codex CLI, PowerShell, Bridge executor/orchestrator, CAD, Flutter, OCCT, dependency installation, access to functional worktree, credentials, changes to GitHub or any other branch, git add, commit, push, merge, PR, Actions, publication of results, background execution. No retries with relaxed permissions.

## Outcomes
PASS_ISOLATED_CODE_TEST when five unittest cases pass and checkout remains limited to two new files; PARTIAL when checks cannot be completed; BLOCKED for absent runner or wrong HEAD; STOP for safety/authorization issue.
