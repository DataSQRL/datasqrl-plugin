"""A fake `docker` that keeps image state, and the helpers that set it up and read it back.

Each image is a file under FAKE_DOCKER_DIR: `registry/` holds what `docker pull` can fetch and
`images/` holds what is local. A file's four lines are the image's edition label, its version
label, its repo digests and its image ID, so `docker tag` copies them and `docker image inspect -f`
reads them back.

A `docker run` of the cosign image is the signature check. It passes when the checked digest is
listed in FAKE_DOCKER_DIR/signed, and it fails with FAKE_COSIGN_ERROR when that is set.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest


LAUNCHER = Path(__file__).resolve().parents[3] / "scripts" / "datasqrl-agent.sh"

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


def calls(fake: Path, name: str = "calls") -> str:
    f = fake / name
    return f.read_text() if f.exists() else ""


def run_flag(cwd: Path, env: dict, *args: str, **extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(LAUNCHER), *args], cwd=cwd, env={**env, **extra},
                          capture_output=True, text=True, timeout=30)
