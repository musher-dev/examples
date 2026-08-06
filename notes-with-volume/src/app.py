"""A service whose data outlives its container.

Notes are appended to a JSON Lines file under ``DATA_DIR``. That directory is a
Musher Volume, so the file survives a restart, a redeploy, and the instance
being rescheduled onto a different machine.

Write anything to the container filesystem *outside* that directory and it is
gone the moment the container is replaced. That is the whole lesson.
"""

from __future__ import annotations

import json
import os
import signal
import sys
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from types import FrameType

PORT = int(os.environ.get("PORT", "8080"))
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
NOTES_FILE = DATA_DIR / "notes.jsonl"
MAX_BODY_BYTES = 4096

# ThreadingHTTPServer means concurrent requests; appends need serialising.
_write_lock = Lock()


def read_notes() -> list[dict[str, str]]:
    if not NOTES_FILE.exists():
        return []
    with NOTES_FILE.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def append_note(text: str) -> dict[str, str]:
    note = {"text": text, "createdAt": datetime.now(UTC).isoformat()}
    with _write_lock, NOTES_FILE.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(note) + "\n")
        # Without this the note is in the OS page cache, not on the volume, and
        # an abrupt restart loses it. Durability you did not ask for is not
        # durability you have.
        handle.flush()
        os.fsync(handle.fileno())
    return note


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler's required name
        if self.path == "/healthz":
            # Readiness is "can I serve", so it checks the volume is writable —
            # a mount that vanished should take the instance out of rotation.
            writable = os.access(DATA_DIR, os.W_OK)
            self._respond(200 if writable else 503, {"status": "ok" if writable else "data dir not writable"})
        elif self.path == "/notes":
            notes = read_notes()
            self._respond(200, {"count": len(notes), "notes": notes})
        elif self.path == "/":
            self._respond(200, {"notes": len(read_notes()), "storedAt": str(NOTES_FILE)})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 -- BaseHTTPRequestHandler's required name
        if self.path != "/notes":
            self._respond(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length > MAX_BODY_BYTES:
            self._respond(413, {"error": "body too large"})
            return

        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            text = str(payload["text"])[:500]
        except (ValueError, KeyError, TypeError):
            self._respond(400, {"error": 'expected {"text": "..."}'})
            return

        self._respond(201, append_note(text))

    def _respond(self, status: int, payload: object) -> None:
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
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)  # noqa: S104 -- containers bind all interfaces

    def shutdown(_signum: int, _frame: FrameType | None) -> None:
        server.shutdown()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    sys.stdout.write(f"listening on :{PORT} data_dir={DATA_DIR} existing_notes={len(read_notes())}\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
