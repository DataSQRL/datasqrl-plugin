"""Writes `.datasqrl_agent_results.json` the way the agent container does.

The agent in DataSQRL/code-agent writes this file at the end of each run, and the launcher's
--status and --wait read it. This copy of the writer lets the launcher tests run here without the
agent's Python package. A contract test in DataSQRL/code-agent compares this writer's output with
the agent's own writer, so a change on either side fails there.
"""

from __future__ import annotations

import json
from pathlib import Path

RESULTS_FILENAME = ".datasqrl_agent_results.json"

SEVERITY_WEIGHTS = {"CRITICAL": 100, "HIGH": 25, "MEDIUM": 5, "LOW": 1}


def read_run_results(workspace: Path) -> list[dict]:
    path = workspace / RESULTS_FILENAME
    if not path.exists():
        return []
    return json.loads(path.read_text()).get("runs", [])


def write_run_result(workspace: Path, result: dict) -> None:
    """Prepend `result` to the run history, so the newest run is the first match in the file."""
    runs = [result] + read_run_results(workspace)
    (workspace / RESULTS_FILENAME).write_text(json.dumps({"runs": runs}, indent=2))


def issue(severity: str, description: str) -> dict:
    """One judge issue, with the fields the agent writes."""
    return {"severity": severity, "description": description, "location": None, "verifier": None}


def calculate_issue_score(issues: list[dict]) -> int:
    return sum(SEVERITY_WEIGHTS[i["severity"]] for i in issues)


def count_by_severity(issues: list[dict]) -> dict[str, int]:
    counts = {severity.lower(): 0 for severity in SEVERITY_WEIGHTS}
    for i in issues:
        counts[i["severity"].lower()] += 1
    return counts
