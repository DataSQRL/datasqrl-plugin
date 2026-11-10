"""The signature check after each pull, and runs of the checked image by its ID."""

from __future__ import annotations

import base64
import signal
import subprocess
import time

from tests.launcher.fakes.docker_images import (  # noqa: F401
    GOOD_TOKEN,
    LAUNCHER,
    OS_REGISTRY,
    PRO_REGISTRY,
    project,
    state_dir,
    image_id,
    repo_digest,
    publish,
    have_local,
    local_edition,
    verified_ids,
    cosign_args,
    run_launch,
    ran_image,
    ran_image_id,
    pulls,
    run_flag,
)


SIGNER_IDENTITY = "https://github.com/DataSQRL/code-agent/.github/workflows/build-and-push.yml@refs/heads/main"
SIGNER_ISSUER = "https://token.actions.githubusercontent.com"


class TestSignatureCheck:
    def test_signed_pull_is_tagged_and_recorded(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        args = cosign_args(fake)
        assert args[-1] == repo_digest(OS_REGISTRY)
        assert args[args.index("--certificate-identity") + 1] == SIGNER_IDENTITY
        assert args[args.index("--certificate-oidc-issuer") + 1] == SIGNER_ISSUER
        assert local_edition(fake, "adv-agent:latest") == "os"
        assert verified_ids(fake) == [image_id(OS_REGISTRY)]
        assert ran_image(fake) == "adv-agent:latest"

    def test_unsigned_pull_is_refused_and_removed(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os", signed=False)
        r = run_launch(proj, env)
        assert r.returncode == 1
        assert "signature" in r.stderr
        assert local_edition(fake, "adv-agent:latest") is None
        assert local_edition(fake, OS_REGISTRY) is None
        assert verified_ids(fake) == []
        assert ran_image(fake) is None

    def test_an_unsigned_pull_keeps_the_checked_local_image(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", "1.0.4")
        publish(fake, OS_REGISTRY, "os", "1.0.5", signed=False)
        r = run_flag(proj, env, "--pull-image")
        assert r.returncode == 1
        assert local_edition(fake, "adv-agent:latest") == "os"
        assert verified_ids(fake) == [image_id("adv-agent:latest")]

    def test_check_uses_the_digest_of_the_pulled_name(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os", other_repo_digests=("mirror.example/adv-agent@sha256:other",))
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert cosign_args(fake)[-1] == repo_digest(OS_REGISTRY)

    def test_pro_check_gets_the_login_from_a_file(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert GOOD_TOKEN not in "\n".join(cosign_args(fake))
        auth = base64.b64encode(f"datasqrl-agent-bot:{GOOD_TOKEN}".encode()).decode()
        assert auth in (fake / "cosign_config").read_text()
        assert not list((state_dir(fake) / "datasqrl-agent").glob("cosign-auth.*"))

    def test_a_pro_check_keeps_the_login_folder_of_another_check(self, project):
        """Two launchers can check at the same time, so each one removes only its own folder."""
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        other_check_folder = state_dir(fake) / "datasqrl-agent" / "cosign-auth.othercheck"
        other_check_folder.mkdir(parents=True)
        (other_check_folder / "config.json").write_text("{}")
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 0, r.stderr
        assert (other_check_folder / "config.json").exists()
        assert list((state_dir(fake) / "datasqrl-agent").glob("cosign-auth.*")) == [other_check_folder]

    def test_a_failed_pro_check_removes_its_login_folder(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro", signed=False)
        r = run_launch(proj, env, DATASQRL_PRO_TOKEN=GOOD_TOKEN)
        assert r.returncode == 1
        assert not list((state_dir(fake) / "datasqrl-agent").glob("cosign-auth.*"))

    def test_a_pro_check_stopped_with_sigterm_removes_its_login_folder(self, project):
        proj, fake, env = project
        publish(fake, PRO_REGISTRY, "pro")
        launcher_process = subprocess.Popen(
            ["bash", str(LAUNCHER), "--mode", "implementation", "--detach"], cwd=proj,
            env={**env, "DATASQRL_PRO_TOKEN": GOOD_TOKEN, "FAKE_COSIGN_WAIT": "2"},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while not (fake / "cosign_started").exists():
            assert time.monotonic() < deadline, "the signature check never started"
            time.sleep(0.05)
        assert list((state_dir(fake) / "datasqrl-agent").glob("cosign-auth.*"))
        launcher_process.send_signal(signal.SIGTERM)
        # Bash runs the EXIT trap, then ends itself with the same signal.
        assert launcher_process.wait(timeout=20) == -signal.SIGTERM
        assert not list((state_dir(fake) / "datasqrl-agent").glob("cosign-auth.*"))

    def test_os_check_uses_no_login(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert "DOCKER_CONFIG=/cosign-auth" not in cosign_args(fake)
        assert not (fake / "cosign_config").exists()

    def test_a_network_failure_is_explained(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        r = run_launch(proj, env, FAKE_COSIGN_ERROR=(
            "Error: dial tcp: lookup tuf-repo-cdn.sigstore.dev: no such host"))
        assert r.returncode == 1
        assert "network access to Sigstore" in r.stderr
        assert ran_image(fake) is None


class TestCheckedImageRun:
    def test_a_checked_image_runs_by_id_without_a_pull(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert pulls(fake) == []
        assert cosign_args(fake) == []
        assert ran_image_id(fake) == image_id("adv-agent:latest")

    def test_an_unchecked_local_image_is_pulled_and_checked(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", "1.0.4", checked=False)
        publish(fake, OS_REGISTRY, "os", "1.0.5")
        r = run_launch(proj, env)
        assert r.returncode == 0, r.stderr
        assert "has no checked signature" in r.stderr
        assert pulls(fake) == [OS_REGISTRY]
        assert ran_image_id(fake) == image_id(OS_REGISTRY)

    def test_a_custom_image_skips_the_check_with_a_warning(self, project):
        proj, fake, env = project
        have_local(fake, "custom:dev", "os", checked=False)
        r = run_launch(proj, env, DATASQRL_AGENT_IMAGE="custom:dev")
        assert r.returncode == 0, r.stderr
        assert "Warning: DATASQRL_AGENT_IMAGE is set" in r.stderr
        assert cosign_args(fake) == []
        assert ran_image(fake) == "custom:dev"

    def test_check_config_runs_the_checked_id(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os")
        run_flag(proj, env, "--check-config")
        assert ran_image_id(fake) == image_id("adv-agent:latest")

    def test_check_config_refuses_an_unchecked_image_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", checked=False)
        publish(fake, OS_REGISTRY, "os")
        r = run_flag(proj, env, "--check-config")
        assert r.returncode == 1
        assert "--pull-image" in r.stderr
        assert pulls(fake) == []
        assert ran_image(fake) is None

    def test_show_options_refuses_an_unchecked_image_without_pulling(self, project):
        proj, fake, env = project
        have_local(fake, "adv-agent:latest", "os", checked=False)
        r = run_flag(proj, env, "--show-options")
        assert r.returncode == 1
        assert "--pull-image" in r.stderr
        assert ran_image(fake) is None

    def test_an_unwritable_record_still_runs_the_checked_image(self, project):
        proj, fake, env = project
        publish(fake, OS_REGISTRY, "os")
        record_dir = state_dir(fake) / "datasqrl-agent"
        record_dir.mkdir(parents=True)
        record_dir.chmod(0o500)
        try:
            r = run_launch(proj, env)
        finally:
            record_dir.chmod(0o700)
        assert r.returncode == 0, r.stderr
        assert "Warning" in r.stderr
        assert ran_image_id(fake) == image_id(OS_REGISTRY)
