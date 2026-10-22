"""Read-only summary of selected publication-policy fields."""

import json


def inspect_policy_text(raw: str) -> dict:
    """Parse policy JSON and return a small, non-authorizing summary."""
    try:
        policy = json.loads(raw)
    except (json.JSONDecodeError, TypeError) as exc:
        raise ValueError("invalid policy JSON") from exc

    if not isinstance(policy, dict):
        raise ValueError("policy JSON root must be an object")

    destination_branch = policy.get("destination_branch")
    push_enabled = policy.get("push_enabled")
    push_mode = policy.get("push_mode")
    allowed_files = policy.get("allowed_files")

    return {
        "destination_branch": (
            destination_branch if isinstance(destination_branch, str) else None
        ),
        "push_enabled": push_enabled if type(push_enabled) is bool else None,
        "push_mode": push_mode if isinstance(push_mode, str) else None,
        "allowed_file_count": (
            len(allowed_files) if isinstance(allowed_files, list) else None
        ),
    }
