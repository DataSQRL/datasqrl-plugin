"""`mcp-headers` and `mcp-bridge`: the token reaches MCP clients and stays fresh past expiry."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from tests.cloud.fake_cloud import FakeCloud

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "datasqrl-cloud.sh"


@pytest.fixture
def cloud():
    fake = FakeCloud().start()
    yield fake
    fake.stop()


@pytest.fixture
def config(tmp_path):
    return tmp_path / "config"


def seed(config: Path, host: str, access: str, refresh: str, expires_in: int) -> Path:
    path = config / "datasqrl" / "credentials.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    entry = {"access_token": access, "refresh_token": refresh, "expires_at": int(time.time()) + expires_in}
    path.write_text(json.dumps({host: entry}))
    return path


def run(config: Path, cloud: FakeCloud, *args: str, stdin: str = "", **env: str):
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=30,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(config.parent),
             "XDG_CONFIG_HOME": str(config), "DATASQRL_BASE_URL": cloud.base_url, **env},
    )


def lines(*messages: dict) -> str:
    return "".join(json.dumps(m) + "\n" for m in messages)


def shim_curl_and_jq(tmp_path: Path) -> Path:
    """Puts curl and jq wrappers that log their arguments in a directory; returns the log path."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = bin_dir / "argv.log"
    for tool in ("curl", "jq"):
        shim = bin_dir / tool
        shim.write_text(f'#!/bin/bash\nprintf "%s\\n" "{tool} $*" >>"{log}"\nexec {shutil.which(tool)} "$@"\n')
        shim.chmod(0o755)
    return log


class TestMcpHeaders:
    def test_prints_the_cached_token_without_refreshing(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        r = run(config, cloud, "mcp-headers")
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout) == {"Authorization": "Bearer access-0"}
        assert cloud.refresh_calls == 0

    def test_refreshes_an_expiring_token_and_stores_the_rotated_refresh_token(self, cloud, config):
        creds = seed(config, cloud.host, "access-0", "refresh-0", 30)
        r = run(config, cloud, "mcp-headers")
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout) == {"Authorization": "Bearer access-1"}
        assert json.loads(creds.read_text())[cloud.host]["refresh_token"] == "refresh-1"

    def test_fails_with_a_login_hint_when_not_signed_in(self, cloud, config):
        r = run(config, cloud, "mcp-headers")
        assert r.returncode == 1
        assert r.stdout == ""
        assert "login" in r.stderr

    def test_uses_the_token_of_the_host_claude_code_connects_to(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        r = run(config, cloud, "mcp-headers", CLAUDE_CODE_MCP_SERVER_URL="https://other.example/api/mcp")
        assert r.returncode == 1
        assert "access-0" not in r.stdout
        assert "other.example" in r.stderr

    def test_concurrent_refreshes_spend_the_refresh_token_once(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 30)
        cloud.refresh_delay = 0.5
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda _: run(config, cloud, "mcp-headers"), range(3)))
        assert [r.returncode for r in results] == [0, 0, 0], [r.stderr for r in results]
        assert cloud.refresh_calls == 1
        assert {r.stdout.strip() for r in results} == {json.dumps({"Authorization": "Bearer access-1"}, separators=(",", ":"))}
        assert not (config / "datasqrl" / ".refresh.lock").exists()

    def test_a_slow_refresh_gives_up_and_its_lock_is_never_taken_over(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 30)
        cloud.refresh_delay = 9

        def timed_run(_):
            r = run(config, cloud, "mcp-headers")
            return r, time.monotonic()

        start = time.monotonic()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(timed_run, range(2)))
        assert [r.returncode for r, _ in results] == [1, 1]
        first_exit = min(end for _, end in results)
        # Each refresh call gives up after 5s; the second starts only once the first process let go.
        assert first_exit - start < 7
        assert len(cloud.refresh_arrivals) == 2
        assert cloud.refresh_arrivals[1] >= first_exit - 0.5
        assert not (config / "datasqrl" / ".refresh.lock").exists()

    def test_a_lock_left_by_a_killed_process_is_taken_over(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 30)
        lock = config / "datasqrl" / ".refresh.lock"
        lock.mkdir()
        (lock / "owner").write_text("killed")
        old = time.time() - 60
        os.utime(lock, (old, old))
        r = run(config, cloud, "mcp-headers")
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout) == {"Authorization": "Bearer access-1"}
        assert not lock.exists()

    def test_tokens_never_appear_in_a_command_line(self, cloud, config, tmp_path):
        log = shim_curl_and_jq(tmp_path)
        seed(config, cloud.host, "revoked", "refresh-0", 3600)
        call = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": "createSecret", "arguments": {"value": "s3cr3t-value"}}}
        r = run(config, cloud, "mcp-bridge", stdin=lines(call),
                PATH=f"{log.parent}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)["result"] == {"echo": "tools/call"}
        logged = log.read_text()
        assert "curl" in logged and "jq" in logged
        for secret in ("revoked", "refresh-0", "access-1", "refresh-1", "s3cr3t-value"):
            assert secret not in logged


class TestMcpBridge:
    def test_relays_a_request_with_the_token_and_mcp_accept_header(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        r = run(config, cloud, "mcp-bridge", stdin=lines({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}))
        assert r.returncode == 0, r.stderr
        assert [json.loads(x) for x in r.stdout.splitlines()] == [
            {"jsonrpc": "2.0", "id": 1, "result": {"echo": "tools/list"}}]
        headers = cloud.mcp_requests[0]["headers"]
        assert headers["authorization"] == "Bearer access-0"
        assert "application/json" in headers["accept"] and "text/event-stream" in headers["accept"]

    def test_relays_a_message_larger_than_one_command_line_argument_may_be(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        call = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"blob": "x" * 200_000}}
        r = run(config, cloud, "mcp-bridge", stdin=lines(call))
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)["result"] == {"echo": "tools/call"}
        assert json.loads(cloud.mcp_requests[0]["body"]) == call

    def test_a_notification_gets_no_reply(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        r = run(config, cloud, "mcp-bridge", stdin=lines({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        assert r.returncode == 0, r.stderr
        assert r.stdout == ""
        assert len(cloud.mcp_requests) == 1

    def test_sends_the_negotiated_protocol_version_after_initialize(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        stdin = lines({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                      {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        r = run(config, cloud, "mcp-bridge", stdin=stdin)
        assert r.returncode == 0, r.stderr
        assert "mcp-protocol-version" not in cloud.mcp_requests[0]["headers"]
        assert cloud.mcp_requests[1]["headers"]["mcp-protocol-version"] == "2025-06-18"

    def test_a_rejected_token_is_refreshed_once_and_the_request_retried(self, cloud, config):
        seed(config, cloud.host, "revoked", "refresh-0", 3600)
        r = run(config, cloud, "mcp-bridge", stdin=lines({"jsonrpc": "2.0", "id": 7, "method": "tools/list"}))
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout) == {"jsonrpc": "2.0", "id": 7, "result": {"echo": "tools/list"}}
        assert cloud.refresh_calls == 1
        assert len(cloud.mcp_requests) == 2

    def test_http_errors_become_json_rpc_errors_and_the_bridge_keeps_going(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        cloud.mcp_overrides = [(429, json.dumps({"message": "Too many requests."}))]
        stdin = lines({"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                      {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        r = run(config, cloud, "mcp-bridge", stdin=stdin)
        assert r.returncode == 0, r.stderr
        first, second = (json.loads(x) for x in r.stdout.splitlines())
        assert first["id"] == 1 and "429" in first["error"]["message"]
        assert "Too many requests." in first["error"]["message"]
        assert second == {"jsonrpc": "2.0", "id": 2, "result": {"echo": "tools/list"}}

    def test_a_json_rpc_error_from_the_server_is_passed_through(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        error = {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Batches are not supported."}}
        cloud.mcp_overrides = [(400, json.dumps(error))]
        r = run(config, cloud, "mcp-bridge", stdin=lines({"jsonrpc": "2.0", "id": 3, "method": "x"}))
        assert json.loads(r.stdout) == error

    def test_not_signed_in_answers_each_request_with_a_login_hint(self, cloud, config):
        stdin = lines({"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                      {"jsonrpc": "2.0", "id": "b", "method": "tools/list"})
        r = run(config, cloud, "mcp-bridge", stdin=stdin)
        assert r.returncode == 0, r.stderr
        replies = [json.loads(x) for x in r.stdout.splitlines()]
        assert [x["id"] for x in replies] == [1, "b"]
        assert all("login" in x["error"]["message"] for x in replies)
        assert cloud.mcp_requests == []

    def test_an_unreachable_server_is_reported_per_request(self, cloud, config):
        seed(config, cloud.host, "access-0", "refresh-0", 3600)
        cloud.stop()
        r = run(config, cloud, "mcp-bridge", stdin=lines({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}))
        assert r.returncode == 0, r.stderr
        assert "cannot reach" in json.loads(r.stdout)["error"]["message"]
