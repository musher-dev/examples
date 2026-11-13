#!/usr/bin/env python3
"""Run scripts/musher-apply.sh against a fake Musher API that enforces the pinned OpenAPI.

api-routes.py proves each path exists. This proves the script sends what
those operations accept: the fake answers only operations in
pins/openapi/public.json, and refuses any request whose query parameters or
JSON body do not validate against that operation's schema. A renamed field
(`userAssignedName` for `name`) or a reshaped body (`{metadata, spec}` for
`{document, slug}`) fails here, and so does an example document the API's
own document schema would refuse.

For every example it runs the script three times, the way a person would:

1. first apply: everything is created, published and deployed;
2. the same apply again: nothing changes, nothing is published or deployed;
3. a new image tag: changed Components get a new revision, the Blueprint
   too, and the existing deployment is moved to it rather than re-created.

The fake is stateful only as far as those runs need. It does not prove the
real API accepts the documents (semantic and admission rules run on the
server), and it does not check the responses the script reads; a live run
does both.

    usage: scripts/check/contract-test.py [--openapi FILE] [EXAMPLE...]

Needs `jsonschema` (pip install jsonschema), curl, jq and mikefarah/yq.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import jsonschema
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

ROOT = Path(__file__).resolve().parents[2]
ORG = "3f6c1a2e-0b7d-4c1e-9a55-6f0e2d4b8c11"
KEY = "mush_contract_test"
METHODS = ("get", "put", "post", "delete", "patch")


class Contract:
    """The operations of the pinned OpenAPI, and a validator for each request."""

    def __init__(self, openapi: Path) -> None:
        self.spec = json.loads(openapi.read_text(encoding="utf-8"))
        resource = Resource.from_contents(self.spec, default_specification=DRAFT202012)
        self.registry = Registry().with_resource("urn:openapi", resource)
        self.ops: list[tuple[re.Pattern[str], str, str, dict]] = []
        for template, item in self.spec["paths"].items():
            pattern = re.compile(
                "^" + re.sub(r"\\\{[^}]+\\\}", r"[^/:?]+", re.escape(template)) + "$"
            )
            for method in METHODS:
                if method in item:
                    self.ops.append((pattern, method.upper(), template, item[method]))

    def match(self, method: str, path: str) -> tuple[str, dict] | None:
        for pattern, op_method, template, op in self.ops:
            if op_method == method and pattern.match(path):
                return template, op
        return None

    def check(self, method: str, path: str, query: dict, body: object) -> tuple[str | None, list[str]]:
        found = self.match(method, path)
        if not found:
            return None, [f"{method} {path} is not an operation in the pinned OpenAPI"]
        template, op = found
        problems = []
        declared = {p["name"]: p for p in op.get("parameters", []) if p.get("in") == "query"}
        for name in query:
            if name not in declared:
                problems.append(f"{method} {template}: unknown query parameter '{name}'")
        for name, param in declared.items():
            if param.get("required") and name not in query:
                problems.append(f"{method} {template}: missing required query parameter '{name}'")
        schema = op.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
        if schema is None and body is not None:
            problems.append(f"{method} {template}: sends a body the operation does not take")
        if schema is not None and body is None and op["requestBody"].get("required"):
            problems.append(f"{method} {template}: the operation requires a body")
        if schema is not None and body is not None:
            validator = jsonschema.Draft202012Validator(
                {"$ref": "urn:openapi#" + schema["$ref"][1:]} if "$ref" in schema else schema,
                registry=self.registry,
            )
            for error in sorted(validator.iter_errors(body), key=lambda e: list(e.absolute_path)):
                where = "/" + "/".join(str(p) for p in error.absolute_path)
                problems.append(f"{method} {template}: body {where}: {error.message[:300]}")
        return template, problems


class FakeMusher:
    """Just enough state to answer the apply script's requests."""

    def __init__(self) -> None:
        self.kinds: dict[str, dict[str, dict]] = {"components": {}, "blueprints": {}}
        self.deployments: dict[str, dict] = {}
        self.calls: list[str] = []

    def lineage(self, kind: str, lineage_id: str) -> dict | None:
        return self.kinds[kind].get(lineage_id)

    def summary(self, entry: dict) -> dict:
        versions = entry["versions"].values()
        published = [v for v in versions if v["status"] == "PUBLISHED"]
        drafts = [v for v in versions if v["status"] == "DRAFT"]
        latest = max(published, key=lambda v: v["revision"]) if published else None
        return {
            "id": entry["id"],
            "slug": entry["slug"],
            "latestPublishedVersion": {"revision": latest["revision"]} if latest else None,
            "draftVersion": {"revision": drafts[0]["revision"]} if drafts else None,
        }

    def version(self, kind: str, entry: dict, v: dict) -> dict:
        id_key = "componentId" if kind == "components" else "blueprintId"
        return {id_key: entry["id"], "revision": v["revision"], "status": v["status"], "document": v["document"]}

    def published(self, kind: str, ref: str, revision: int) -> bool:
        entry = self.kinds[kind].get(ref)
        return bool(entry) and entry["versions"].get(revision, {}).get("status") == "PUBLISHED"

    def handle(self, method: str, template: str, path: str, query: dict, body: dict | None) -> tuple[int, object]:
        self.calls.append(f"{method} {template}")
        parts = re.findall(r"[^/:]+", path)
        for kind in ("components", "blueprints"):
            base = f"/v1/organizations/{{organization_id}}/{kind}"
            if template == base and method == "GET":
                found = [self.summary(e) for e in self.kinds[kind].values() if e["slug"] == query.get("slug")]
                return 200, {"data": found, "meta": {"hasMore": False, "nextCursor": None}}
            if template == base and method == "POST":
                if any(e["slug"] == body.get("slug") for e in self.kinds[kind].values()):
                    return 409, {"title": "Resource conflict", "detail": "slug taken"}
                if kind == "blueprints" and (problem := self.unresolved(body["document"])):
                    return 422, {"title": "Spec document invalid", "detail": problem}
                entry = {"id": str(uuid.uuid4()), "slug": body["slug"], "versions": {}}
                revision = body["document"]["metadata"]["revision"]
                entry["versions"][revision] = {"revision": revision, "status": "DRAFT", "document": body["document"]}
                self.kinds[kind][entry["id"]] = entry
                return 201, self.version(kind, entry, entry["versions"][revision])
            prefix = f"/v1/{kind}/{{{kind[:-1]}_id}}/versions"
            if not template.startswith(prefix):
                continue
            entry = self.lineage(kind, parts[2])
            if entry is None:
                return 404, {"title": "Resource not found"}
            if template == prefix and method == "GET":
                rows = [{"revision": v["revision"], "status": v["status"]} for v in entry["versions"].values()]
                return 200, {"data": rows, "meta": {"hasMore": False, "nextCursor": None}}
            if template == prefix and method == "POST":
                revision = body["document"]["metadata"]["revision"]
                if any(v["status"] == "DRAFT" for v in entry["versions"].values()):
                    return 409, {"title": "Resource conflict", "detail": "a draft is open"}
                if revision <= max(entry["versions"]):
                    return 422, {"title": "Spec document invalid", "detail": "ERR_REVISION_NOT_INCREASING"}
                if kind == "blueprints" and (problem := self.unresolved(body["document"])):
                    return 422, {"title": "Spec document invalid", "detail": problem}
                entry["versions"][revision] = {"revision": revision, "status": "DRAFT", "document": body["document"]}
                return 201, self.version(kind, entry, entry["versions"][revision])
            version = entry["versions"].get(int(parts[4]))
            if version is None:
                return 404, {"title": "Resource not found"}
            if template == prefix + "/{revision}" and method == "PUT":
                if version["status"] != "DRAFT":
                    return 409, {"title": "Resource conflict", "detail": "immutable-state"}
                if body["document"]["metadata"]["revision"] != version["revision"]:
                    return 422, {"title": "Spec document invalid", "detail": "revision mismatch"}
                version["document"] = body["document"]
                return 200, self.version(kind, entry, version)
            if template == prefix + "/{revision}/document":
                return 200, version["document"]
            if template == prefix + "/{revision}:publish":
                if version["status"] != "DRAFT":
                    return 409, {"title": "Resource conflict", "detail": "not a draft"}
                version["status"] = "PUBLISHED"
                return 200, self.version(kind, entry, version)
        if template == "/v1/organizations/{organization_id}/deployments:byName":
            found = self.deployments.get(query["name"])
            return (200, found) if found else (404, {"title": "Resource not found"})
        if template == "/v1/organizations/{organization_id}/deployments:deployBlueprint":
            if body["name"] in self.deployments:
                return 409, {"title": "Resource conflict", "detail": "name taken"}
            if not self.published("blueprints", body["blueprintId"], body["revision"]):
                return 404, {"title": "version-not-found"}
            deployment = {
                "metadata": {"id": str(uuid.uuid4()), "name": body["name"]},
                "spec": {"blueprintId": body["blueprintId"], "blueprintVersion": body["revision"]},
                "status": {"phase": "PROVISIONING"},
            }
            self.deployments[body["name"]] = deployment
            return 201, deployment
        if template == "/v1/deployments/{deployment_id}:update":
            for deployment in self.deployments.values():
                if deployment["metadata"]["id"] == parts[2]:
                    blueprint = deployment["spec"]["blueprintId"]
                    if not self.published("blueprints", blueprint, body["revision"]):
                        return 404, {"title": "version-not-found"}
                    deployment["spec"]["blueprintVersion"] = body["revision"]
                    return 200, deployment
            return 404, {"title": "Resource not found"}
        return 501, {"title": f"the fake does not implement {method} {template}"}

    def unresolved(self, document: dict) -> str | None:
        """A Blueprint written through the API names published components by id and revision."""
        for name, node in document.get("spec", {}).get("nodes", {}).items():
            if not self.published("components", node.get("componentRef", ""), node.get("revision")):
                return f"node {name} does not name a published component revision"
        return None


def serve(contract: Contract, fake: FakeMusher, violations: list[str]) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args: object) -> None:
            pass

        def reply(self, status: int, body: object) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def dispatch(self) -> None:
            url = urlparse(self.path)
            query = {k: v[-1] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            if self.headers.get("Authorization") != f"Bearer {KEY}":
                violations.append(f"{self.command} {url.path}: no or wrong Authorization header")
                return self.reply(401, {"title": "Not authenticated"})
            try:
                body = json.loads(raw) if raw else None
            except json.JSONDecodeError as error:
                violations.append(f"{self.command} {url.path}: body is not JSON: {error}")
                return self.reply(400, {"title": "Bad request"})
            if body is not None and self.headers.get("Content-Type") != "application/json":
                violations.append(f"{self.command} {url.path}: JSON body without Content-Type: application/json")
            template, problems = contract.check(self.command, url.path, query, body)
            if problems:
                violations.extend(problems)
                return self.reply(422, {"title": "Contract violation", "detail": problems[0]})
            if not url.path.startswith(f"/v1/organizations/{ORG}") and "/organizations/" in url.path:
                violations.append(f"{self.command} {url.path}: wrong organization id")
            status, reply = fake.handle(self.command, template, url.path, query, body)
            if status == 501:
                violations.append(reply["title"])
            self.reply(status, reply)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = dispatch

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def apply(port: int, example: str, image: str) -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "MUSHER_API_URL": f"http://127.0.0.1:{port}",
        "MUSHER_API_KEY": KEY,
        "MUSHER_ORG_ID": ORG,
        "DRY_RUN": "",
    }
    return subprocess.run(
        ["sh", str(ROOT / "scripts/musher-apply.sh"), str(ROOT / example), image, f"ct-{example}"],
        env=env, capture_output=True, text=True, timeout=120, check=False,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--openapi", type=Path, default=ROOT / "pins/openapi/public.json")
    parser.add_argument("examples", nargs="*")
    args = parser.parse_args()
    examples = args.examples or sorted(p.parent.parent.name for p in ROOT.glob("*/musher/blueprint.yaml"))
    contract = Contract(args.openapi)

    failed = False
    for example in examples:
        fake, violations = FakeMusher(), []
        server = serve(contract, fake, violations)
        port = server.server_address[1]
        steps = [
            ("first apply", f"ghcr.io/example/{example}:0.1.0",
             lambda c: "POST /v1/organizations/{organization_id}/deployments:deployBlueprint" in c),
            ("unchanged re-apply", f"ghcr.io/example/{example}:0.1.0",
             lambda c: not any(":publish" in x or "deployBlueprint" in x or ":update" in x for x in c)),
            ("new image", f"ghcr.io/example/{example}:0.2.0",
             lambda c: "POST /v1/deployments/{deployment_id}:update" in c),
        ]
        for name, image, expect in steps:
            fake.calls.clear()
            result = apply(port, example, image)
            problems = list(violations)
            violations.clear()
            if result.returncode != 0:
                problems.append(f"exit status {result.returncode}")
            elif not expect(fake.calls):
                problems.append("did not make the calls this step should: " + ", ".join(fake.calls))
            if problems:
                failed = True
                print(f"FAIL {example}: {name}")
                for problem in problems:
                    print(f"     {problem}")
                print("     --- script output ---")
                print("\n".join("     " + line for line in (result.stderr + result.stdout).splitlines()))
            else:
                print(f"ok   {example}: {name} ({len(fake.calls)} requests)")
        server.shutdown()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
