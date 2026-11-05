"""Drives scripts/datasqrl-agent.sh --show-options with the fake `docker` from fakes/docker_images.py."""

from __future__ import annotations

import subprocess
from pathlib import Path

from tests.launcher.fakes.docker_images import (  # noqa: F401
    LAUNCHER,
    project,
    image_id,
    have_local,
)


OS_LOCAL = "adv-agent:latest"


def show_options(cwd: Path, env: dict, *args: str, **extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(LAUNCHER), "--show-options", *args],
        cwd=cwd, env={**env, **extra}, capture_output=True, text=True, timeout=30,
    )


def run_args(fake: Path) -> list[str]:
    f = fake / "run_args"
    return f.read_text().splitlines() if f.exists() else []


def image_args(fake: Path, image: str = OS_LOCAL) -> list[str]:
    """What the image was asked: everything after its name, or after its ID for a checked image."""
    args = run_args(fake)
    position = args.index(image) if image in args else args.index(image_id(image))
    return args[position + 1:]


def test_asks_the_image_with_no_repository(project, tmp_path):  # noqa: F811
    proj, fake, env = project
    have_local(fake, OS_LOCAL, "os")
    env = {k: v for k, v in env.items() if k != "DATASQRL_AGENT_ALLOW_NO_GIT"}
    outside = tmp_path / "not-a-repo"
    outside.mkdir()

    result = show_options(outside, env)

    assert result.returncode == 0, result.stderr
    assert "--rm" in run_args(fake)
    assert image_args(fake) == ["--show-options"]
    assert result.stdout.startswith(f"Image              {OS_LOCAL} · edition: os")


def test_forwards_provider_variables_by_name_only(project):  # noqa: F811
    proj, fake, env = project
    have_local(fake, OS_LOCAL, "os")

    show_options(proj, env, FIREWORKS_API_KEY="fw-secret", GITHUB_TOKEN="unrelated")

    args = run_args(fake)
    assert args[args.index("FIREWORKS_API_KEY") - 1] == "-e"
    assert not any("fw-secret" in a for a in args)
    assert "GITHUB_TOKEN" not in args


def test_an_id_and_a_harness_reach_the_image(project):  # noqa: F811
    proj, fake, env = project
    have_local(fake, OS_LOCAL, "os")

    result = show_options(proj, env, "fireworks", "--harness", "pi")

    assert result.returncode == 0, result.stderr
    assert image_args(fake) == ["--show-options", "fireworks", "--harness", "pi"]


def test_a_missing_image_is_an_error_and_never_pulled(project):  # noqa: F811
    proj, fake, env = project

    result = show_options(proj, env)

    assert result.returncode == 1
    assert "datasqrl-agent.sh --pull-image" in result.stderr
    assert "pull" not in (fake / "calls").read_text()
    assert run_args(fake) == []


def test_a_custom_image_is_used_as_it_is(project):  # noqa: F811
    proj, fake, env = project
    have_local(fake, "custom:dev", "os")

    result = show_options(proj, env, DATASQRL_AGENT_IMAGE="custom:dev")

    assert result.returncode == 0, result.stderr
    assert image_args(fake, "custom:dev") == ["--show-options"]


def test_provider_flag_reaches_the_image(project):  # noqa: F811
    proj, fake, env = project
    have_local(fake, OS_LOCAL, "os")

    result = show_options(proj, env, "--provider", "amazon-bedrock")

    assert result.returncode == 0, result.stderr
    assert image_args(fake) == ["--show-options", "--provider", "amazon-bedrock"]


def test_a_model_is_refused(project):  # noqa: F811
    proj, fake, env = project
    have_local(fake, OS_LOCAL, "os")

    result = show_options(proj, env, "--model", "m")

    assert result.returncode == 1
    assert "not '--model'" in result.stderr
    assert run_args(fake) == []


def test_detach_is_refused(project):  # noqa: F811
    proj, fake, env = project
    have_local(fake, OS_LOCAL, "os")

    assert show_options(proj, env, "--detach").returncode == 1
    assert run_args(fake) == []
