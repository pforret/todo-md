#!/usr/bin/env python3
"""todo-web.py — local web dashboard for every project registered with todo.sh.

Reads ~/.claude/state/todo-projects.tsv (or $TODO_REGISTRY), scans each
project's docs/todo tree and serves a single-page dashboard plus a JSON API.

    todo-web.py                 serve on http://127.0.0.1:7474 (and open the browser)
    todo-web.py --port 8080     another port
    todo-web.py --no-open       don't open the browser
    todo-web.py --json          print the scan as JSON and exit

Stdlib only. Nothing is written; the item files are read on every request so the
page always reflects the current state on disk.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
PAGE = HERE / "todo-dashboard.html"
REGISTRY = Path(os.environ.get("TODO_REGISTRY") or Path.home() / ".claude" / "state" / "todo-projects.tsv")
STATUSES = ("open", "plan", "busy", "done", "skipped")
STATUS_RANK = {s: i for i, s in enumerate(("busy", "plan", "open", "done", "skipped"))}
URGENCY_RANK = {"essential": 0, "useful": 1, "nice-to-have": 2}
FILE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})\.([a-z]+)\.(.+)\.md$")
MONTH_RE = re.compile(r"^\d{4}-\d{2}$")


def parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """The key: value block between the first two --- lines, and the body after it."""
    fm: dict[str, str] = {}
    lines = text.splitlines()
    if not lines or not re.fullmatch(r"---\s*", lines[0]):
        return fm, text
    for i, line in enumerate(lines[1:], start=1):
        if re.fullmatch(r"---\s*", line):
            return fm, "\n".join(lines[i + 1:])
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip().strip("\"'")
    return fm, ""


def section(body: str, heading: str) -> str:
    """The text under '## <heading>' up to the next '## ' heading."""
    m = re.search(rf"^## {re.escape(heading)}\s*$(.*?)(?=^## |\Z)", body, re.M | re.S)
    return m.group(1).strip() if m else ""


def plain(md: str) -> str:
    """Markdown to a one-line plain excerpt."""
    md = re.sub(r"```.*?```", " ", md, flags=re.S)
    md = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", md)
    md = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", md)
    md = re.sub(r"^\s*(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s?)", "", md, flags=re.M)
    md = re.sub(r"[*_`~]+", "", md)
    return re.sub(r"\s+", " ", md).strip()


def date_for(fm: dict[str, str], status: str) -> str:
    key = {"plan": "plan_started", "busy": "started", "done": "finished"}.get(status, "created")
    return fm.get(key) or fm.get("created", "")


def read_item(project: dict, path: Path, status: str) -> dict:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    fm, body = parse_frontmatter(text)
    m = FILE_RE.match(path.name)
    status = fm.get("status") if fm.get("status") in STATUSES else status
    description = plain(section(body, "Description"))[:280]
    return {
        "project": project["name"],
        "projectPath": project["path"],
        "file": str(path),
        "relative": str(path.relative_to(project["path"])),
        "title": fm.get("title") or (m.group(3).replace("-", " ") if m else path.stem),
        "type": fm.get("type") or (m.group(2) if m else ""),
        "urgency": fm.get("urgency", ""),
        "complexity": fm.get("complexity", ""),
        "term": "long" if fm.get("term") == "long" else "short",
        "category": fm.get("category", ""),
        "milestone": fm.get("milestone", ""),
        "status": status,
        "created": fm.get("created") or (m.group(1) if m else ""),
        "started": fm.get("started", ""),
        "finished": fm.get("finished", ""),
        "date": date_for(fm, status),
        "skipReason": fm.get("skip_reason", ""),
        "description": description,
    }


def item_files(folder: Path):
    if not folder.is_dir():
        return
    for p in sorted(folder.iterdir()):
        if p.is_file() and p.suffix == ".md" and p.name != "index.md" and not p.name.startswith("DONE-"):
            yield p


def scan_project(project: dict) -> list[dict]:
    todo = Path(project["path"]) / "docs" / "todo"
    if not todo.is_dir():
        return []
    items = [read_item(project, p, "open") for p in item_files(todo)]
    for status in ("plan", "busy", "skipped"):
        items += [read_item(project, p, status) for p in item_files(todo / status)]
    done = todo / "done"
    if done.is_dir():
        for month in sorted(d for d in done.iterdir() if d.is_dir() and MONTH_RE.match(d.name)):
            items += [read_item(project, p, "done") for p in item_files(month)]
    return items


def read_registry() -> list[dict]:
    if not REGISTRY.is_file():
        return []
    projects = []
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        path = parts[0]
        name = parts[1] if len(parts) > 1 and parts[1] else Path(path).name
        projects.append({"name": name, "path": path, "seen": parts[2] if len(parts) > 2 else ""})
    return projects


def scan() -> dict:
    projects = read_registry()
    items: list[dict] = []
    for project in projects:
        project_items = scan_project(project)
        project["counts"] = {s: sum(1 for i in project_items if i["status"] == s) for s in STATUSES}
        project["hasTodo"] = (Path(project["path"]) / "docs" / "todo").is_dir()
        items += project_items
    # newest first, then a stable sort groups by status and urgency
    items.sort(key=lambda i: (i["date"] or "", i["project"], i["title"]), reverse=True)
    items.sort(key=lambda i: (STATUS_RANK.get(i["status"], 9), i["term"] == "long", URGENCY_RANK.get(i["urgency"], 9)))
    return {
        "scannedAt": int(time.time() * 1000),
        "registry": str(REGISTRY),
        "projects": projects,
        "items": items,
        "counts": {s: sum(1 for i in items if i["status"] == s) for s in STATUSES},
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "todo-web/1.0"

    def log_message(self, fmt, *args):  # quiet unless --verbose
        if self.server.verbose:  # type: ignore[attr-defined]
            super().log_message(fmt, *args)

    def send(self, status: HTTPStatus, body: bytes, content_type: str):
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the browser went away mid-response; nothing to do

    def send_json(self, data, status=HTTPStatus.OK):
        self.send(status, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html", "/history", "/history/"):
            if not PAGE.is_file():
                return self.send(HTTPStatus.INTERNAL_SERVER_ERROR, f"missing {PAGE}".encode(), "text/plain")
            return self.send(HTTPStatus.OK, PAGE.read_bytes(), "text/html; charset=utf-8")
        if url.path == "/api/todos":
            return self.send_json(scan())
        if url.path == "/api/item":
            file = parse_qs(url.query).get("file", [""])[0]
            data = scan()
            known = {i["file"]: i for i in data["items"]}
            if file not in known:
                return self.send_json({"error": "unknown item"}, HTTPStatus.NOT_FOUND)
            text = Path(file).read_text(encoding="utf-8", errors="replace")
            _, body = parse_frontmatter(text)
            return self.send_json({**known[file], "body": body})
        return self.send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=int(os.environ.get("TODO_WEB_PORT", "7474")))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--no-open", action="store_true", help="don't open the browser")
    ap.add_argument("--json", action="store_true", help="print the scan as JSON and exit")
    ap.add_argument("--verbose", action="store_true", help="log every request")
    args = ap.parse_args()

    if args.json:
        json.dump(scan(), sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.verbose = args.verbose  # type: ignore[attr-defined]
    url = f"http://{args.host}:{args.port}/"
    data = scan()
    print(f"todo-web: {len(data['items'])} items in {len(data['projects'])} projects from {REGISTRY}", flush=True)
    print(f"todo-web: serving {url}  (Ctrl-C to stop)", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\ntodo-web: stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
