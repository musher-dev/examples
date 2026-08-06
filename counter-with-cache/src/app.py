"""Two workloads, wired together: a web service backed by a Redis cache.

Everything here is standard library. There is no Redis client dependency
because the interesting part of this example is not the client — it is that
this process never learned the cache's address at build time. It reads
``REDIS_URL`` from the environment, and Musher put it there by resolving the
connection declared in ``musher/blueprint.yaml``.

Change which cache this talks to and you change one line of YAML. You do not
rebuild the image.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import FrameType
from urllib.parse import urlparse

PORT = int(os.environ.get("PORT", "8080"))
REDIS_URL = os.environ.get("REDIS_URL", "")
COUNTER_KEY = os.environ.get("COUNTER_KEY", "visits")

# Kept short on purpose. A readiness probe that hangs is worse than one that
# fails: the platform cannot tell "starting" from "wedged".
_TIMEOUT_SECONDS = 2.0


class RedisError(RuntimeError):
    """The cache could not be reached, or answered something unexpected."""


def _address() -> tuple[str, int]:
    """Split ``redis://host:port`` into the pieces ``socket.create_connection`` wants.

    The producing Component publishes this whole URL as its ``url`` output —
    see ``musher/component-cache.yaml``. Parsing it here rather than taking a
    host and a port separately is deliberate: one wire carries one value, and
    a URL is the shape every Redis client already expects.
    """
    if not REDIS_URL:
        msg = "REDIS_URL is empty — the cache connection was not wired"
        raise RedisError(msg)
    parsed = urlparse(REDIS_URL)
    if parsed.scheme != "redis" or not parsed.hostname:
        msg = f"REDIS_URL={REDIS_URL!r} is not a redis:// URL"
        raise RedisError(msg)
    return (parsed.hostname, parsed.port or 6379)


def _encode(*args: str) -> bytes:
    """Encode one command in RESP, the Redis wire protocol.

    ``INCR visits`` becomes ``*2\\r\\n$4\\r\\nINCR\\r\\n$6\\r\\nvisits\\r\\n``.
    That is the entire protocol you need for this example.
    """
    parts = [f"*{len(args)}\r\n".encode()]
    for arg in args:
        raw = arg.encode()
        parts.append(b"$" + str(len(raw)).encode() + b"\r\n" + raw + b"\r\n")
    return b"".join(parts)


def _command(*args: str) -> str:
    """Send one command, read one reply. A fresh connection each time.

    Connection pooling is what a real client library is for. Opening a socket
    per request keeps this file readable and costs a millisecond on a mesh
    that never leaves the datacentre.
    """
    host, port = _address()
    try:
        with socket.create_connection((host, port), timeout=_TIMEOUT_SECONDS) as conn:
            conn.sendall(_encode(*args))
            reply = conn.makefile("rb").readline()
    except OSError as exc:
        msg = f"cache at {host}:{port} is unreachable: {exc}"
        raise RedisError(msg) from exc

    if not reply:
        msg = "cache closed the connection without replying"
        raise RedisError(msg)
    prefix, body = reply[:1], reply[1:].rstrip(b"\r\n").decode()
    if prefix == b"-":
        raise RedisError(body)
    return body


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler's required name
        if self.path == "/healthz":
            self._healthz()
        elif self.path == "/":
            self._visit()
        else:
            self._respond(404, {"error": "not found"})

    def _healthz(self) -> None:
        """Readiness reflects the dependency, not just the process.

        This instance cannot serve a single request without the cache, so it
        should not be in rotation before the cache answers. Reporting 200 while
        every request 503s is the failure mode this probe exists to prevent.
        """
        try:
            _command("PING")
        except RedisError as exc:
            self._respond(503, {"status": "cache unreachable", "detail": str(exc)})
            return
        self._respond(200, {"status": "ok"})

    def _visit(self) -> None:
        try:
            count = int(_command("INCR", COUNTER_KEY))
        except (RedisError, ValueError) as exc:
            self._respond(503, {"error": str(exc)})
            return
        self._respond(200, {"visits": count, "servedBy": socket.gethostname()})

    def _respond(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)  # noqa: S104 -- containers bind all interfaces

    def shutdown(_signum: int, _frame: FrameType | None) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    sys.stdout.write(f"listening on :{PORT}, cache at {REDIS_URL or '<unwired>'}\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
