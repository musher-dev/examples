"""The smallest useful Musher workload: one HTTP service.

Two routes, no dependencies beyond the standard library:

* ``/``        — what a visitor sees.
* ``/healthz`` — what the platform's readiness probe polls.

The readiness route is the part worth copying. Musher will not send traffic to
an instance until this returns 200, and a service with a public endpoint is
required to declare one. Keep it cheap and keep it honest: it should answer
"can I serve a request right now", not "am I alive".
"""

from __future__ import annotations

import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import FrameType

PORT = int(os.environ.get("PORT", "8080"))
GREETING = os.environ.get("GREETING", "Hello from Musher")


class Handler(BaseHTTPRequestHandler):
    """Route two paths; 404 everything else."""

    def do_GET(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler's required name
        if self.path == "/healthz":
            self._respond(200, {"status": "ok"})
            return
        if self.path == "/":
            self._respond(200, {"message": GREETING})
            return
        self._respond(404, {"error": "not found"})

    def _respond(self, status: int, payload: dict[str, str]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        # One line per request on stdout, which is where Musher collects logs.
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)  # noqa: S104 -- containers bind all interfaces

    def shutdown(_signum: int, _frame: FrameType | None) -> None:
        # Musher sends SIGTERM before replacing an instance. Draining here is
        # what makes a redeploy invisible to whoever is mid-request.
        server.shutdown()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    sys.stdout.write(f"listening on :{PORT}\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
