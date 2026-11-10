"""A fake `docker` that keeps run state, and the helpers that set it up.

The launcher only needs docker for `ps` (is the run alive?), `inspect` (labels), `stop`, `wait`, and the
preflight/launch calls of --detach. The shim answers those from files in FAKE_DOCKER_DIR so the
tests control the container's state.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

from tests.launcher.fakes.run_results import (
    calculate_issue_score,
    count_by_severity,
    issue,
    write_run_result,
)


LAUNCHER = Path(__file__).resolve().parents[3] / "scripts" / "datasqrl-agent.sh"

CHECKED_IMAGE_ID = "sha256:checked-image"

SHIM = """#!/bin/sh
case "$1" in
  ps)      [ -f "$FAKE_DOCKER_DIR/live" ] && echo deadbeef; exit 0 ;;
  inspect) case "$*" in
             *codeagent.started*) cat "$FAKE_DOCKER_DIR/started" 2>/dev/null ;;
             *codeagent.mode*)    echo implementation ;;
           esac; exit 0 ;;
  image)   case "$*" in
             *.Id*) echo "$CHECKED_IMAGE_ID" ;;
           esac; exit 0 ;;
  stop)    printf '%s\\n' "$*" > "$FAKE_DOCKER_DIR/stop_args"; rm -f "$FAKE_DOCKER_DIR/live"; exit 0 ;;
  wait)    printf '%s\\n' "$*" > "$FAKE_DOCKER_DIR/wait_args"
           if [ -f "$FAKE_DOCKER_DIR/live" ]; then
             rm -f "$FAKE_DOCKER_DIR/live"; cat "$FAKE_DOCKER_DIR/exit_code" 2>/dev/null || echo 0; exit 0
           fi
           echo "Error response from daemon: No such container: $2" >&2; exit 1 ;;
  run)     printf '%s\n' "$@" > "$FAKE_DOCKER_DIR/run_args"
           env | grep -E '^(AWS_|DATASQRL_TELEMETRY=)' | sort > "$FAKE_DOCKER_DIR/run_env"
           exit 0 ;;
  *)       exit 0 ;;
esac
"""


@pytest.fixture
def project(tmp_path: Path):
    shim_dir = tmp_path / "bin"
    shim_dir.mkdir()
    shim = shim_dir / "docker"
    shim.write_text(SHIM)
    shim.chmod(shim.stat().st_mode | stat.S_IEXEC)
    fake = tmp_path / "fake-docker"
    fake.mkdir()
    proj = tmp_path / "proj"
    (proj / ".datasqrl").mkdir(parents=True)
    # The developer's own AWS settings must not reach the launcher under test.
    host = {k: v for k, v in os.environ.items() if not k.startswith("AWS_") and k != "DATASQRL_TELEMETRY"}
    # Every image the shim reports is one whose signature this machine already verified, so the
    # launcher runs it with no pull. These tests are about the run, not the image check.
    state = tmp_path / "state"
    (state / "datasqrl-agent").mkdir(parents=True)
    (state / "datasqrl-agent" / "verified-images").write_text(f"{CHECKED_IMAGE_ID}\n")
    env = {
        **host,
        "PATH": f"{shim_dir}:{os.environ['PATH']}",
        "FAKE_DOCKER_DIR": str(fake),
        "DATASQRL_AGENT_ALLOW_NO_GIT": "1",
        "XDG_STATE_HOME": str(state),
        "CHECKED_IMAGE_ID": CHECKED_IMAGE_ID,
    }
    return proj, fake, env


def launcher(proj: Path, env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(LAUNCHER), *args], cwd=proj, env=env,
                          capture_output=True, text=True, timeout=30)


def start_run(fake: Path, started: int) -> None:
    (fake / "live").write_text("")
    (fake / "started").write_text(str(started))


def trail(proj: Path) -> Path:
    return proj / ".datasqrl" / "datasqrl-agent-progress.txt"


def write_trail(proj: Path, *records: str) -> None:
    with open(trail(proj), "a") as f:
        for r in records:
            f.write(r + "\n")


def write_result(proj: Path, *runs: dict) -> None:
    """Write runs, oldest first, in the agent's format (see fakes/run_results.py)."""
    for run in runs:
        write_run_result(proj, run)


def run_result(mode="implementation", success=True, scenario="pipeline", refinements=1,
               severities=None, code_check_status=None, llm_judge_status=None) -> dict:
    """One run entry as the agent writes it. `severities` lists one issue each; None means no
    judge ran, so `issue_score` is null. The two statuses are null when no check of that kind ran."""
    issues = [issue(sev, f"issue {i}") for i, sev in enumerate(severities or [])]
    return {
        "success": success, "mode": mode, "scenario": scenario, "refinements": refinements,
        "issue_score": None if severities is None else calculate_issue_score(issues),
        "code_check_status": code_check_status, "llm_judge_status": llm_judge_status,
        "issue_count": {"total": len(issues), **count_by_severity(issues)},
        "issues": issues,
    }
