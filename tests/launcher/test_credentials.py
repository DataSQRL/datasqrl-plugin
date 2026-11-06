"""What a run forwards into the container: provider variables, the Claude login and AWS credentials."""

from __future__ import annotations

import stat
from pathlib import Path

import pytest

from tests.launcher.fakes.docker_runs import (  # noqa: F401
    project,
    launcher,
)


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
