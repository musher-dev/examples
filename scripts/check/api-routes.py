#!/usr/bin/env python3
"""Check every Musher API call this repository documents against the pinned OpenAPI.

The examples drifted once already: the apply script and the READMEs kept
calling routes the API had renamed, and nothing noticed until someone followed
them. This finds every call and asserts that its method and path exist in the
pinned description, pins/openapi/public.json.

What counts as a call:

* in a shell script, `api METHOD "/path"` and `request METHOD "/path"`, the two
  helpers scripts/musher-apply.sh sends everything through;
* anywhere (scripts and Markdown), a `curl` command whose URL starts with
  https://api.musher.dev, $API_URL or $MUSHER_API_URL. Its method is the
  -X/--request value, else POST when it sends data, else GET.

A path segment written as a variable ($ID, ${ID}, $(cmd)) or a <placeholder>
matches any path parameter. The query string is ignored.

    usage: scripts/check/api-routes.py [--openapi FILE] [FILE...]

With no FILE it checks scripts/*.sh and every README.md. Exit status 1 when any
call is unknown, or when scripts/musher-apply.sh yields no calls at all (the
extractor silently matching nothing would make this check pass vacuously).
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
METHODS = ("get", "put", "post", "delete", "patch", "head", "options")

HELPER_CALL = re.compile(r"\b(?:api|request)\s+(GET|POST|PUT|PATCH|DELETE)\s+\"(/[^\"]*)\"")
CURL_URL = re.compile(
    r"(?:https://api\.musher\.dev|\$\{?(?:MUSHER_)?API_URL\}?)(/v\d+[^\s\"'`)]*)"
)
CURL_METHOD = re.compile(r"(?:-X|--request)\s+\"?([A-Z]+)")
CURL_DATA = re.compile(r"\s(?:-d|--data(?:-binary|-raw)?|--json)[\s=]")
VARIABLE = re.compile(r"\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*|<[^>]*>")
TEMPLATE = re.compile(r"\{[^}/]+\}")


def normalize(path: str) -> str:
    path = path.replace("\\", "")
    path = VARIABLE.sub("{}", path)
    path = path.split("?", 1)[0].rstrip("\"'")
    return TEMPLATE.sub("{}", path)


def load_routes(openapi: Path) -> dict[str, set[str]]:
    spec = json.loads(openapi.read_text(encoding="utf-8"))
    routes: dict[str, set[str]] = {}
    for path, item in spec.get("paths", {}).items():
        methods = {m.upper() for m in item if m in METHODS}
        routes.setdefault(normalize(path), set()).update(methods)
    return routes


def logical_lines(text: str) -> list[tuple[int, str]]:
    """Join backslash-continued lines, keeping the number of the first."""
    out: list[tuple[int, str]] = []
    buf, start = "", 0
    for number, line in enumerate(text.splitlines(), 1):
        if not buf:
            start = number
        if line.rstrip().endswith("\\"):
            buf += line.rstrip()[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def calls(path: Path) -> list[tuple[int, str, str]]:
    found = []
    for number, line in logical_lines(path.read_text(encoding="utf-8")):
        if path.suffix == ".sh":
            for method, route in HELPER_CALL.findall(line):
                found.append((number, method, route))
        if "curl" in line:
            method_match = CURL_METHOD.search(line)
            method = method_match[1] if method_match else ("POST" if CURL_DATA.search(line) else "GET")
            for route in CURL_URL.findall(line):
                found.append((number, method, route))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--openapi", type=Path, default=ROOT / "pins/openapi/public.json")
    parser.add_argument("files", nargs="*", type=Path)
    args = parser.parse_args()

    files = args.files or sorted(
        [*ROOT.glob("scripts/*.sh"), *ROOT.glob("README.md"), *ROOT.glob("*/README.md")]
    )
    routes = load_routes(args.openapi)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"

    failures = checked = 0
    for file in files:
        shown = file.resolve().relative_to(ROOT) if file.resolve().is_relative_to(ROOT) else file
        found = calls(file)
        if not found and file.name == "musher-apply.sh":
            print(f"FAIL {shown}: found no API calls; has the extractor stopped matching?")
            failures += 1
        for number, method, route in found:
            checked += 1
            key = normalize(route)
            if key in routes and method in routes[key]:
                print(f"ok   {method:6} {route}  ({shown}:{number})")
                continue
            failures += 1
            reason = (
                f"{route} exists, but not with {method} (it takes {', '.join(sorted(routes[key]))})"
                if key in routes
                else f"{method} {route} is not in {args.openapi.name}"
            )
            print(f"FAIL {method:6} {route}  ({shown}:{number}): {reason}")
            if annotate:
                print(f"::error file={shown},line={number}::{reason}")

    print(f"\n{checked} calls checked against {args.openapi}, {failures} failing")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
