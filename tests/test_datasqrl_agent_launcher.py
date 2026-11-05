"""Drives scripts/datasqrl-agent.sh --status/--stop/--detach with a fake `docker` on PATH.

The launcher only needs docker for `ps` (is the run alive?), `inspect` (labels), `stop`, `wait`, and the
preflight/launch calls of --detach. The shim answers those from files in FAKE_DOCKER_DIR so the
tests control the container's state.
"""

from __future__ import annotations

import os
import stat
import subprocess
import time
from pathlib import Path

import pytest

from tests.run_results import calculate_issue_score, count_by_severity, issue, write_run_result

LAUNCHER = Path(__file__).resolve().parents[1] / "scripts" / "datasqrl-agent.sh"

SHIM = """#!/bin/sh
case "$1" in
  ps)      [ -f "$FAKE_DOCKER_DIR/live" ] && echo deadbeef; exit 0 ;;
  inspect) case "$*" in
             *codeagent.started*) cat "$FAKE_DOCKER_DIR/started" 2>/dev/null ;;
             *codeagent.mode*)    echo implementation ;;
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
    env = {
        **host,
        "PATH": f"{shim_dir}:{os.environ['PATH']}",
        "FAKE_DOCKER_DIR": str(fake),
        "DATASQRL_AGENT_ALLOW_NO_GIT": "1",
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
    """Write runs, oldest first, in the agent's format (see tests/run_results.py)."""
    for run in runs:
        write_run_result(proj, run)


def run_result(mode="implementation", success=True, scenario="pipeline", refinements=1,
               severities=None) -> dict:
    """One run entry as the agent writes it. `severities` lists one issue each; None means no
    judge ran, so `issue_score` is null."""
    issues = [issue(sev, f"issue {i}") for i, sev in enumerate(severities or [])]
    return {
        "success": success, "mode": mode, "scenario": scenario, "refinements": refinements,
        "issue_score": None if severities is None else calculate_issue_score(issues),
        "issue_count": {"total": len(issues), **count_by_severity(issues)},
        "issues": issues,
    }


class TestStatus:
    def test_running_shows_last_step_and_activity(self, project):
        proj, fake, env = project
        now = int(time.time())
        start_run(fake, now - 600)
        write_trail(proj, "+00:00:00  RUN    Run started · implementation",
                    "+00:01:40  STEP   Iteration 1 · implementing",
                    "+00:07:40  TEXT   Step 7 done. Now step 8.",
                    "                  second line of that text")
        r = launcher(proj, env, "--status")
        assert r.returncode == 0, r.stderr
        line = r.stdout.strip()
        assert line.startswith("Running · implementation · started 10m ago · Iteration 1 · implementing · last: Step 7 done. Now step 8. (")
        assert line.endswith(" ago)")

    def test_running_without_activity_yet(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 120)   # minutes, so a second boundary cannot flip the text
        write_trail(proj, "+00:00:00  RUN    Run started · planning")
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "Running · implementation · started 2m ago · Run started · planning"

    def test_running_with_done_record_reports_finishing(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 600)
        write_trail(proj, "+00:10:00  DONE   Finished · success · implementation · pipeline · 1 refinement(s) · 0 issue(s) (0 critical, 0 high, 0 medium, 0 low) · score 0")
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "Finishing · Finished · success · implementation · pipeline · 1 refinement(s) · 0 issue(s) (0 critical, 0 high, 0 medium, 0 low) · score 0"

    def test_not_running_reports_last_result(self, project):
        proj, fake, env = project
        write_result(proj, run_result(success=False, refinements=2, severities=["CRITICAL", "HIGH", "LOW"]))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == (
            "No run in progress. Last result: failed · implementation · pipeline · 2 refinement(s) · "
            "3 issue(s) (1 critical, 1 high, 0 medium, 1 low) · score 126"
        )

    def test_a_run_no_judge_scored_shows_no_issues(self, project):
        """Planning, patch and --disable-verification runs record `issue_score: null`."""
        proj, fake, env = project
        write_result(proj, run_result(mode="patch", severities=None))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "No run in progress. Last result: success · patch · pipeline · 1 refinement(s)"

    def test_nothing_ever_ran(self, project):
        proj, fake, env = project
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "No run in progress for this project, and no previous result."


class TestStop:
    def test_stop_stops_the_named_container(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()))
        r = launcher(proj, env, "--stop")
        assert r.stdout.strip() == "Stopped the run for this project."
        args = (fake / "stop_args").read_text().split()
        assert args[0] == "stop" and args[-1].startswith("datasqrl-agent-proj-")

    def test_stop_without_a_run(self, project):
        proj, fake, env = project
        r = launcher(proj, env, "--stop")
        assert r.stdout.strip() == "No run in progress for this project."


class TestDetach:
    def test_detached_launch_prints_run_name_and_hand_off(self, project, tmp_path):
        """A detached launch prints the run name, then copy-pasteable commands for a second terminal."""
        proj, fake, env = project
        env = {**env, "HOME": str(tmp_path / "home"), "ANTHROPIC_API_KEY": "sk-test",
               "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "y"}
        (tmp_path / "home").mkdir()
        r = launcher(proj, env, "--mode", "implementation", "--detach")
        assert r.returncode == 0, r.stderr
        lines = r.stdout.splitlines()
        assert lines[0].startswith("datasqrl-agent-proj-")
        assert lines[1].startswith("Running in the background as a detached container.")
        assert lines[2].strip() == f"follow it live:   tail -f '{proj.resolve()}/.datasqrl/datasqrl-agent-progress.txt'"
        assert lines[3].strip() == f"wait for it:      cd '{proj.resolve()}' && '{LAUNCHER}' --wait"
        assert lines[4].strip() == f"status:           cd '{proj.resolve()}' && '{LAUNCHER}' --status"
        assert lines[5].strip() == f"stop:             cd '{proj.resolve()}' && '{LAUNCHER}' --stop"


class TestProviderEnv:
    """Provider variables reach the container by name only, and nothing else from the host does."""

    def _launch(self, project, tmp_path, **extra):
        proj, fake, env = project
        home = tmp_path / "home"
        home.mkdir(exist_ok=True)
        env = {**env, "HOME": str(home), "ANTHROPIC_API_KEY": "sk-test", **extra}
        r = launcher(proj, env, "--mode", "implementation", "--detach")
        args_file = fake / "run_args"
        return r, (args_file.read_text().splitlines() if args_file.exists() else [])

    @staticmethod
    def _env_names(args):
        return [args[i + 1] for i, a in enumerate(args) if a == "-e"]

    def test_a_set_provider_key_is_forwarded_by_name(self, project, tmp_path):
        r, args = self._launch(project, tmp_path, FIREWORKS_API_KEY="fw-secret")
        assert r.returncode == 0, r.stderr
        assert "FIREWORKS_API_KEY" in self._env_names(args)
        assert not any("fw-secret" in a for a in args)
        assert not any("sk-test" in a for a in args)

    def test_unset_and_unlisted_variables_stay_on_the_host(self, project, tmp_path):
        r, args = self._launch(project, tmp_path, GITHUB_TOKEN="ghp_x")
        names = self._env_names(args)
        assert "GITHUB_TOKEN" not in names
        assert "TOGETHER_API_KEY" not in names
        assert "PATH" not in names

    def test_codeagent_pass_env_adds_names(self, project, tmp_path):
        r, args = self._launch(project, tmp_path, DATASQRL_AGENT_PASS_ENV="MY_KEY, OTHER_KEY", MY_KEY="v")
        assert r.returncode == 0, r.stderr
        names = self._env_names(args)
        assert "MY_KEY" in names
        assert "OTHER_KEY" not in names  # listed, but not set on the host

    def test_codeagent_pass_env_refuses_a_non_name(self, project, tmp_path):
        r, args = self._launch(project, tmp_path, DATASQRL_AGENT_PASS_ENV="A=B")
        assert r.returncode == 1
        assert "not a variable name" in r.stderr
        assert args == []

    def test_a_credentials_file_variable_mounts_the_file_read_only(self, project, tmp_path):
        key = tmp_path / "sa.json"
        key.write_text("{}")
        r, args = self._launch(project, tmp_path, GOOGLE_APPLICATION_CREDENTIALS=str(key))
        assert r.returncode == 0, r.stderr
        assert f"{key}:{key}:ro" in args

    def test_a_credentials_file_variable_pointing_nowhere_is_an_error(self, project, tmp_path):
        r, args = self._launch(project, tmp_path, GOOGLE_APPLICATION_CREDENTIALS="/no/such.json")
        assert r.returncode == 1
        assert "GOOGLE_APPLICATION_CREDENTIALS" in r.stderr
        assert args == []

    def test_log_upload_opt_in_is_forwarded_by_name(self, project, tmp_path):
        r, args = self._launch(project, tmp_path, DATASQRL_TELEMETRY="1")
        assert r.returncode == 0, r.stderr
        assert "DATASQRL_TELEMETRY" in self._env_names(args)

    def test_ecs_credential_variables_are_forwarded_by_prefix(self, project, tmp_path):
        r, args = self._launch(
            project, tmp_path, AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/v2/credentials/x"
        )
        assert "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" in self._env_names(args)


AWS_SHIM = """#!/bin/sh
d="$FAKE_AWS_DIR"
profile=""
prev=""
for a in "$@"; do [ "$prev" = "--profile" ] && profile="$a"; prev="$a"; done
case "$1 $2" in
  "configure get")
    case "$3" in
      sso_session|sso_start_url) [ -f "$d/sso_$profile" ] && { echo x; exit 0; }; exit 1 ;;
      region) [ -f "$d/region" ] && { cat "$d/region"; exit 0; }; exit 1 ;;
    esac; exit 1 ;;
  "configure export-credentials")
    echo "$profile" >> "$d/exports"
    [ -f "$d/valid_$profile" ] || { echo "Error loading SSO Token" >&2; exit 255; }
    cat "$d/valid_$profile"; exit 0 ;;
  "sso login")
    echo "$profile" >> "$d/logins"
    [ -f "$d/login_ok" ] || exit 1
    cp "$d/creds" "$d/valid_$profile"; exit 0 ;;
esac
exit 0
"""

CREDS = (
    "AWS_ACCESS_KEY_ID=ASIATEST\n"
    "AWS_SECRET_ACCESS_KEY=secret/with+chars\n"
    "AWS_SESSION_TOKEN=IQoJb3JpZ2luX2VjEPad==\n"
    "AWS_CREDENTIAL_EXPIRATION=2026-10-06T02:28:56+00:00\n"
)


class TestClaudeCredential:
    """A Claude credential is needed only when the coding agent runs on Anthropic.

    The provider comes from --provider, else DATASQRL_AGENT_PROVIDER, else the provider/ prefix of
    the model, as Pi and the judges read it. Any other provider starts without a Claude login,
    and no Claude login file reaches its container.
    """

    MOUNT = "/root/.claude/.credentials.json"

    def _launch(self, project, tmp_path, *args, login_file=False, **extra):
        proj, fake, env = project
        home = tmp_path / "home"
        (home / ".claude").mkdir(parents=True, exist_ok=True)
        if login_file:
            (home / ".claude" / ".credentials.json").write_text('{"claudeAiOauth":{"accessToken":"t"}}')
        # A Keychain with no Claude login, so the test never reads the developer's own.
        shim_dir = Path(env["PATH"].split(":", 1)[0])
        security = shim_dir / "security"
        security.write_text("#!/bin/sh\nexit 44\n")
        security.chmod(security.stat().st_mode | stat.S_IEXEC)
        host = {k: v for k, v in env.items()
                if k not in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "DATASQRL_AGENT_PROVIDER",
                             "DATASQRL_AGENT_MODEL")}
        r = launcher(proj, {**host, "HOME": str(home), **extra}, "--mode", "implementation", "--detach", *args)
        args_file = fake / "run_args"
        return r, (args_file.read_text().splitlines() if args_file.exists() else [])

    @pytest.mark.parametrize(
        "args, extra",
        [
            (["--provider", "fireworks", "--model", "accounts/fireworks/models/deepseek-v4-pro"], {}),
            (["--provider=fireworks", "--model", "m"], {}),
            (["--model", "m"], {"DATASQRL_AGENT_PROVIDER": "fireworks"}),
            (["--model", "deepseek/deepseek-v4-pro"], {}),
            ([], {"DATASQRL_AGENT_MODEL": "deepseek/deepseek-v4-pro"}),
            (["--model=deepseek/deepseek-v4-pro"], {}),
        ],
    )
    def test_another_provider_starts_without_a_claude_login(self, project, tmp_path, args, extra):
        r, run_args = self._launch(project, tmp_path, *args, FIREWORKS_API_KEY="fw", **extra)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "No authentication found" not in r.stdout
        assert run_args

    def test_another_provider_gets_no_claude_login_file(self, project, tmp_path):
        r, run_args = self._launch(project, tmp_path, "--provider", "fireworks", "--model", "m", login_file=True)
        assert r.returncode == 0, r.stdout + r.stderr
        assert not any(self.MOUNT in a for a in run_args)

    @pytest.mark.parametrize(
        "args, extra",
        [
            ([], {}),
            (["--provider", "anthropic"], {}),
            (["--model", "anthropic/claude-sonnet-5"], {}),
            (["--model", "claude-sonnet-5"], {}),
        ],
    )
    def test_an_anthropic_run_still_needs_a_claude_login(self, project, tmp_path, args, extra):
        r, run_args = self._launch(project, tmp_path, *args, **extra)
        assert r.returncode == 1
        assert "No authentication found" in r.stdout
        assert run_args == []

    def test_an_anthropic_run_mounts_the_login_file(self, project, tmp_path):
        r, run_args = self._launch(project, tmp_path, login_file=True)
        assert r.returncode == 0, r.stdout + r.stderr
        assert any(self.MOUNT in a for a in run_args)

    def test_the_provider_flag_wins_over_a_model_prefix(self, project, tmp_path):
        r, _ = self._launch(project, tmp_path, "--provider", "anthropic", "--model", "deepseek/x")
        assert r.returncode == 1
        assert "No authentication found" in r.stdout


class TestAwsProfile:
    """AWS_PROFILE becomes one temporary credential on the host; ~/.aws never reaches the container."""

    @pytest.fixture
    def aws(self, project, tmp_path):
        proj, fake, env = project
        shim = tmp_path / "bin" / "aws"
        shim.write_text(AWS_SHIM)
        shim.chmod(shim.stat().st_mode | stat.S_IEXEC)
        fake_aws = tmp_path / "fake-aws"
        fake_aws.mkdir()
        (fake_aws / "creds").write_text(CREDS)
        home = tmp_path / "home"
        (home / ".aws").mkdir(parents=True)
        env = {**env, "HOME": str(home), "FAKE_AWS_DIR": str(fake_aws), "ANTHROPIC_API_KEY": "sk-test"}
        return proj, fake, fake_aws, env

    @staticmethod
    def _run(proj, fake, env, *provider_args, **extra):
        # A Bedrock run by default: that is a run that needs the profile.
        provider_args = provider_args or ("--provider", "amazon-bedrock", "--model", "m")
        r = launcher(proj, {**env, **extra}, "--mode", "implementation", *provider_args, "--detach")
        args_file, env_file = fake / "run_args", fake / "run_env"
        args = args_file.read_text().splitlines() if args_file.exists() else []
        run_env = (dict(line.split("=", 1) for line in env_file.read_text().splitlines())
                   if env_file.exists() else {})
        return r, args, run_env

    @staticmethod
    def _names(args):
        return [args[i + 1] for i, a in enumerate(args) if a == "-e"]

    def test_a_valid_login_forwards_one_credential_by_name(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "sso_dev").write_text("")
        (fake_aws / "valid_dev").write_text(CREDS)
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev")
        assert r.returncode == 0, r.stderr
        names = self._names(args)
        for n in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION"):
            assert n in names
        assert "AWS_PROFILE" not in names
        assert not any("/root/.aws" in a for a in args)
        assert not any("ASIATEST" in a or "IQoJ" in a for a in args)
        assert run_env["AWS_ACCESS_KEY_ID"] == "ASIATEST"
        assert run_env["AWS_REGION"] == "us-east-1"
        assert not (fake_aws / "logins").exists()

    def test_values_with_equals_signs_survive(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_dev").write_text(CREDS)
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev")
        assert run_env["AWS_SESSION_TOKEN"] == "IQoJb3JpZ2luX2VjEPad=="
        assert run_env["AWS_SECRET_ACCESS_KEY"] == "secret/with+chars"

    def test_the_profile_region_is_used(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_dev").write_text(CREDS)
        (fake_aws / "region").write_text("eu-central-1\n")
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev")
        assert run_env["AWS_REGION"] == "eu-central-1"

    def test_a_set_region_wins(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_dev").write_text(CREDS)
        (fake_aws / "region").write_text("eu-central-1\n")
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev", AWS_REGION="us-west-2")
        assert run_env["AWS_REGION"] == "us-west-2"

    def test_an_expired_sso_login_names_the_login_command_and_starts_nothing(self, aws):
        """The launcher never logs in itself: the user runs `aws sso login` and re-runs."""
        proj, fake, fake_aws, env = aws
        (fake_aws / "sso_dev").write_text("")
        (fake_aws / "login_ok").write_text("")
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev")
        assert r.returncode == 1
        assert "aws --profile dev sso login" in r.stderr
        assert not (fake_aws / "logins").exists()
        assert args == []

    def test_a_failing_static_profile_names_the_export_command(self, aws):
        proj, fake, fake_aws, env = aws
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="static")
        assert r.returncode == 1
        assert "aws configure export-credentials --profile static" in r.stderr
        assert not (fake_aws / "logins").exists()
        assert args == []

    def test_a_static_profile_clears_a_stale_session_token(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_static").write_text("AWS_ACCESS_KEY_ID=AKIA\nAWS_SECRET_ACCESS_KEY=s\n")
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="static", AWS_SESSION_TOKEN="stale")
        assert r.returncode == 0, r.stderr
        assert "AWS_SESSION_TOKEN" not in self._names(args)
        assert run_env["AWS_ACCESS_KEY_ID"] == "AKIA"

    def test_exported_credentials_do_not_opt_in_to_the_upload(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_dev").write_text(CREDS)
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev")
        assert "DATASQRL_TELEMETRY" not in self._names(args)

    def test_another_provider_ignores_the_profile(self, aws):
        """AWS_PROFILE set for unrelated work never blocks or reaches a run that does not use AWS."""
        proj, fake, fake_aws, env = aws
        (fake_aws / "sso_dev").write_text("")  # expired login
        r, args, run_env = self._run(proj, fake, env, "--provider", "fireworks", "--model", "m",
                                     AWS_PROFILE="dev", FIREWORKS_API_KEY="fw")
        assert r.returncode == 0, r.stderr
        assert not (fake_aws / "exports").exists()
        names = self._names(args)
        assert not any(n.startswith("AWS_") for n in names)

    def test_no_provider_flag_ignores_the_profile(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "sso_dev").write_text("")
        r, args, run_env = self._run(proj, fake, env, "--model", "m", AWS_PROFILE="dev")
        assert r.returncode == 0, r.stderr
        assert not (fake_aws / "exports").exists()

    @pytest.mark.parametrize("provider_args, extra", [
        (("--provider=amazon-bedrock",), {}),
        (("--provider", "bedrock"), {}),
        (("--model", "m"), {"DATASQRL_AGENT_PROVIDER": "amazon-bedrock"}),
    ])
    def test_every_way_of_naming_bedrock_uses_the_profile(self, aws, provider_args, extra):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_dev").write_text(CREDS)
        r, args, run_env = self._run(proj, fake, env, *provider_args, AWS_PROFILE="dev", **extra)
        assert r.returncode == 0, r.stderr
        assert (fake_aws / "exports").read_text().split() == ["dev"]
        assert "AWS_ACCESS_KEY_ID" in self._names(args)

    def test_the_provider_flag_wins_over_the_environment(self, aws):
        proj, fake, fake_aws, env = aws
        r, args, run_env = self._run(proj, fake, env, "--provider", "fireworks", "--model", "m",
                                     AWS_PROFILE="dev", DATASQRL_AGENT_PROVIDER="amazon-bedrock")
        assert r.returncode == 0, r.stderr
        assert not (fake_aws / "exports").exists()

    def test_log_upload_uses_the_profile_with_another_provider(self, aws):
        proj, fake, fake_aws, env = aws
        (fake_aws / "valid_dev").write_text(CREDS)
        r, args, run_env = self._run(proj, fake, env, "--provider", "fireworks", "--model", "m",
                                     AWS_PROFILE="dev", DATASQRL_TELEMETRY="1")
        assert r.returncode == 0, r.stderr
        assert run_env["AWS_ACCESS_KEY_ID"] == "ASIATEST"
        assert "DATASQRL_TELEMETRY" in self._names(args)

    def test_log_upload_with_an_expired_login_stops(self, aws):
        """The user asked to upload, so a missing credential is an error rather than a silent skip."""
        proj, fake, fake_aws, env = aws
        (fake_aws / "sso_dev").write_text("")
        r, args, run_env = self._run(proj, fake, env, "--provider", "fireworks", "--model", "m",
                                     AWS_PROFILE="dev", DATASQRL_TELEMETRY="1")
        assert r.returncode == 1
        assert "aws --profile dev sso login" in r.stderr
        assert args == []

    def test_keys_already_set_win_over_the_profile(self, aws):
        """As in the AWS SDK, access keys in the environment take precedence over a profile."""
        proj, fake, fake_aws, env = aws
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev",
                                     AWS_ACCESS_KEY_ID="AKIAMINE", AWS_SECRET_ACCESS_KEY="mine")
        assert r.returncode == 0, r.stderr
        assert not (fake_aws / "exports").exists()
        assert run_env["AWS_ACCESS_KEY_ID"] == "AKIAMINE"
        assert "AWS_PROFILE" not in self._names(args)

    def test_no_profile_never_calls_aws(self, aws):
        proj, fake, fake_aws, env = aws
        r, args, run_env = self._run(proj, fake, env)
        assert r.returncode == 0, r.stderr
        assert not (fake_aws / "exports").exists()

    def test_a_missing_aws_cli_is_an_error(self, aws, tmp_path):
        proj, fake, fake_aws, env = aws
        (tmp_path / "bin" / "aws").unlink()
        # Only the shim dir and the basic system dirs, so no installed aws is found either.
        env = {**env, "PATH": f"{tmp_path / 'bin'}:/usr/bin:/bin"}
        if any(Path(d, "aws").exists() for d in ("/usr/bin", "/bin")):
            pytest.skip("an aws CLI is installed in a system directory")
        r, args, run_env = self._run(proj, fake, env, AWS_PROFILE="dev")
        assert r.returncode == 1
        assert "AWS CLI" in r.stderr
        assert args == []


RESULT_OK = run_result(mode="planning", refinements=0, severities=None)
RESULT_OK_LINE = "No run in progress. Last result: success · planning · pipeline · 0 refinement(s)"

# The history: newest run first, so the launcher's `grep -m1` reads the run that just finished
# and the earlier ones stay on disk. write_result takes the runs oldest first.
RESULT_HISTORY = (
    run_result(mode="planning", success=False, scenario="catalog", refinements=0,
               severities=["CRITICAL"] * 7),
    run_result(severities=["HIGH", "MEDIUM", "MEDIUM"]),
)
RESULT_HISTORY_LINE = (
    "No run in progress. Last result: success · implementation · pipeline · "
    "1 refinement(s) · 3 issue(s) (0 critical, 1 high, 2 medium, 0 low) · score 35"
)


class TestWait:
    def test_wait_blocks_on_the_container_then_prints_the_result(self, project):
        """`docker wait <run>` is the block; the status line after it is the whole output."""
        proj, fake, env = project
        start_run(fake, int(time.time()) - 60)
        write_result(proj, RESULT_OK)
        r = launcher(proj, env, "--wait")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == RESULT_OK_LINE
        args = (fake / "wait_args").read_text().split()
        assert args[0] == "wait" and args[-1].startswith("datasqrl-agent-proj-")

    def test_wait_exits_with_the_containers_exit_code(self, project):
        """A stopped run exits 143 in the container; --wait passes that through so `&&` chains see it."""
        proj, fake, env = project
        start_run(fake, int(time.time()))
        (fake / "exit_code").write_text("143\n")
        r = launcher(proj, env, "--wait")
        assert r.returncode == 143
        assert r.stdout.strip() == "No run in progress for this project, and no previous result."

    def test_wait_without_a_run_prints_the_status_at_once(self, project):
        """Already gone (finished and --rm'd, or never started): docker's error is swallowed, the status line still tells what happened."""
        proj, fake, env = project
        write_result(proj, RESULT_OK)
        r = launcher(proj, env, "--wait")
        assert r.returncode == 0
        assert r.stdout.strip() == RESULT_OK_LINE
        assert "No such container" not in r.stderr


class TestStatusWithCount:
    def test_status_n_prints_recent_lines_then_status(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 60)
        write_trail(proj, "+00:00:00  RUN    Run started · implementation",
                    "+00:00:10  STEP   Iteration 0 · implementing",
                    "+00:00:20  TEXT   Step 1 done.")
        r = launcher(proj, env, "--status", "2")
        assert r.returncode == 0, r.stderr
        lines = r.stdout.splitlines()
        assert lines[:2] == ["+00:00:10  STEP   Iteration 0 · implementing", "+00:00:20  TEXT   Step 1 done."]
        assert lines[2].startswith("Running · implementation · started 1m ago · Iteration 0 · implementing · last: Step 1 done. (")

    def test_status_n_after_the_run_shows_kept_trail_and_last_result(self, project):
        proj, fake, env = project
        done = ("+00:46:51  DONE   Finished · success · implementation · pipeline · 1 refinement(s) · "
                "3 issue(s) (0 critical, 1 high, 2 medium, 0 low) · score 35")
        write_trail(proj, done)
        write_result(proj, run_result(severities=["HIGH", "MEDIUM", "MEDIUM"]))
        r = launcher(proj, env, "--status", "40")
        assert r.returncode == 0
        assert r.stdout.splitlines() == [
            done,
            "No run in progress. Last result: success · implementation · pipeline · 1 refinement(s) · "
            "3 issue(s) (0 critical, 1 high, 2 medium, 0 low) · score 35",
        ]

    def test_status_n_takes_the_last_n_physical_lines(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 5)
        write_trail(proj, *[f"+00:00:{i:02d}  TEXT   line {i}" for i in range(50)])
        r = launcher(proj, env, "--status", "40")
        lines = r.stdout.splitlines()
        assert len(lines) == 41
        assert lines[0].endswith("line 10")
        assert lines[-1].startswith("Running · implementation")

    def test_status_n_without_trail_prints_status_only(self, project):
        proj, fake, env = project
        r = launcher(proj, env, "--status", "40")
        assert r.stdout.strip() == "No run in progress for this project, and no previous result."

    def test_plain_status_stays_one_line_even_with_a_trail(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 5)
        write_trail(proj, "+00:00:00  RUN    Run started · implementation",
                    "+00:00:03  TEXT   hello")
        r = launcher(proj, env, "--status")
        assert len(r.stdout.splitlines()) == 1


class TestResultHistory:
    """`.datasqrl_agent_results.json` holds every run for the project, newest first. The launcher
    parses it with `grep -m1`, so the newest run has to be what --status and --wait report."""

    def test_status_reports_the_newest_run_not_an_earlier_one(self, project):
        proj, fake, env = project
        write_result(proj, *RESULT_HISTORY)

        r = launcher(proj, env, "--status")

        assert r.returncode == 0, r.stderr
        assert RESULT_HISTORY_LINE in r.stdout
        # The older planning run's values must not leak into the line.
        assert "planning" not in r.stdout
        assert "catalog" not in r.stdout
        assert "7 issue(s)" not in r.stdout

    def test_wait_reports_the_newest_run(self, project):
        proj, fake, env = project
        write_result(proj, *RESULT_HISTORY)

        r = launcher(proj, env, "--wait")

        assert r.returncode == 0, r.stderr
        assert RESULT_HISTORY_LINE in r.stdout
