"""Tests for plan_secrets_guard.py.

Run: python3 -m unittest discover -s scripts -v

The end-to-end tests need `terraform` on PATH. They build a real plan from a
throwaway configuration (built-in terraform_data only, so no provider
download and no cloud credentials) and run the guard on its real JSON.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "plan_secrets_guard.py")
CANARY = "canary-3f9b1e-should-never-print"

sys.path.insert(0, HERE)
from plan_secrets_guard import find_sensitive_values  # noqa: E402


def run_guard(stdin: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, GUARD], input=stdin, capture_output=True, text=True, check=False)


def plan_with(**parts) -> dict:
    base = {"format_version": "1.2", "resource_changes": [], "prior_state": {"values": {"root_module": {}}}}
    base.update(parts)
    return base


class FindSensitiveValues(unittest.TestCase):
    def test_clean_plan_passes(self):
        plan = plan_with(resource_changes=[{
            "address": "azurerm_resource_group.x",
            "change": {"before": None, "after": {"name": "rg"}, "before_sensitive": False, "after_sensitive": {}},
        }])
        self.assertEqual(find_sensitive_values(plan), [])

    def test_sensitive_value_in_prior_state_fails(self):
        plan = plan_with(prior_state={"values": {"root_module": {"resources": [{
            "address": "azurerm_log_analytics_workspace.this",
            "values": {"name": "log", "primary_shared_key": CANARY},
            "sensitive_values": {"primary_shared_key": True},
        }]}}})
        self.assertEqual(find_sensitive_values(plan),
                         ["prior_state azurerm_log_analytics_workspace.this: primary_shared_key"])

    def test_sensitive_but_null_or_empty_passes(self):
        plan = plan_with(prior_state={"values": {"root_module": {"resources": [{
            "address": "x.y",
            "values": {"a": None, "b": "", "c": []},
            "sensitive_values": {"a": True, "b": True, "c": True},
        }]}}})
        self.assertEqual(find_sensitive_values(plan), [])

    def test_nested_list_and_child_module_fail_with_path(self):
        plan = plan_with(prior_state={"values": {"root_module": {"child_modules": [{"resources": [{
            "address": "module.m.x.y",
            "values": {"secret": [{"name": "n", "value": CANARY}]},
            "sensitive_values": {"secret": [{"value": True}]},
        }]}]}}})
        self.assertEqual(find_sensitive_values(plan), ["prior_state module.m.x.y: secret[0].value"])

    def test_sensitive_after_value_in_change_fails(self):
        plan = plan_with(resource_changes=[{
            "address": "x.y",
            "change": {"before": None, "after": {"k": CANARY}, "before_sensitive": False, "after_sensitive": {"k": True}},
        }])
        self.assertEqual(find_sensitive_values(plan), ["resource_changes x.y (after): k"])

    def test_whole_value_marked_sensitive_fails(self):
        plan = plan_with(output_changes={"o": {"before": None, "after": CANARY,
                                               "before_sensitive": False, "after_sensitive": True}})
        self.assertEqual(find_sensitive_values(plan), ["output_changes o (after): <root>"])

    def test_sensitive_variable_with_value_fails(self):
        plan = plan_with(variables={"api_key": {"value": CANARY}},
                         configuration={"root_module": {"variables": {"api_key": {"sensitive": True}}}})
        self.assertEqual(find_sensitive_values(plan), ["variables api_key: sensitive input variable has a value"])


class GuardProcess(unittest.TestCase):
    def test_failure_names_path_but_never_prints_value(self):
        plan = plan_with(prior_state={"values": {"root_module": {"resources": [{
            "address": "x.y", "values": {"k": CANARY}, "sensitive_values": {"k": True}}]}}})
        result = run_guard(json.dumps(plan))
        self.assertEqual(result.returncode, 1)
        self.assertIn("x.y: k", result.stderr)
        self.assertNotIn(CANARY, result.stdout + result.stderr)

    def test_non_json_is_refused(self):
        self.assertEqual(run_guard("not json").returncode, 2)

    def test_json_that_is_not_a_plan_is_refused(self):
        self.assertEqual(run_guard("{}").returncode, 2)


@unittest.skipUnless(shutil.which("terraform"), "terraform not on PATH")
class EndToEndWithRealTerraform(unittest.TestCase):
    """A real plan, made by real Terraform, checked by the real guard."""

    def _plan_json(self, hcl: str) -> str:
        with tempfile.TemporaryDirectory() as workdir:
            with open(os.path.join(workdir, "main.tf"), "w") as handle:
                handle.write(hcl)
            env = dict(os.environ, TF_IN_AUTOMATION="1", TF_INPUT="0")
            for args in (["init", "-input=false", "-no-color"],
                         ["plan", "-input=false", "-no-color", "-out=tfplan"]):
                subprocess.run(["terraform", *args], cwd=workdir, env=env, check=True, capture_output=True)
            shown = subprocess.run(["terraform", "show", "-json", "tfplan"], cwd=workdir, env=env,
                                   check=True, capture_output=True, text=True)
            return shown.stdout

    def test_real_plan_with_sensitive_value_fails_without_printing_it(self):
        plan_json = self._plan_json(f'resource "terraform_data" "leak" {{\n  input = sensitive("{CANARY}")\n}}\n')
        self.assertIn(CANARY, plan_json, "precondition: terraform show -json does carry the sensitive value")
        result = run_guard(plan_json)
        self.assertEqual(result.returncode, 1)
        self.assertIn("terraform_data.leak", result.stderr)
        self.assertNotIn(CANARY, result.stdout + result.stderr)

    def test_real_plan_without_sensitive_values_passes(self):
        result = run_guard(self._plan_json('resource "terraform_data" "ok" {\n  input = "public"\n}\n'))
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
