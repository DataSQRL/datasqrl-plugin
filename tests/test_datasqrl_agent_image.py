"""Drives scripts/datasqrl-agent.sh's image selection with a fake `docker` that keeps image state.

Each image is a file under FAKE_DOCKER_DIR: `registry/` holds what `docker pull` can fetch and
`images/` holds what is local. A file's four lines are the image's edition label, its version
label, its repo digests and its image ID, so `docker tag` copies them and `docker image inspect -f`
reads them back.

A `docker run` of the cosign image is the signature check. It passes when the checked digest is
listed in FAKE_DOCKER_DIR/signed, and it fails with FAKE_COSIGN_ERROR when that is set.
"""

from __future__ import annotations

import base64
import os
import stat
import subprocess
from pathlib import Path

import pytest

LAUNCHER = Path(__file__).resolve().parents[1] / "scripts" / "datasqrl-agent.sh"

SHIM = r"""#!/bin/sh
D="$FAKE_DOCKER_DIR"
key() { printf '%s' "$1" | tr '/:' '__'; }
printf '%s\n' "$*" >> "$D/calls"
case "$1" in
  image)
    shift 2
    fmt=""
    if [ "$1" = "-f" ]; then fmt="$2"; shift 2; fi
    f="$D/images/$(key "$1")"
    [ -f "$f" ] || exit 1
    case "$fmt" in
      *com.datasqrl.edition*)             sed -n 1p "$f" ;;
      *org.opencontainers.image.version*) sed -n 2p "$f" ;;
      *RepoDigests*)                      sed -n 3p "$f" | tr ' ' '\n' ;;
      *.Id*)                              sed -n 4p "$f" ;;
    esac
    exit 0 ;;
  pull)
    f="$D/registry/$(key "$2")"
    if [ ! -f "$f" ]; then echo "Error response from daemon: denied" >&2; exit 1; fi
    cp "$f" "$D/images/$(key "$2")"; exit 0 ;;
  tag)
    cp "$D/images/$(key "$2")" "$D/images/$(key "$3")"; exit $? ;;
  rmi)
    rm -f "$D/images/$(key "$2")"; exit 0 ;;
  login)
    pw="$(cat)"
    printf '%s' "$pw" > "$D/login_password"
    [ "$pw" = "$FAKE_GOOD_TOKEN" ] || { echo "Error response from daemon: denied" >&2; exit 1; }
    exit 0 ;;
  run)
    case "$*" in
      *sigstore/cosign*" verify "*)
        printf '%s\n' "$@" > "$D/cosign_args"
        prev=""
        for a in "$@"; do
          if [ "$prev" = "-v" ]; then
            src="${a%%:*}"
            [ -f "$src/config.json" ] && cp "$src/config.json" "$D/cosign_config"
          fi
          prev="$a"; target="$a"
        done
        if [ -n "${FAKE_COSIGN_ERROR:-}" ]; then echo "$FAKE_COSIGN_ERROR" >&2; exit 1; fi
        grep -qx "${target#*@}" "$D/signed" 2>/dev/null && exit 0
        echo "Error: no signatures found" >&2; exit 10 ;;
    esac
    printf '%s\n' "$@" > "$D/run_args"; exit 0 ;;
  *) exit 0 ;;
esac
"""

# Answers GET https://api.github.com/user the way GitHub does: the body, then the HTTP status on
# its own line (the launcher asks for it with -w). The token arrives as a header on stdin.
CURL_SHIM = r"""#!/bin/sh
D="$FAKE_DOCKER_DIR"
printf '%s\n' "$*" >> "$D/curl_calls"
hdr="$(cat)"
if [ "$hdr" = "Authorization: Bearer $FAKE_LOOKUP_TOKEN" ]; then
  printf '{\n  "login": "datasqrl-agent-bot",\n  "id": 1\n}\n200'
else
  printf '{\n  "message": "Bad credentials"\n}\n401'
fi
"""

GOOD_TOKEN = "ghp_goodtoken123"

OS_REGISTRY = "ghcr.io/datasqrl/adv-agent:latest"
PRO_REGISTRY = "ghcr.io/datasqrl/pro-agent:latest"


def _key(name: str) -> str:
    return name.replace("/", "_").replace(":", "_")


@pytest.fixture
def project(tmp_path: Path):
    shim_dir = tmp_path / "bin"
    shim_dir.mkdir()
    shim = shim_dir / "docker"
    shim.write_text(SHIM)
    shim.chmod(shim.stat().st_mode | stat.S_IEXEC)
    curl = shim_dir / "curl"
    curl.write_text(CURL_SHIM)
    curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
    fake = tmp_path / "fake-docker"
    (fake / "registry").mkdir(parents=True)
    (fake / "images").mkdir()
    proj = tmp_path / "proj"
    (proj / ".claude").mkdir(parents=True)
    home = tmp_path / "home"
    home.mkdir()
    env = {
        k: v for k, v in os.environ.items()
        if k not in ("DATASQRL_AGENT_EDITION", "DATASQRL_AGENT_IMAGE", "DATASQRL_PRO_TOKEN")
    }
    env.update({
        "PATH": f"{shim_dir}:{os.environ['PATH']}",
        "FAKE_DOCKER_DIR": str(fake),
        "DATASQRL_AGENT_ALLOW_NO_GIT": "1",
        "HOME": str(home),
        "XDG_STATE_HOME": str(state_dir(fake)),
        "ANTHROPIC_API_KEY": "sk-test",
        # GitHub knows the good token, and ghcr.io accepts it.
        "FAKE_LOOKUP_TOKEN": GOOD_TOKEN,
        "FAKE_GOOD_TOKEN": GOOD_TOKEN,
    })
    return proj, fake, env


def state_dir(fake: Path) -> Path:
    """XDG_STATE_HOME for the launcher under test."""
    return fake.parent / "state"


def verified_images_file(fake: Path) -> Path:
    return state_dir(fake) / "datasqrl-agent" / "verified-images"


def image_id(name: str) -> str:
    return f"sha256:id-{_key(name)}"


def digest_of(name: str) -> str:
    return f"sha256:dg-{_key(name)}"


def repo_digest(name: str) -> str:
    """The `<repository>@<digest>` that `docker pull <name>` records."""
    return f"{name.rsplit(':', 1)[0]}@{digest_of(name)}"


def publish(fake: Path, name: str, edition: str, version: str = "1.0.5", signed: bool = True,
            other_repo_digests: tuple[str, ...] = ()) -> None:
    digests = " ".join((*other_repo_digests, repo_digest(name)))
    (fake / "registry" / _key(name)).write_text(f"{edition}\n{version}\n{digests}\n{image_id(name)}\n")
    if signed:
        with (fake / "signed").open("a") as signed_file:
            signed_file.write(digest_of(name) + "\n")


def have_local(fake: Path, name: str, edition: str, version: str = "1.0.5",
               checked: bool = True) -> None:
    """A local image. `checked` means an earlier pull verified its signature on this machine."""
    (fake / "images" / _key(name)).write_text(f"{edition}\n{version}\n\n{image_id(name)}\n")
    if checked:
        record = verified_images_file(fake)
        record.parent.mkdir(parents=True, exist_ok=True)
        with record.open("a") as record_file:
            record_file.write(image_id(name) + "\n")


def local_edition(fake: Path, name: str) -> str | None:
    f = fake / "images" / _key(name)
    return f.read_text().splitlines()[0] if f.exists() else None


def verified_ids(fake: Path) -> list[str]:
    record = verified_images_file(fake)
    return record.read_text().splitlines() if record.exists() else []


def cosign_args(fake: Path) -> list[str]:
    f = fake / "cosign_args"
    return f.read_text().splitlines() if f.exists() else []


def run_launch(proj: Path, env: dict, **extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(LAUNCHER), "--mode", "implementation", "--detach"],
        cwd=proj, env={**env, **extra}, capture_output=True, text=True, timeout=30,
    )


def ran_image(fake: Path) -> str | None:
    """The image `docker run` was given, or None when no run started.

    The launcher runs a checked image by its ID, so an ID is reported as the name it belongs to.
    """
    args_file = fake / "run_args"
    if not args_file.exists():
        return None
    args = args_file.read_text().splitlines()
    names = ("adv-agent:latest", "pro-agent:latest", "custom:dev", OS_REGISTRY, PRO_REGISTRY)
    for image in names:
        if image in args or image_id(image) in args:
            return {OS_REGISTRY: "adv-agent:latest", PRO_REGISTRY: "pro-agent:latest"}.get(image, image)
    return "unknown"


def ran_image_id(fake: Path) -> str | None:
    args_file = fake / "run_args"
    if not args_file.exists():
        return None
    return next((a for a in args_file.read_text().splitlines() if a.startswith("sha256:")), None)


def pulls(fake: Path) -> list[str]:
    calls = fake / "calls"
    lines = calls.read_text().splitlines() if calls.exists() else []
    return [line.split()[1] for line in lines if line.startswith("pull ")]


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


def calls(fake: Path, name: str = "calls") -> str:
    f = fake / name
    return f.read_text() if f.exists() else ""


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


def run_flag(cwd: Path, env: dict, *args: str, **extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(LAUNCHER), *args], cwd=cwd, env={**env, **extra},
                          capture_output=True, text=True, timeout=30)


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
