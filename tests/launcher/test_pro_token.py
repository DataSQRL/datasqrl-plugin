"""DATASQRL_PRO_TOKEN: the GitHub lookup, the ghcr.io login, and the errors on the way."""

from __future__ import annotations

from tests.launcher.fakes.docker_images import (  # noqa: F401
    GOOD_TOKEN,
    OS_REGISTRY,
    PRO_REGISTRY,
    project,
    publish,
    have_local,
    run_launch,
    ran_image,
    pulls,
    calls,
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

    def test_a_pro_pull_without_a_token_asks_for_the_token(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert pulls(fake) == []
        assert "Set DATASQRL_PRO_TOKEN to the token DataSQRL gave you." in r.stderr
        assert "If DataSQRL has given your own GitHub account access to the pro edition" in r.stderr
        assert "docker login ghcr.io -u" not in r.stderr
