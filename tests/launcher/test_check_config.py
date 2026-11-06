"""Drives scripts/datasqrl-agent.sh --check-config with a fake `docker` and a fake `aws`.

The fake image prints FAKE_RUN_OUT and exits with FAKE_RUN_RC, the way the image's --check-config
answers. The fake `aws` knows the profiles in FAKE_AWS_PROFILES: FAKE_AWS_GOOD has a working login,
and the names in FAKE_AWS_SSO are SSO profiles.
"""

from __future__ import annotations

import stat
import subprocess
from pathlib import Path

import pytest

from tests.launcher.fakes.docker_images import (  # noqa: F401
    LAUNCHER,
    SHIM,
    project,
    image_id,
    have_local,
)


OS_LOCAL = "adv-agent:latest"

_PLAIN_RUN = """    printf '%s\\n' "$@" > "$D/run_args"; exit 0 ;;"""
assert _PLAIN_RUN in SHIM, "the image tests' docker shim changed; update RUN_SHIM"
RUN_SHIM = SHIM.replace(
    _PLAIN_RUN,
    """    printf '%s\\n' "$@" > "$D/run_args"; printf '%s\\n' "$FAKE_RUN_OUT"; exit "${FAKE_RUN_RC:-0}" ;;""",
)

AWS_SHIM = r"""#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_DIR/aws_calls"
prof=""; prev=""
for a in "$@"; do [ "$prev" = "--profile" ] && prof="$a"; prev="$a"; done
case "$1 $2" in
  "configure list-profiles") printf '%s\n' $FAKE_AWS_PROFILES; exit 0 ;;
  "sts get-caller-identity") [ "$prof" = "$FAKE_AWS_GOOD" ] && { echo 123456789012; exit 0; }; exit 255 ;;
  "configure get")
    case "$3" in
      sso_session) case " $FAKE_AWS_SSO " in *" $prof "*) echo s; exit 0 ;; esac; exit 1 ;;
      region) echo eu-west-1; exit 0 ;;
    esac
    exit 1 ;;
esac
exit 1
"""

IMAGE_READY = "Harness            pi · default pi\nProvider           amazon-bedrock · default anthropic\nStatus             READY"
IMAGE_NOT_READY = IMAGE_READY.replace("READY", "NOT READY")

AWS_CONFIG = """[profile dev]
sso_session = corp
sso_account_id = 111122223333
sso_role_name = DataEngineer
region = us-east-1

[profile personal]
region = eu-west-1
"""


@pytest.fixture
def setup(project, tmp_path):  # noqa: F811
    proj, fake, env = project
    bin_dir = Path(env["PATH"].split(":", 1)[0])
    (bin_dir / "docker").write_text(RUN_SHIM)
    aws = bin_dir / "aws"
    aws.write_text(AWS_SHIM)
    aws.chmod(aws.stat().st_mode | stat.S_IEXEC)
    config = tmp_path / "aws-config"
    config.write_text(AWS_CONFIG)
    have_local(fake, OS_LOCAL, "os")
    env = {k: v for k, v in env.items() if not k.startswith("AWS_") and k != "DATASQRL_TELEMETRY"}
    env.update({
        "AWS_CONFIG_FILE": str(config),
        "FAKE_AWS_PROFILES": "dev personal",
        "FAKE_AWS_SSO": "dev",
        "FAKE_RUN_OUT": IMAGE_READY,
        "FAKE_RUN_RC": "0",
    })
    env.pop("ANTHROPIC_API_KEY", None)
    return proj, fake, env


def check(proj: Path, env: dict, *args: str, **extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(LAUNCHER), "--check-config", *args],
        cwd=proj, env={**env, **extra}, capture_output=True, text=True, timeout=30,
    )


def forwarded(fake: Path) -> list[str]:
    args = (fake / "run_args").read_text().splitlines()
    return [args[i + 1] for i, a in enumerate(args) if a == "-e"]


def aws_calls(fake: Path) -> str:
    f = fake / "aws_calls"
    return f.read_text() if f.exists() else ""


BEDROCK = ("--provider", "amazon-bedrock", "--model", "us.anthropic.claude-opus-5-5")


def test_a_working_profile_is_ready(setup):
    proj, fake, env = setup
    result = check(proj, env, *BEDROCK, AWS_PROFILE="dev", FAKE_AWS_GOOD="dev")

    assert result.returncode == 0, result.stderr
    assert "AWS                profile dev · account 123456789012 · region eu-west-1" in result.stdout
    assert result.stdout.splitlines()[-1] == "Status             READY"
    assert result.stdout.count("Status ") == 1
    assert "AWS_PROFILE" in forwarded(fake)


def test_an_expired_sso_login_names_the_login_command(setup):
    proj, fake, env = setup
    result = check(proj, env, *BEDROCK, AWS_PROFILE="dev", FAKE_AWS_GOOD="other")

    assert result.returncode == 1
    assert "profile dev: the SSO login is missing or expired" in result.stdout
    assert "→ ask the user to run: aws sso login --profile dev" in result.stdout
    assert result.stdout.splitlines()[-1] == "Status             NOT READY"
    assert "AWS_PROFILE" not in forwarded(fake)


def test_a_static_profile_without_a_credential_names_the_check(setup):
    proj, fake, env = setup
    result = check(proj, env, *BEDROCK, AWS_PROFILE="personal", FAKE_AWS_GOOD="other")

    assert result.returncode == 1
    assert "→ see why with: aws sts get-caller-identity --profile personal" in result.stdout


def test_no_profile_lists_the_profiles_with_their_fields(setup):
    proj, fake, env = setup
    result = check(proj, env, *BEDROCK)

    assert result.returncode == 1
    assert "dev" in result.stdout and "account 111122223333 · role DataEngineer · region us-east-1" in result.stdout
    assert "region eu-west-1" in result.stdout
    assert "→ ask the user which profile is for DataSQRL, then run with AWS_PROFILE=<name>" in result.stdout
    assert result.stdout.splitlines()[-1] == "Status             NOT READY"


def test_access_keys_skip_the_profile_check(setup):
    proj, fake, env = setup
    result = check(proj, env, *BEDROCK, AWS_ACCESS_KEY_ID="a", AWS_SECRET_ACCESS_KEY="b", AWS_PROFILE="dev")

    assert result.returncode == 0, result.stderr
    assert "access keys from your shell" in result.stdout
    assert aws_calls(fake) == ""


def test_a_provider_other_than_bedrock_ignores_aws(setup):
    proj, fake, env = setup
    result = check(proj, env, "--provider", "fireworks", "--model", "m", AWS_PROFILE="dev")

    assert result.returncode == 0, result.stderr
    assert "AWS " not in result.stdout
    assert aws_calls(fake) == ""
    assert "AWS_PROFILE" not in forwarded(fake)


def test_the_image_verdict_decides_when_aws_is_not_involved(setup):
    proj, fake, env = setup
    result = check(proj, env, FAKE_RUN_OUT=IMAGE_NOT_READY, FAKE_RUN_RC="1")

    assert result.returncode == 1
    assert result.stdout.splitlines()[-1] == "Status             NOT READY"


def test_the_choices_reach_the_image(setup):
    proj, fake, env = setup
    check(proj, env, "--harness", "pi", "--provider", "fireworks", "--model", "m")

    args = (fake / "run_args").read_text().splitlines()
    # The launcher runs the checked image by its ID.
    assert args[args.index(image_id(OS_LOCAL)) + 1:] == ["--check-config", "--harness", "pi", "--provider", "fireworks", "--model", "m"]


def test_other_arguments_are_refused(setup):
    proj, fake, env = setup
    result = check(proj, env, "--mode", "planning")

    assert result.returncode == 1
    assert "not '--mode'" in result.stderr
    assert not (fake / "run_args").exists()


def test_a_missing_image_is_an_error_and_never_pulled(setup):
    proj, fake, env = setup
    (fake / "images" / "adv-agent_latest").unlink()

    result = check(proj, env)

    assert result.returncode == 1
    assert "datasqrl-agent.sh --pull-image" in result.stderr
    assert "pull" not in (fake / "calls").read_text()
