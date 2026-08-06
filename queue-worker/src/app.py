"""One image, two workloads: an API that enqueues and a worker that consumes.

``ROLE`` selects which one this container runs. Both Components in
``musher/`` point at the same image and differ only in that environment
variable and in their runtime shape — SERVICE with a public endpoint, and
WORKER with no endpoint at all.

Sharing an image is a choice, not a requirement. It keeps this example to one
`docker build`, and it is a shape you will meet in real repositories. Two
images with two Dockerfiles works identically as far as Musher is concerned.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import FrameType

from redis_min import RedisError, command

ROLE = os.environ.get("ROLE", "api")
PORT = int(os.environ.get("PORT", "8080"))
QUEUE_KEY = os.environ.get("QUEUE_KEY", "jobs")
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "0.5"))

_shutdown = threading.Event()


def _install_signal_handlers(on_term: object = None) -> None:
    """Musher sends SIGTERM before replacing an instance. Exit on purpose."""

    def handle(_signum: int, _frame: FrameType | None) -> None:
        _shutdown.set()
        if callable(on_term):
            threading.Thread(target=on_term, daemon=True).start()

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)


def _log(message: str) -> None:
    sys.stdout.write(f"[{ROLE}] {message}\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# ROLE=api — a SERVICE with a public endpoint
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler's required name
        if self.path == "/healthz":
            self._healthz()
        elif self.path.startswith("/jobs/"):
            self._result(self.path.removeprefix("/jobs/"))
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler's required name
        if self.path == "/jobs":
            self._enqueue()
        else:
            self._respond(404, {"error": "not found"})

    def _healthz(self) -> None:
        try:
            command("PING", timeout=2.0)
        except RedisError as exc:
            self._respond(503, {"status": "queue unreachable", "detail": str(exc)})
            return
        self._respond(200, {"status": "ok"})

    def _enqueue(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode() if length else "{}"
        try:
            text = str(json.loads(raw).get("text", ""))
        except json.JSONDecodeError:
            self._respond(400, {"error": "body must be JSON"})
            return

        job_id = str(uuid.uuid4())
        try:
            command("LPUSH", QUEUE_KEY, json.dumps({"id": job_id, "text": text}))
        except RedisError as exc:
            self._respond(503, {"error": str(exc)})
            return
        # 202: accepted, not done. The worker has not touched it yet, and
        # pretending otherwise is how async APIs start lying to their callers.
        self._respond(202, {"id": job_id, "status": "queued"})

    def _result(self, job_id: str) -> None:
        try:
            result = command("GET", f"result:{job_id}")
        except RedisError as exc:
            self._respond(503, {"error": str(exc)})
            return
        if result is None:
            self._respond(200, {"id": job_id, "status": "pending"})
            return
        self._respond(200, {"id": job_id, "status": "done", "result": result})

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


def run_api() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)  # noqa: S104 -- containers bind all interfaces
    _install_signal_handlers(server.shutdown)
    _log(f"listening on :{PORT}")
    server.serve_forever()


# ---------------------------------------------------------------------------
# ROLE=worker — a WORKER: no endpoint, no URL, nothing to route to
# ---------------------------------------------------------------------------


def run_worker() -> None:
    _install_signal_handlers()
    _log("polling for jobs")
    while not _shutdown.is_set():
        try:
            job = command("RPOP", QUEUE_KEY)
        except RedisError as exc:
            # The queue being briefly unreachable is normal during a redeploy.
            # Log it, back off, keep going — a worker that exits on the first
            # blip is a worker you get paged about.
            _log(f"queue unavailable: {exc}")
            _shutdown.wait(POLL_SECONDS * 4)
            continue

        if job is None:
            # A real worker uses BRPOP or a stream so an idle queue costs
            # nothing. Polling keeps this file to one readable protocol path.
            _shutdown.wait(POLL_SECONDS)
            continue

        payload = json.loads(job)
        _log(f"processing {payload['id']}")
        time.sleep(0.2)  # stand-in for whatever the real work is
        try:
            command("SET", f"result:{payload['id']}", payload["text"].upper())
        except RedisError as exc:
            _log(f"could not store result: {exc}")

    _log("shutting down")


def main() -> None:
    if ROLE == "worker":
        run_worker()
    elif ROLE == "api":
        run_api()
    else:
        sys.stderr.write(f"unknown ROLE={ROLE!r}; expected 'api' or 'worker'\n")
        raise SystemExit(2)


if __name__ == "__main__":
    main()
