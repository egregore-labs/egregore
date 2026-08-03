#!/usr/bin/env python3
"""Local, one-shot browser surface for selecting Egregore intake files."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.parse
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from threading import Event, Lock


ROOT = Path(__file__).resolve().parent.parent
HTML_PATH = Path(__file__).with_name("ingest-surface.html")
DESIGN_CSS_PATH = ROOT / "packages" / "design-system" / "dist" / "egregore-design.css"
SELECTION_SCHEMA = "egregore-ingest-selection/v1"
STALE_AFTER_SECONDS = 24 * 60 * 60
MAX_JSON_BYTES = 64 * 1024
RECEIPT_GRACE_SECONDS = 20 * 60
VALID_THEME_PAIRS = {"meridian", "agronomic", "sovereign"}
VALID_THEME_MODES = {"light", "auto", "dark"}


def ingest_root() -> Path:
    override = os.environ.get("EGREGORE_INGEST_ROOT")
    return Path(override).resolve() if override else (ROOT / ".egregore" / "ingest").resolve()


def staging_root() -> Path:
    override = os.environ.get("EGREGORE_INGEST_STAGING_ROOT")
    return Path(override).resolve() if override else (ROOT / ".egregore" / "ingest-staging").resolve()


def preferences_path() -> Path:
    override = os.environ.get("EGREGORE_INGEST_UI_PREFERENCES")
    return Path(override).resolve() if override else (ROOT / ".egregore" / "ingest-ui-preferences.json").resolve()


def load_preferences(path: Path) -> dict[str, str]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        value = {}
    pair = value.get("pair") if value.get("pair") in VALID_THEME_PAIRS else "sovereign"
    mode = value.get("mode") if value.get("mode") in VALID_THEME_MODES else "auto"
    return {"pair": pair, "mode": mode}


def save_preferences(path: Path, value: dict) -> dict[str, str]:
    pair = value.get("pair")
    mode = value.get("mode")
    if pair not in VALID_THEME_PAIRS or mode not in VALID_THEME_MODES:
        raise ValueError("invalid theme preference")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    result = {"pair": pair, "mode": mode}
    temporary.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)
    return result


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not result:
        raise ValueError("source id must contain at least one letter or number")
    return result


def safe_relative_path(raw: str) -> str:
    value = urllib.parse.unquote(raw).strip()
    if not value or "\x00" in value or "\\" in value:
        raise ValueError("invalid relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} or part.startswith(".") for part in path.parts):
        raise ValueError("path must be a visible relative path without traversal")
    if len(value) > 2048:
        raise ValueError("relative path is too long")
    return path.as_posix()


def clean_stale_sessions(base: Path, now: float | None = None) -> None:
    if not base.exists():
        return
    cutoff = (now if now is not None else time.time()) - STALE_AFTER_SECONDS
    for child in base.iterdir():
        try:
            if child.is_dir() and child.stat().st_mtime < cutoff:
                shutil.rmtree(child)
        except OSError:
            continue


class SelectionState:
    def __init__(self, staging_base: Path, session_id: str | None = None) -> None:
        self.session_id = session_id or secrets.token_hex(12)
        self.session_root = (staging_base / self.session_id).resolve()
        self.files_root = self.session_root / "files"
        self.files_root.mkdir(parents=True, exist_ok=False)
        self.items: dict[str, dict] = {}
        self.done = Event()
        self.cancelled = False
        self.result: dict | None = None
        self.receipt: dict = {"status": "selecting"}
        self.receipt_done = Event()
        self.receipt_ack = Event()
        self.receipt_url = ""
        self.receipt_token = ""
        self.lock = Lock()

    def upload(self, relative_path: str, mime: str, stream, size: int) -> dict:
        relative = safe_relative_path(relative_path)
        if size < 0:
            raise ValueError("invalid content length")
        free = shutil.disk_usage(self.session_root).free
        if size > max(0, free - 16 * 1024 * 1024):
            raise ValueError("not enough free disk space for this file")

        with self.lock:
            if self.done.is_set():
                raise ValueError("selection is already closed")
            if relative in self.items:
                existing = self.items[relative]
                hasher = hashlib.sha256()
                remaining = size
                while remaining:
                    block = stream.read(min(1024 * 1024, remaining))
                    if not block:
                        raise ValueError("upload ended before content length")
                    hasher.update(block)
                    remaining -= len(block)
                if size == existing["bytes"] and hasher.hexdigest() == existing["sha256"]:
                    return existing
                raise FileExistsError(f"duplicate relative path has different bytes: {relative}")
            destination = (self.files_root / relative).resolve()
            if self.files_root not in destination.parents:
                raise ValueError("staged path escaped the selection root")
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_name(destination.name + ".upload")
            hasher = hashlib.sha256()
            remaining = size
            try:
                with temporary.open("xb") as handle:
                    while remaining:
                        block = stream.read(min(1024 * 1024, remaining))
                        if not block:
                            raise ValueError("upload ended before content length")
                        handle.write(block)
                        hasher.update(block)
                        remaining -= len(block)
                temporary.replace(destination)
            except Exception:
                temporary.unlink(missing_ok=True)
                raise

            item = {
                "relative_path": relative,
                "local_path": str(destination),
                "mime": mime or mimetypes.guess_type(relative)[0] or "application/octet-stream",
                "bytes": size,
                "sha256": hasher.hexdigest(),
            }
            self.items[relative] = item
            return item

    def confirm(self, payload: dict) -> dict:
        with self.lock:
            if self.done.is_set():
                raise ValueError("selection is already closed")
            source = payload.get("source")
            if not isinstance(source, dict):
                raise ValueError("source contract is required")
            if "org" in payload or "org" in source:
                raise ValueError("org is derived from egregore.json and cannot be supplied")
            source_id = slug(str(source.get("id", "")))
            name = str(source.get("name", "")).strip() or source_id
            if len(name) > 200:
                raise ValueError("source name is too long")
            boundaries_raw = source.get("boundaries", {})
            if not isinstance(boundaries_raw, dict):
                raise ValueError("boundaries must be an object")
            boundaries: dict[str, str] = {}
            for raw_key, raw_value in boundaries_raw.items():
                key = slug(str(raw_key))
                value = str(raw_value).strip()
                if not value:
                    raise ValueError(f"boundary value is empty: {raw_key}")
                boundaries[key] = value
            if not self.items:
                raise ValueError("select at least one file")

            created_at = datetime.now(timezone.utc).isoformat()
            manifest = {
                "schema": SELECTION_SCHEMA,
                "session_id": self.session_id,
                "created_at": created_at,
                "source": {
                    "id": source_id,
                    "name": name,
                    "kind": "files",
                    "boundaries": dict(sorted(boundaries.items())),
                    "authoritative_snapshot": bool(source.get("authoritative_snapshot", False)),
                },
                "staging_root": str(self.session_root),
                "items": [self.items[key] for key in sorted(self.items)],
                "receipt": {"url": self.receipt_url, "token": self.receipt_token},
            }
            manifest_path = self.session_root / "selection.json"
            temporary = manifest_path.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            temporary.replace(manifest_path)
            self.result = {
                "schema": SELECTION_SCHEMA,
                "selection_path": str(manifest_path),
                "source_id": source_id,
                "files": len(self.items),
                "bytes": sum(item["bytes"] for item in self.items.values()),
                "receipt_url": self.receipt_url,
            }
            self.receipt = {**self.result, "status": "processing", "message": "The agent is validating and indexing this selection."}
            self.done.set()
            return self.result

    def finish_receipt(self, payload: dict) -> dict:
        with self.lock:
            if not self.done.is_set() or self.cancelled:
                raise ValueError("selection has not been confirmed")
            status = payload.get("status")
            if status not in {"complete", "attention", "failed"}:
                raise ValueError("invalid receipt status")
            self.receipt = payload
            self.receipt_done.set()
            return self.receipt

    def cancel(self) -> None:
        with self.lock:
            self.cancelled = True
            self.done.set()

    def cleanup(self) -> None:
        shutil.rmtree(self.session_root, ignore_errors=True)


def handler_class(state: SelectionState, token: str, expected_origin: str, preference_file: Path | None = None):
    html_template = HTML_PATH.read_text(encoding="utf-8")
    design_css = DESIGN_CSS_PATH.read_text(encoding="utf-8")
    capabilities = {"pdftotext": bool(shutil.which("pdftotext"))}
    preferences = load_preferences(preference_file or preferences_path())
    page = (
        html_template.replace("__EGREGORE_DESIGN_CSS__", design_css)
        .replace("__EGREGORE_TOKEN_JSON__", json.dumps(token))
        .replace("__EGREGORE_CAPABILITIES_JSON__", json.dumps(capabilities))
        .replace("__EGREGORE_PREFERENCES_JSON__", json.dumps(preferences))
        .encode("utf-8")
    )
    entry_path = f"/{token}/"

    class Handler(BaseHTTPRequestHandler):
        server_version = "EgregoreIngest/1"

        def log_message(self, _format: str, *_args) -> None:
            return

        def send_headers(self, status: int, content_type: str, length: int) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            )
            self.end_headers()

        def send_json(self, status: int, value: object) -> None:
            body = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_headers(status, "application/json; charset=utf-8", len(body))
            self.wfile.write(body)

        def do_GET(self) -> None:
            if urllib.parse.urlsplit(self.path).path != entry_path:
                self.send_json(404, {"error": "not found"})
                return
            self.send_headers(200, "text/html; charset=utf-8", len(page))
            self.wfile.write(page)

        def authorized(self) -> bool:
            return secrets.compare_digest(self.headers.get("X-Egregore-Token", ""), token) and self.headers.get("Origin") == expected_origin

        def token_authorized(self) -> bool:
            return secrets.compare_digest(self.headers.get("X-Egregore-Token", ""), token)

        def read_json(self) -> dict:
            try:
                length = int(self.headers.get("Content-Length", "-1"))
            except ValueError as exc:
                raise ValueError("invalid content length") from exc
            if length < 0 or length > MAX_JSON_BYTES:
                raise ValueError("invalid JSON body size")
            value = json.loads(self.rfile.read(length))
            if not isinstance(value, dict):
                raise ValueError("JSON body must be an object")
            return value

        def do_POST(self) -> None:
            path = urllib.parse.urlsplit(self.path).path
            if path == "/api/result":
                if not self.token_authorized():
                    self.send_json(403, {"error": "invalid receipt token"})
                    return
                try:
                    self.send_json(200, state.finish_receipt(self.read_json()))
                except (ValueError, OSError, json.JSONDecodeError) as exc:
                    self.send_json(400, {"error": str(exc)})
                return
            if not self.authorized():
                self.send_json(403, {"error": "invalid selection token or origin"})
                return
            try:
                if path == "/api/upload":
                    raw_length = self.headers.get("Content-Length")
                    if raw_length is None:
                        raise ValueError("content length is required")
                    item = state.upload(
                        self.headers.get("X-Egregore-Path", ""),
                        self.headers.get("Content-Type", ""),
                        self.rfile,
                        int(raw_length),
                    )
                    self.send_json(201, item)
                    return
                if path == "/api/confirm":
                    result = state.confirm(self.read_json())
                    self.send_json(200, result)
                    return
                if path == "/api/cancel":
                    state.cancel()
                    self.send_json(200, {"cancelled": True})
                    return
                if path == "/api/status":
                    self.send_json(200, state.receipt)
                    return
                if path == "/api/ack":
                    state.receipt_ack.set()
                    self.send_json(200, {"acknowledged": True})
                    return
                if path == "/api/preferences":
                    saved = save_preferences(preference_file or preferences_path(), self.read_json())
                    self.send_json(200, saved)
                    return
                self.send_json(404, {"error": "not found"})
            except FileExistsError as exc:
                self.send_json(409, {"error": str(exc)})
            except (ValueError, OSError, json.JSONDecodeError) as exc:
                self.send_json(400, {"error": str(exc)})

    return Handler


def build_server(state: SelectionState, token: str, host: str = "127.0.0.1", port: int = 0, preference_file: Path | None = None) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), BaseHTTPRequestHandler)
    actual_host, actual_port = server.server_address[:2]
    origin = f"http://{actual_host}:{actual_port}"
    state.receipt_url = origin
    state.receipt_token = token
    server.RequestHandlerClass = handler_class(state, token, origin, preference_file)
    server.daemon_threads = True
    return server


def serve_picker(args: argparse.Namespace) -> int:
    staging_base = Path(args.staging_root).resolve() if args.staging_root else staging_root()
    staging_base.mkdir(parents=True, exist_ok=True)
    clean_stale_sessions(staging_base)
    state = SelectionState(staging_base)
    token = secrets.token_urlsafe(24)
    server = build_server(state, token, port=args.port)
    host, port = server.server_address[:2]
    url = f"http://{host}:{port}/{token}/"
    server.timeout = 0.25
    print(json.dumps({"event": "ready", "url": url}), flush=True)
    deadline = time.monotonic() + args.timeout
    try:
        while not state.done.is_set() and time.monotonic() < deadline:
            server.handle_request()
    except KeyboardInterrupt:
        state.cancel()
    if not state.done.is_set():
        server.server_close()
        state.cleanup()
        print("ingest picker timed out", file=sys.stderr)
        return 2
    if state.cancelled:
        server.server_close()
        state.cleanup()
        print(json.dumps({"schema": SELECTION_SCHEMA, "cancelled": True}))
        return 0
    print(json.dumps({"event": "selected", **state.result}, ensure_ascii=False), flush=True)
    receipt_deadline = time.monotonic() + args.receipt_timeout
    while not state.receipt_ack.is_set() and time.monotonic() < receipt_deadline:
        server.handle_request()
        if state.receipt_done.is_set() and time.monotonic() + 5 >= receipt_deadline:
            break
    server.server_close()
    return 0


def run_picker(args: argparse.Namespace) -> int:
    command = [sys.executable, str(Path(__file__).resolve()), "--serve", "--port", str(args.port), "--timeout", str(args.timeout), "--receipt-timeout", str(args.receipt_timeout)]
    if args.staging_root:
        command.extend(["--staging-root", args.staging_root])
    child = subprocess.Popen(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    assert child.stdout
    ready = json.loads(child.stdout.readline())
    url = ready["url"]
    if not args.no_open:
        webbrowser.open(url, new=1)
    print(f"ingest picker: {url}", file=sys.stderr, flush=True)
    selected = json.loads(child.stdout.readline())
    if selected.get("event") == "selected":
        selected.pop("event", None)
        print(json.dumps(selected, ensure_ascii=False), flush=True)
        return 0
    print(json.dumps({"schema": SELECTION_SCHEMA, "cancelled": True}))
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--port", type=int, default=0)
    result.add_argument("--timeout", type=int, default=30 * 60)
    result.add_argument("--receipt-timeout", type=int, default=RECEIPT_GRACE_SECONDS)
    result.add_argument("--staging-root")
    result.add_argument("--no-open", action="store_true")
    result.add_argument("--serve", action="store_true", help=argparse.SUPPRESS)
    return result


if __name__ == "__main__":
    options = parser().parse_args()
    raise SystemExit(serve_picker(options) if options.serve else run_picker(options))
