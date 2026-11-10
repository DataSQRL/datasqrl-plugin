"""Which edition and image the launcher picks, and that it never falls back to the other edition."""

from __future__ import annotations

from tests.launcher.fakes.docker_images import (  # noqa: F401
    GOOD_TOKEN,
    OS_REGISTRY,
    PRO_REGISTRY,
    project,
    publish,
    have_local,
    local_edition,
    run_launch,
    ran_image,
    pulls,
)


class TestEditionResolution:
    def test_defaults_to_os_and_bootstraps_it(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == [OS_REGISTRY]
        assert ran_image(fake) == "adv-agent:latest"
        assert f"Pulling {OS_REGISTRY} (os edition" in r.stderr
        assert "edition: os · version: 1.0.5" in r.stderr

    def test_explicit_pro_bootstraps_pro(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro", DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == [PRO_REGISTRY]
        assert ran_image(fake) == "pro-agent:latest"

    def test_a_local_pro_image_selects_pro_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) == "pro-agent:latest"

    def test_explicit_os_wins_over_a_local_pro_image(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro")
        have_local(fake, "adv-agent:latest", "os")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="os")
        assert r.returncode == 0, r.stderr
        assert ran_image(fake) == "adv-agent:latest"

    def test_an_unknown_edition_is_refused(self, project):
        proj, fake, env = project
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="enterprise")
        assert r.returncode == 1
        assert "DATASQRL_AGENT_EDITION" in r.stderr
        assert ran_image(fake) is None

    def test_an_existing_local_image_is_not_pulled_again(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) == "adv-agent:latest"


class TestNoSilentDowngrade:
    def test_a_failed_pro_pull_stops_instead_of_running_os(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")  # os is available; pro is not
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="pro", DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 1
        assert pulls(fake) == [PRO_REGISTRY]
        assert ran_image(fake) is None
        assert local_edition(fake, "adv-agent:latest") is None


class TestCommonTag:
    def test_pulling_os_points_the_common_tag_at_os(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        run_launch(proj, env)
        assert local_edition(fake, "datasqrl-agent:latest") == "os"

    def test_pulling_pro_points_the_common_tag_at_pro(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        run_launch(proj, env, DATASQRL_AGENT_EDITION="pro", DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert local_edition(fake, "datasqrl-agent:latest") == "pro"

    def test_pulling_os_leaves_the_common_tag_on_a_local_pro(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro")
        have_local(fake, "datasqrl-agent:latest", "pro")
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env, DATASQRL_AGENT_EDITION="os")
        assert r.returncode == 0, r.stderr
        assert local_edition(fake, "datasqrl-agent:latest") == "pro"


class TestImageOverride:
    def test_a_present_override_runs_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, "custom:dev", "pro")
        r = run_launch(proj, env, DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) == "custom:dev"

    def test_a_missing_override_is_an_error_not_a_pull(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env, DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 1
        assert "DATASQRL_AGENT_IMAGE" in r.stderr
        assert pulls(fake) == []
