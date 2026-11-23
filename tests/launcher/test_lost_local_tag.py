"""A local image is found when Docker does not resolve its local tag, for both editions.

Docker Desktop in Resource Saver mode stops its engine when idle, and its cache then can answer
"No such image" for `adv-agent:latest` or `pro-agent:latest` although the image is local. A local
tag can also be lost while the image stays, under its ghcr.io name or untagged. The launcher asks
for the local tag again after a lookup by the ghcr.io name starts the engine. Else it finds a
checked image of the edition by its ghcr.io name or by an ID in verified-images, and tags it again.
"""

from __future__ import annotations

from tests.launcher.fakes.docker_images import (  # noqa: F401
    OS_REGISTRY,
    PRO_REGISTRY,
    calls,
    project,
    publish,
    have_local,
    have_untagged,
    image_id,
    local_edition,
    ran_image,
    ran_image_id,
    pulls,
    run_flag,
    run_launch,
    verified_images_file,
)

OS_MISSING = "adv-agent:latest (os edition) is missing · run: datasqrl-agent.sh --pull-image"
PRO_MISSING = "pro-agent:latest (pro edition) is missing · run: datasqrl-agent.sh --pull-image"


def tag_calls(fake) -> list[str]:
    return [line for line in calls(fake).splitlines() if line.startswith("tag ")]


class TestPausedDockerDesktopEngine:
    """The cache denies the local tag until a lookup by the ghcr.io name starts the engine."""

    def test_an_os_image_is_present(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", "1.0.991")
        r = run_flag(proj, env, "--image-exists", FAKE_ENGINE_PAUSED="1")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "adv-agent:latest is present · edition: os · version: 1.0.991"
        assert tag_calls(fake) == []
        assert "tagged" not in r.stderr

    def test_an_os_image_is_present_when_os_is_selected_explicitly(self, project):
        # The os lookup starts the engine on its own, not only through the pro lookup of rule 3.
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", "1.0.991")
        r = run_flag(proj, env, "--image-exists", FAKE_ENGINE_PAUSED="1", DATASQRL_AGENT_EDITION="os")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "adv-agent:latest is present · edition: os · version: 1.0.991"
        assert f"image inspect -f {{{{.Id}}}} {OS_REGISTRY}" in calls(fake)
        assert tag_calls(fake) == []

    def test_a_pro_image_selects_pro(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro", "1.0.918")
        r = run_flag(proj, env, "--image-exists", FAKE_ENGINE_PAUSED="1")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "pro-agent:latest is present · edition: pro · version: 1.0.918"
        assert tag_calls(fake) == []

    def test_a_pro_image_selects_pro_over_a_local_os_image(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        have_local(fake, "pro-agent:latest", "pro")
        r = run_flag(proj, env, "--image-exists", FAKE_ENGINE_PAUSED="1")
        assert r.returncode == 0, r.stderr
        assert r.stdout.startswith("pro-agent:latest is present")

    def test_a_pro_image_is_present_when_pro_is_selected_explicitly(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro")
        r = run_flag(proj, env, "--image-exists", FAKE_ENGINE_PAUSED="1", DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 0, r.stderr
        assert r.stdout.startswith("pro-agent:latest is present")
        assert tag_calls(fake) == []

    def test_a_missing_image_is_still_missing_and_is_not_pulled(self, project):
        proj, fake, env = project
        r = run_flag(proj, env, "--image-exists", FAKE_ENGINE_PAUSED="1")
        assert r.returncode == 1
        assert r.stdout.strip() == OS_MISSING
        assert pulls(fake) == []

    def test_an_os_run_uses_the_local_image_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        r = run_launch(proj, env, FAKE_ENGINE_PAUSED="1")
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) == "adv-agent:latest"

    def test_a_pro_run_uses_the_local_image_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, "pro-agent:latest", "pro")
        r = run_launch(proj, env, FAKE_ENGINE_PAUSED="1")
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) == "pro-agent:latest"


class TestLostTagUnderTheGhcrName:
    def test_an_os_image_is_tagged_again(self, project):
        proj, fake, env = project
        have_local(fake, OS_REGISTRY, "os", "1.0.991")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "adv-agent:latest is present · edition: os · version: 1.0.991"
        assert tag_calls(fake) == [f"tag {image_id(OS_REGISTRY)} adv-agent:latest"]
        assert (f"Docker did not resolve adv-agent:latest, so the launcher tagged the checked image "
                f"{image_id(OS_REGISTRY)} with it again." in r.stderr)
        assert pulls(fake) == []

    def test_a_pro_image_is_tagged_again_and_selects_pro(self, project):
        proj, fake, env = project
        have_local(fake, PRO_REGISTRY, "pro", "1.0.918")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "pro-agent:latest is present · edition: pro · version: 1.0.918"
        assert tag_calls(fake) == [f"tag {image_id(PRO_REGISTRY)} pro-agent:latest"]

    def test_an_os_run_uses_the_image_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image_id(fake) == image_id(OS_REGISTRY)

    def test_an_unchecked_image_stays_missing(self, project):
        proj, fake, env = project
        have_local(fake, OS_REGISTRY, "os", checked=False)
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 1
        assert r.stdout.strip() == OS_MISSING
        assert tag_calls(fake) == []

    def test_an_unchecked_image_gives_way_to_an_older_checked_image(self, project):
        # An undecided signature check leaves the pulled image under its ghcr.io name, unchecked.
        proj, fake, env = project
        have_untagged(fake, "older-os", "os", "1.0.712")
        have_local(fake, OS_REGISTRY, "os", "1.0.991", checked=False)
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "adv-agent:latest is present · edition: os · version: 1.0.712"
        assert tag_calls(fake) == [f"tag {image_id('older-os')} adv-agent:latest"]


class TestLostTagOnAnUntaggedImage:
    def test_an_os_image_is_tagged_again(self, project):
        proj, fake, env = project
        have_untagged(fake, "adv-agent:latest", "os", "1.0.991")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "adv-agent:latest is present · edition: os · version: 1.0.991"
        assert tag_calls(fake) == [f"tag {image_id('adv-agent:latest')} adv-agent:latest"]

    def test_a_pro_image_is_tagged_again_and_selects_pro(self, project):
        proj, fake, env = project
        have_untagged(fake, "pro-agent:latest", "pro", "1.0.918")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "pro-agent:latest is present · edition: pro · version: 1.0.918"
        assert local_edition(fake, "pro-agent:latest") == "pro"

    def test_a_pro_image_selects_pro_over_a_local_os_image(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        have_untagged(fake, "pro-agent:latest", "pro")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.startswith("pro-agent:latest is present")

    def test_the_newest_checked_image_of_the_edition_wins(self, project):
        proj, fake, env = project
        have_untagged(fake, "old-pro", "pro", "1.0.871")
        have_untagged(fake, "new-pro", "pro", "1.0.918")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert "version: 1.0.918" in r.stdout
        assert tag_calls(fake) == [f"tag {image_id('new-pro')} pro-agent:latest"]

    def test_a_checked_id_that_is_no_longer_local_is_skipped(self, project):
        proj, fake, env = project
        have_untagged(fake, "kept-os", "os", "1.0.712")
        record = verified_images_file(fake)
        record.write_text(record.read_text() + image_id("deleted-os") + "\n")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert "version: 1.0.712" in r.stdout

    def test_a_pro_run_uses_the_image_without_pulling(self, project):
        proj, fake, env = project
        have_untagged(fake, "pro-agent:latest", "pro")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image_id(fake) == image_id("pro-agent:latest")

    def test_an_os_run_uses_the_image_without_pulling(self, project):
        proj, fake, env = project
        have_untagged(fake, "adv-agent:latest", "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert ran_image_id(fake) == image_id("adv-agent:latest")


class TestOnlyCheckedImagesOfTheSelectedEdition:
    def test_an_unchecked_untagged_pro_image_does_not_select_pro(self, project):
        proj, fake, env = project
        have_untagged(fake, "pro-agent:latest", "pro", checked=False)
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 1
        assert r.stdout.strip() == OS_MISSING
        assert tag_calls(fake) == []

    def test_a_checked_os_image_never_selects_pro(self, project):
        proj, fake, env = project
        have_untagged(fake, "adv-agent:latest", "os")
        r = run_flag(proj, env, "--image-exists")
        assert r.returncode == 0, r.stderr
        assert r.stdout.startswith("adv-agent:latest is present")
        assert local_edition(fake, "pro-agent:latest") is None

    def test_explicit_os_never_takes_an_untagged_pro_image(self, project):
        proj, fake, env = project
        have_untagged(fake, "pro-agent:latest", "pro")
        r = run_flag(proj, env, "--image-exists", DATASQRL_AGENT_EDITION="os")
        assert r.returncode == 1
        assert r.stdout.strip() == OS_MISSING
        assert local_edition(fake, "adv-agent:latest") is None

    def test_explicit_pro_never_takes_an_untagged_os_image(self, project):
        proj, fake, env = project
        have_untagged(fake, "adv-agent:latest", "os")
        r = run_flag(proj, env, "--image-exists", DATASQRL_AGENT_EDITION="pro")
        assert r.returncode == 1
        assert r.stdout.strip() == PRO_MISSING
        assert local_edition(fake, "pro-agent:latest") is None

    def test_a_custom_image_never_tags_a_checked_image(self, project):
        proj, fake, env = project
        have_local(fake, "custom:dev", "pro")
        have_untagged(fake, "pro-agent:latest", "pro")
        r = run_flag(proj, env, "--image-exists", DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 0, r.stderr
        assert r.stdout.startswith("custom:dev is present")
        assert tag_calls(fake) == []


class TestFailedTag:
    def test_image_exists_reports_missing(self, project):
        proj, fake, env = project
        have_untagged(fake, "adv-agent:latest", "os")
        r = run_flag(proj, env, "--image-exists", FAKE_TAG_ERROR="Error response from daemon: tag failed")
        assert r.returncode == 1
        assert r.stdout.strip() == OS_MISSING

    def test_a_run_pulls_a_new_image(self, project):
        proj, fake, env = project
        have_untagged(fake, "adv-agent:latest", "os")
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env, FAKE_TAG_ERROR="Error response from daemon: tag failed")
        assert pulls(fake) == [OS_REGISTRY]
        assert r.returncode == 1
        assert ran_image(fake) is None
