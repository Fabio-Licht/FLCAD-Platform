# FLCAD AB-18 — Queue-to-executor handoff architecture pilot

task_id: AB18-QUEUE-HANDOFF-20261022
status: PROPOSED_READONLY
repository: Fabio-Licht/FLCAD-Platform
branch: automation/ab18-queue-handoff-20261022
base_commit: c05bfe78d36bb4d8fde5a220c15874095b8a0c25
queue_path: docs/automation/AB18-QUEUE-TASK.json
risk: LOW_READ_ONLY

## Purpose
Test whether a proposed next-task document can be delivered via GitHub and discovered without manual copy/paste. A scheduled ChatGPT inbox can read it, but this does NOT start ChatGPT Work, Codex or any executor. No system should treat this file as permission to execute.

## Stage A — read-only queue discovery
1. Publish the JSON queue item on this dedicated branch with state PROPOSED_READONLY and no execution permissions.
2. Configure the existing scheduled AB-11 inbox monitor to additionally poll this branch/path hourly, preserving its current AB-11 monitoring.
3. The monitor validates JSON fields, task ID, HEAD, blob SHA, changed-file metadata and reports the pending item with a concise next-prompt proposal. No code execution or writes.

## Stage B — executor adapter (NOT IMPLEMENTED OR AUTHORIZED)
Identify an authenticated, supported workflow or runner that can poll the queue and be invoked after explicit human approval. Requirements:
- persistent service or event/poll trigger with an actual launch capability (not merely a GitHub file or ChatGPT notification);
- exact task schema validation, idempotency and task claiming;
- authenticated identity, least privilege and isolation;
- finite execution scope and allowlist of paths and commands;
- human approval for any code execution; separate additional permission for CAD/Windows;
- read-only inspection first, with immutable traceability and result publication;
- explicit stop on failure and no unbounded agent loops.
A ChatGPT task automation and GitHub connector alone are not verified to start Work/Codex autonomously.

## Success criteria
Stage A PASS only when the scheduled inbox successfully observes and validates this new queue item without the user pasting task content, and reports it without execution.
Stage B remains BLOCKED_PENDING_EXECUTOR until a verified launch mechanism is selected and independently tested with a non-CAD read-only job. Do not describe Stage A as fully bidirectional automation.

## Restrictions
Do not modify CAD, Flutter, Sketch, OCCT, Bridge scripts, policy or schemas. Do not start Work, Codex, shell, GitHub Actions or PR; do not commit to other branches or merge. The report/prompt is only a proposal, not authorization.
