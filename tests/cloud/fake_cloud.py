"""A local stand-in for DataSQRL Cloud's token refresh and MCP endpoints."""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeCloud:
    def __init__(self) -> None:
        self.valid_access = "access-0"
        self.valid_refresh = "refresh-0"
        self.refresh_delay = 0.0
        self.refresh_calls = 0
        self.refresh_arrivals: list[float] = []
        self.mcp_requests: list[dict] = []
        # (status, body) pairs served before the default behaviour.
        self.mcp_overrides: list[tuple[int, str]] = []
        self._lock = threading.Lock()
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self._server.server_address[1]}"

    @property
    def host(self) -> str:
        return self.base_url.removeprefix("http://")

    def start(self) -> "FakeCloud":
        self._thread.start()
        return self

    def stop(self) -> None:
        if self._thread.is_alive():
            self._server.shutdown()
            self._server.server_close()
            self._thread.join()

    def refresh(self, token: str) -> tuple[int, dict]:
        self.refresh_arrivals.append(time.monotonic())
        time.sleep(self.refresh_delay)
        with self._lock:
            self.refresh_calls += 1
            if token != self.valid_refresh:
                return 403, {"message": "Unknown or reused refresh token."}
            n = self.refresh_calls
            self.valid_access, self.valid_refresh = f"access-{n}", f"refresh-{n}"
            return 200, {
                "access_token": self.valid_access,
                "refresh_token": self.valid_refresh,
                "expires_in": 3600,
            }

    def mcp(self, headers: dict, body: str) -> tuple[int, str]:
        self.mcp_requests.append({"headers": headers, "body": body})
        if self.mcp_overrides:
            return self.mcp_overrides.pop(0)
        if headers.get("authorization") != f"Bearer {self.valid_access}":
            return 401, json.dumps({"message": "Invalid access token."})
        message = json.loads(body)
        if "id" not in message:
            return 202, ""
        if message.get("method") == "initialize":
            result = {"protocolVersion": "2025-06-18"}
        else:
            result = {"echo": message.get("method")}
        return 200, json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result})

    def _handler(self):
        cloud = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
                headers = {k.lower(): v for k, v in self.headers.items()}
                if self.path == "/auth/device/token/refresh":
                    status, payload = cloud.refresh(json.loads(body)["refresh_token"])
                    self._send(status, json.dumps(payload))
                elif self.path == "/api/mcp":
                    self._send(*cloud.mcp(headers, body))
                else:
                    self._send(404, "{}")

            def _send(self, status: int, body: str) -> None:
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        return Handler
