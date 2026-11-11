"""The pro login: DATASQRL_PRO_TOKEN, or the ghcr.io login that Docker already stored."""

from __future__ import annotations

import base64

import pytest

from tests.launcher.fakes.docker_images import (  # noqa: F401
    GOOD_TOKEN,
    OS_REGISTRY,
    PRO_REGISTRY,
    STORED_LOGIN_SECRET,
    STORED_LOGIN_USER,
    project,
    publish,
    have_local,
    run_flag,
    run_launch,
    ran_image,
    pulls,
    all_pulls,
    calls,
    state_dir,
    store_ghcr_login,
)


class TestProToken:
    def test_a_token_selects_pro_and_logs_in_before_pulling(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        docker_calls = calls(fake).splitlines()
        login = [c for c in docker_calls if c.startswith("login ")]
        assert login == ["login ghcr.io -u datasqrl-agent-bot --password-stdin"]
        assert docker_calls.index(login[0]) < docker_calls.index(f"pull {PRO_REGISTRY}")
        assert (fake / "login_password").read_text() == GOOD_TOKEN
        assert ran_image(fake) == "pro-agent:latest"

    def test_the_token_never_appears_in_arguments_or_output(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert GOOD_TOKEN not in calls(fake)
        assert GOOD_TOKEN not in calls(fake, "curl_calls")
        assert GOOD_TOKEN not in calls(fake, "run_args")
        assert GOOD_TOKEN not in r.stdout + r.stderr
        assert "DATASQRL_PRO_TOKEN" not in calls(fake, "run_args")

    def test_a_rejected_token_stops_before_pulling(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN="ghp_expired")
        assert r.returncode == 1
        assert "invalid or expired" in r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) is None

    def test_a_failed_registry_login_stops_before_pulling(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN, FAKE_GOOD_TOKEN="something-else")
        assert r.returncode == 1
        assert "ghcr.io" in r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) is None

    def test_explicit_os_ignores_the_token(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN, DATASQRL_AGENT_EDITION="os")
        assert r.returncode == 0, r.stderr
        assert "login " not in calls(fake)
        assert calls(fake, "curl_calls") == ""
        assert ran_image(fake) == "adv-agent:latest"

    def test_a_local_pro_image_runs_without_logging_in(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert "login " not in calls(fake)
        assert pulls(fake) == []
        assert ran_image(fake) == "pro-agent:latest"

    def test_a_pull_denied_after_a_token_login_blames_access_not_login(self, project):
        proj, fake, env = project  # pro is not published to this account
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 1
        assert "most likely has not been given access" in r.stderr
        assert "docker login ghcr.io -u" not in r.stderr

    def test_a_pro_pull_without_any_login_asks_for_one(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert pulls(fake) == []
        assert "a pro pull needs a ghcr.io login" in r.stderr
        assert "  docker login ghcr.io\n" in r.stderr
        assert "Or set DATASQRL_PRO_TOKEN to the token DataSQRL gave you." in r.stderr
        assert "docker login ghcr.io -u" not in r.stderr


def cosign_login(fake) -> str:
    """The `user:secret` in the Docker config that the cosign check received."""
    config = (fake / "cosign_config").read_text()
    inline_auth = config.split('"auth":"', 1)[1].split('"', 1)[0]
    return base64.b64decode(inline_auth).decode()


class TestStoredGhcrLogin:
    """A user whose GitHub account has pro access and who ran `docker login ghcr.io` needs no token."""

    @pytest.mark.parametrize("storage", ["credential_store", "credential_helper", "inline"])
    def test_a_pro_pull_uses_the_stored_login(self, project, storage):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, storage)
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == [PRO_REGISTRY]
        assert "login " not in calls(fake)
        assert "https://api.github.com/user" not in calls(fake, "curl_calls")
        assert "https://ghcr.io/token?scope=repository:sigstore/cosign/cosign:pull" in calls(fake, "curl_calls")
        assert cosign_login(fake) == f"{STORED_LOGIN_USER}:{STORED_LOGIN_SECRET}"
        assert f"Using the ghcr.io login that Docker stored for {STORED_LOGIN_USER}." in r.stderr
        assert ran_image(fake) == "pro-agent:latest"
        assert not list((state_dir(fake) / "datasqrl-agent").glob("cosign-auth.*"))

    def test_the_stored_secret_never_appears_in_arguments_or_output(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, "credential_store")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 0, r.stderr
        assert STORED_LOGIN_SECRET not in calls(fake)
        assert STORED_LOGIN_SECRET not in calls(fake, "run_args")
        assert STORED_LOGIN_SECRET not in calls(fake, "curl_calls")
        assert STORED_LOGIN_SECRET not in r.stdout + r.stderr

    def test_the_credential_helper_is_asked_only_for_ghcr(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, "credential_store")
        run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert calls(fake, "credential_helper_calls") == "get ghcr.io\n"

    def test_pull_image_updates_pro_with_the_stored_login(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro", "1.0.4")
        publish(fake, PRO_REGISTRY, "pro", "1.0.5")
        store_ghcr_login(fake, "credential_store")
        r = run_flag(proj, env, "--pull-image")
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == [PRO_REGISTRY]
        assert "version: 1.0.5" in r.stderr

    def test_docker_config_points_at_the_stored_login(self, project, tmp_path):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        other_docker_config = tmp_path / "other-docker-config"
        store_ghcr_login(fake, "inline", docker_config_dir=other_docker_config)
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro", DOCKER_CONFIG=str(other_docker_config))
        assert r.returncode == 0, r.stderr
        assert cosign_login(fake) == f"{STORED_LOGIN_USER}:{STORED_LOGIN_SECRET}"

    def test_the_token_wins_over_the_stored_login(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, "credential_store")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert "login ghcr.io -u datasqrl-agent-bot --password-stdin" in calls(fake)
        assert cosign_login(fake) == f"datasqrl-agent-bot:{GOOD_TOKEN}"
        assert calls(fake, "credential_helper_calls") == ""

    def test_a_stored_login_alone_does_not_select_pro(self, project):
        """Many os users log in to ghcr.io for other packages, and pro never falls back to os."""
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, "credential_store")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == [OS_REGISTRY]
        assert calls(fake, "credential_helper_calls") == ""

    def test_a_store_without_a_ghcr_login_asks_for_one(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, "credential_store")
        (fake / "stored_login").unlink()
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert pulls(fake) == []
        assert "a pro pull needs a ghcr.io login" in r.stderr

    def test_a_store_whose_helper_is_not_installed_asks_for_a_login(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        docker_config_dir = fake.parent / "home" / ".docker"
        docker_config_dir.mkdir(parents=True)
        (docker_config_dir / "config.json").write_text('{"credsStore": "notinstalled"}')
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert pulls(fake) == []
        assert "a pro pull needs a ghcr.io login" in r.stderr

    def test_a_helper_name_with_a_path_is_not_run(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        docker_config_dir = fake.parent / "home" / ".docker"
        docker_config_dir.mkdir(parents=True)
        (docker_config_dir / "config.json").write_text('{"credsStore": "../../bin/fakestore"}')
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert calls(fake, "credential_helper_calls") == ""

    def test_a_denied_pull_with_the_stored_login_names_the_account(self, project):
        proj, fake, env = project  # pro is not published to this account
        store_ghcr_login(fake, "credential_store")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert f"ghcr.io refused the pull for {STORED_LOGIN_USER}" in r.stderr
        assert "docker login ghcr.io" in r.stderr

    def test_an_expired_stored_login_stops_before_any_pull(self, project):
        """ghcr.io refuses an expired login also for the public cosign image, so no pull can work."""
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        store_ghcr_login(fake, "credential_store")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro", FAKE_GHCR_ACCEPTED_LOGIN="")
        assert r.returncode == 1
        assert all_pulls(fake) == []
        assert f"ghcr.io refused the ghcr.io login that Docker stored for {STORED_LOGIN_USER}" in r.stderr
        assert "docker login ghcr.io" in r.stderr
        assert "Check the network" not in r.stderr
        assert ran_image(fake) is None

    def test_a_stored_login_with_a_quote_reaches_ghcr_intact(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        secret_with_quote = 'ghp_with"quote'
        store_ghcr_login(fake, "inline", secret=secret_with_quote)
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro",
                       FAKE_GHCR_ACCEPTED_LOGIN=f'{STORED_LOGIN_USER}:ghp_with\\"quote')
        assert r.returncode == 0, r.stderr
