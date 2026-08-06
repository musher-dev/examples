"""Just enough Redis to make the point, in the standard library.

A real service uses a client library with connection pooling, pipelining, and
retries. This file exists so the example has no dependency to pin, scan, or
upgrade — and so the wire protocol is visible rather than hidden behind an
import.

RESP is small: a command is an array of bulk strings, and a reply is one of
five things distinguished by its first byte.
"""

from __future__ import annotations

import os
import socket
from urllib.parse import urlparse

TIMEOUT_SECONDS = 5.0


class RedisError(RuntimeError):
    """The cache could not be reached, or answered something unexpected."""


def address() -> tuple[str, int]:
    """Split ``REDIS_URL`` into the pieces ``socket.create_connection`` wants."""
    url = os.environ.get("REDIS_URL", "")
    if not url:
        msg = "REDIS_URL is empty — the queue connection was not wired"
        raise RedisError(msg)
    parsed = urlparse(url)
    if parsed.scheme != "redis" or not parsed.hostname:
        msg = f"REDIS_URL={url!r} is not a redis:// URL"
        raise RedisError(msg)
    return (parsed.hostname, parsed.port or 6379)


def _encode(*args: str) -> bytes:
    parts = [f"*{len(args)}\r\n".encode()]
    for arg in args:
        raw = arg.encode()
        parts.append(b"$" + str(len(raw)).encode() + b"\r\n" + raw + b"\r\n")
    return b"".join(parts)


def command(*args: str, timeout: float = TIMEOUT_SECONDS) -> str | None:
    """Send one command and return its reply. ``None`` is Redis's nil."""
    host, port = address()
    try:
        with socket.create_connection((host, port), timeout=timeout) as conn:
            conn.sendall(_encode(*args))
            stream = conn.makefile("rb")
            line = stream.readline()
            if not line:
                msg = "cache closed the connection without replying"
                raise RedisError(msg)
            prefix, body = line[:1], line[1:].rstrip(b"\r\n")
            if prefix == b"-":
                raise RedisError(body.decode())
            if prefix in (b"+", b":"):
                return body.decode()
            if prefix == b"$":
                length = int(body)
                if length < 0:
                    return None
                payload = stream.read(length + 2)  # +2 for the trailing CRLF
                return payload[:length].decode()
            msg = f"unhandled RESP reply type {prefix!r}"
            raise RedisError(msg)
    except OSError as exc:
        msg = f"cache at {host}:{port} is unreachable: {exc}"
        raise RedisError(msg) from exc
