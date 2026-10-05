#!/usr/bin/env python3
"""Fail if a Terraform plan carries any sensitive value.

Usage:
    terraform show -json tfplan | python3 scripts/plan_secrets_guard.py

Why this exists: this repository is public, so its Actions artifacts and
logs are public. The saved plan that the apply job runs is uploaded as an
artifact, and a saved plan embeds a full copy of the state it was made
against, including every attribute Terraform marks sensitive, in plain text.
`terraform show -json` exposes those values alongside a mask that says which
of them are sensitive. This script walks every value/mask pair in the JSON
plan and exits non-zero if any sensitive attribute is set to anything other
than null or empty.

The design keeps sensitive material out of state in the first place (no
secret values in Terraform, azapi where azurerm's refresh would read secrets;
see docs/identities.md). This check proves it on every plan, before upload.

It reports where (resource address and attribute path) and never what: no
code path below prints, logs, or formats a value.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Iterator


def _blank(value: Any) -> bool:
    """True for values that carry no information."""
    return value is None or value == "" or value == [] or value == {}


def _walk(value: Any, mask: Any, path: str) -> Iterator[str]:
    """Yield the path of every non-blank value whose mask is True."""
    if mask is True:
        if not _blank(value):
            yield path or "<root>"
        return
    if isinstance(mask, dict) and isinstance(value, dict):
        for key, sub_mask in mask.items():
            yield from _walk(value.get(key), sub_mask, f"{path}.{key}" if path else key)
    elif isinstance(mask, list) and isinstance(value, list):
        for index, sub_mask in enumerate(mask):
            if index < len(value):
                yield from _walk(value[index], sub_mask, f"{path}[{index}]")


def _module_resources(module: dict | None) -> Iterator[dict]:
    """Every resource in a state/planned-values module tree."""
    if not module:
        return
    yield from module.get("resources", [])
    for child in module.get("child_modules", []):
        yield from _module_resources(child)


def find_sensitive_values(plan: dict) -> list[str]:
    findings: list[str] = []

    # The state the plan was made against: this is what the saved plan file
    # carries even when nothing is changing.
    prior_root = (plan.get("prior_state") or {}).get("values", {}).get("root_module")
    for resource in _module_resources(prior_root):
        for hit in _walk(resource.get("values"), resource.get("sensitive_values"), ""):
            findings.append(f"prior_state {resource.get('address')}: {hit}")

    planned_root = (plan.get("planned_values") or {}).get("root_module")
    for resource in _module_resources(planned_root):
        for hit in _walk(resource.get("values"), resource.get("sensitive_values"), ""):
            findings.append(f"planned_values {resource.get('address')}: {hit}")

    for change in plan.get("resource_changes", []):
        detail = change.get("change", {})
        for side in ("before", "after"):
            for hit in _walk(detail.get(side), detail.get(f"{side}_sensitive"), ""):
                findings.append(f"resource_changes {change.get('address')} ({side}): {hit}")

    for name, output in (plan.get("output_changes") or {}).items():
        for side in ("before", "after"):
            for hit in _walk(output.get(side), output.get(f"{side}_sensitive"), ""):
                findings.append(f"output_changes {name} ({side}): {hit}")

    # Sensitive input variables with a value. This project declares none;
    # if one is ever added, its value travels inside the plan file.
    declared = (plan.get("configuration") or {}).get("root_module", {}).get("variables", {})
    for name, value in (plan.get("variables") or {}).items():
        if declared.get(name, {}).get("sensitive") and not _blank(value.get("value")):
            findings.append(f"variables {name}: sensitive input variable has a value")

    return findings


def main() -> int:
    try:
        plan = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        print(f"plan-secrets-guard: input is not JSON ({error.msg}); refusing to pass", file=sys.stderr)
        return 2
    if "format_version" not in plan:
        print("plan-secrets-guard: input is not a `terraform show -json` plan; refusing to pass", file=sys.stderr)
        return 2

    findings = find_sensitive_values(plan)
    if findings:
        print(f"plan-secrets-guard: FAIL, {len(findings)} sensitive value(s) in the plan:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        print("The plan was not uploaded. Values are not printed.", file=sys.stderr)
        return 1

    resources = len(plan.get("resource_changes", [])) + len(
        list(_module_resources((plan.get("prior_state") or {}).get("values", {}).get("root_module")))
    )
    print(f"plan-secrets-guard: PASS, no sensitive values in the plan ({resources} resource entries checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
