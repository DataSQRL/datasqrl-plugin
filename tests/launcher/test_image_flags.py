"""--pull-image and --image-exists."""

from __future__ import annotations

from tests.launcher.fakes.docker_images import (  # noqa: F401
    GOOD_TOKEN,
    OS_REGISTRY,
    PRO_REGISTRY,
    project,
    publish,
    have_local,
    local_edition,
    ran_image,
    pulls,
    calls,
    run_flag,
)


class TestPullImage:
    def test_pulls_even_when_the_image_is_local_and_never_runs(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", "1.0.4")
        publish(fake, OS_REGISTRY, "os", "1.0.5")
        r = run_flag(proj, env, "--pull-image")
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == [OS_REGISTRY]
        assert ran_image(fake) is None
        assert "edition: os · version: 1.0.5" in r.stderr

    def test_logs_in_and_pulls_pro_with_a_token(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_flag(proj, env, "--pull-image", DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert "login ghcr.io -u datasqrl-agent-bot --password-stdin" in calls(fake)
        assert pulls(fake) == [PRO_REGISTRY]
        assert local_edition(fake, "pro-agent:latest") == "pro"

    def test_a_failed_pull_exits_non_zero(self, project):
        proj, fake, env = project
        r = run_flag(proj, env, "--pull-image")
        assert r.returncode == 1
        assert ran_image(fake) is None

    def test_refuses_a_custom_image(self, project):
        proj, fake, env = project
        r = run_flag(proj, env, "--pull-image", DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 1
        assert "DATASQRL_AGENT_IMAGE" in r.stderr
        assert pulls(fake) == []

    def test_refuses_other_arguments(self, project):
        proj, fake, env = project
        r = run_flag(proj, env, "--pull-image", "--mode", "implementation")
        assert r.returncode == 1
        assert pulls(fake) == []
        assert ran_image(fake) is None


class TestImageExists:
    def test_present_prints_edition_and_version_and_exits_zero(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro", "1.0.712")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "pro-agent:latest is present · edition: pro · version: 1.0.712"
        assert pulls(fake) == []

    def test_missing_names_the_image_and_the_fix_and_exits_one(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 1
        assert r.stdout.strip() == "adv-agent:latest (os edition) is missing · run: datasqrl-agent.sh --pull-image"
        assert pulls(fake) == []

    def test_checks_the_edition_the_user_selected(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        r = run_flag(proj, env, "--image-exists", DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert r.stdout.startswith("pro-agent:latest (pro edition) is missing")

    def test_checks_a_custom_image(self, project):
        proj, fake, env = project
        have_local(fake, "custom:dev", "pro", "")
        r = run_flag(proj, env, "--image-exists", DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "custom:dev is present · edition: pro · version: local build"

    def test_an_unchecked_image_names_the_fix_and_exits_one(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", checked=False)
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 1
        assert r.stdout.strip() == ("adv-agent:latest (os edition) has no checked signature"
                                    " · run: datasqrl-agent.sh --pull-image")
        assert pulls(fake) == []

    def test_a_custom_image_needs_no_checked_signature(self, project):
        proj, fake, env = project
        have_local(fake, "custom:dev", "pro", "", checked=False)
        r = run_flag(proj, env, "--image-exists", DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "custom:dev is present · edition: pro · version: local build"

    def test_works_outside_a_git_repository(self, project, tmp_path):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        plain = tmp_path / "not-a-repo"
        plain.mkdir()
        env = {k: v for k, v in env.items() if k != "DATASQRL_AGENT_ALLOW_NO_GIT"}
        r = run_flag(plain, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        r = run_flag(plain, env, "--pull-image")
        assert r.returncode == 1  # nothing published; what matters is no git error
        assert "git repository" not in r.stderr
