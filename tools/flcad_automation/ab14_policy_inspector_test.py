"""Isolated unit tests for the AB-14 policy text inspector."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ab14_policy_inspector import inspect_policy_text


class InspectPolicyTextTests(unittest.TestCase):
    def test_typical_policy_summary(self):
        raw = '{"destination_branch":"automation/reports","push_enabled":false,"push_mode":"operator-authorized-only","allowed_files":["report.json","review-request.json","manifest.json"]}'
        self.assertEqual(
            inspect_policy_text(raw),
            {
                "destination_branch": "automation/reports",
                "push_enabled": False,
                "push_mode": "operator-authorized-only",
                "allowed_file_count": 3,
            },
        )

    def test_true_is_reported_without_granting_permission(self):
        raw = '{"destination_branch":"automation/reports","push_enabled":true,"push_mode":"operator-authorized-only","allowed_files":[]}'
        result = inspect_policy_text(raw)
        self.assertIs(result["push_enabled"], True)
        self.assertEqual(
            set(result),
            {
                "destination_branch",
                "push_enabled",
                "push_mode",
                "allowed_file_count",
            },
        )

    def test_invalid_json_raises_value_error(self):
        with self.assertRaises(ValueError):
            inspect_policy_text('{"push_enabled":')

    def test_array_root_raises_value_error(self):
        with self.assertRaises(ValueError):
            inspect_policy_text('[]')

    def test_wrongly_typed_fields_return_null_without_coercion(self):
        raw = '{"destination_branch":7,"push_enabled":"false","push_mode":1,"allowed_files":"report.json"}'
        self.assertEqual(
            inspect_policy_text(raw),
            {
                "destination_branch": None,
                "push_enabled": None,
                "push_mode": None,
                "allowed_file_count": None,
            },
        )


if __name__ == "__main__":
    unittest.main()
