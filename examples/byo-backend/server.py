#!/usr/bin/env python3
"""
Reference Bring-Your-Own (BYO) Home Library backend for Cohort Reader.

Zero third-party dependencies (Python 3.10+ stdlib only). Scans a local folder of
`.epub` and `.pdf` files, extracts title/author/canonical IDs (`isbn:`, `doi:`,
`gutenberg:`, `arxiv:`) locally, optionally joins k-anonymous Manifold shards
(`/api/v1/shard/:prefix?domain=reader`) without leaking filenames, and serves the
HTTP contract expected by `HomeLibraryClient`:
  - POST /api/login
  - GET  /api/home
  - GET  /api/search?q=...&limit=...
  - GET  /api/book/<id>        (with HTTP 206 Range support)
  - GET  /api/cover/<id>
  - GET  /api/notes/<id>[/<asset>]
  - POST /api/progress
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import hmac
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sys
import threading
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

BOOK_EXTENSIONS: dict[str, str] = {
    ".epub": "application/epub+zip",
    ".pdf": "application/pdf",
}

COVER_NAMES = ("cover.jpg", "cover.jpeg", "cover.png", "cover.webp")
ISBN_RE = re.compile(r"97[89][-\s]?(?:[0-9][-\s]?){10}")
DOI_RE = re.compile(r"10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+")
GUTENBERG_RE = re.compile(r"(?:urn:)?gutenberg:([1-9][0-9]{0,7})", re.I)
ARXIV_RE = re.compile(r"(?:arxiv:)?([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?)", re.I)


def shard_prefix(work_id: str) -> str:
    return hashlib.sha256(work_id.encode("utf-8")).hexdigest()[:2]


def valid_isbn13(raw: str) -> str | None:
    digits = "".join(ch for ch in raw if ch.isdigit())
    if len(digits) != 13 or digits[:3] not in ("978", "979"):
        return None
    total = sum(int(ch) * (1 if i % 2 == 0 else 3) for i, ch in enumerate(digits[:12]))
    check = (10 - (total % 10)) % 10
    return digits if check == int(digits[12]) else None


def extract_canonical_id(text: str) -> str | None:
    if not text:
        return None
    m_gut = GUTENBERG_RE.search(text)
    if m_gut:
        return f"gutenberg:{m_gut.group(1)}"
    for m_isbn in ISBN_RE.finditer(text):
        clean = valid_isbn13(m_isbn.group(0))
        if clean:
            return f"isbn:{clean}"
    if "arxiv" in text.lower():
        m_ax = ARXIV_RE.search(text)
        if m_ax:
            return f"arxiv:{m_ax.group(1)}"
    m_doi = DOI_RE.search(text)
    if m_doi:
        return f"doi:{m_doi.group(0).rstrip('.,;)>]')}"
    return None


def inspect_epub_metadata(path: Path) -> tuple[str, str, str | None, str | None]:
    """Read title, creator, canonicalId, and cover internal path from an EPUB safely."""
    title = path.stem
    author = "Unknown"
    canonical_id: str | None = None
    cover_entry: str | None = None
    try:
        with zipfile.ZipFile(path, "r") as zf:
            container_xml = zf.read("META-INF/container.xml")
            c_root = ET.fromstring(container_xml)
            opf_path = None
            for elem in c_root.iter():
                if elem.tag.lower().endswith("rootfile"):
                    opf_path = elem.attrib.get("full-path")
                    if opf_path:
                        break
            if not opf_path or opf_path not in zf.namelist():
                return title, author, canonical_id, cover_entry
            opf_data = zf.read(opf_path)
            opf_dir = str(Path(opf_path).parent)
            if opf_dir == ".":
                opf_dir = ""
            o_root = ET.fromstring(opf_data)
            titles: list[str] = []
            creators: list[str] = []
            idents: list[str] = []
            manifest: dict[str, tuple[str, str]] = {}
            cover_id: str | None = None
            for elem in o_root.iter():
                tag = elem.tag.lower().split("}")[-1]
                text = (elem.text or "").strip()
                if tag == "title" and text:
                    titles.append(text)
                elif tag == "creator" and text:
                    creators.append(text)
                elif tag == "identifier" and text:
                    idents.append(text)
                elif tag == "meta" and elem.attrib.get("name", "").lower() == "cover":
                    cover_id = elem.attrib.get("content")
                elif tag == "item" and "id" in elem.attrib and "href" in elem.attrib:
                    href = elem.attrib["href"]
                    props = elem.attrib.get("properties", "")
                    manifest[elem.attrib["id"]] = (href, props)
                    if "cover-image" in props:
                        cover_id = elem.attrib["id"]
            if titles:
                title = titles[0]
            if creators:
                author = "; ".join(creators)
            for ident in idents:
                cid = extract_canonical_id(ident)
                if cid:
                    canonical_id = cid
                    break
            if cover_id and cover_id in manifest:
                rel = manifest[cover_id][0]
                resolved = str((Path(opf_dir) / rel).as_posix()) if opf_dir else rel
                if resolved in zf.namelist():
                    cover_entry = resolved
    except Exception:
        pass
    return title, author, canonical_id, cover_entry


def parse_byte_range(header_val: str | None, total_size: int) -> tuple[int, int] | None:
    if not header_val:
        return None
    spec = header_val.strip()
    if not spec.startswith("bytes=") or "," in spec or total_size <= 0:
        return None
    part = spec[len("bytes=") :].strip()
    if "-" not in part:
        return None
    start_s, end_s = part.split("-", 1)
    try:
        if start_s == "":
            suffix = int(end_s)
            if suffix <= 0:
                return None
            return (max(0, total_size - suffix), total_size - 1)
        start = int(start_s)
        if start < 0 or start >= total_size:
            return None
        end = total_size - 1 if end_s == "" else min(total_size - 1, int(end_s))
        return (start, end) if end >= start else None
    except ValueError:
        return None


@dataclass
class BookRecord:
    id: str
    path: Path
    fmt: str
    title: str
    author: str
    year: int | None
    canonical_id: str | None
    genre: str
    summary: str
    size_bytes: int
    cover_path: Path | None = None
    epub_cover_entry: str | None = None
    notes_dir: Path | None = None
    point: dict[str, float] | None = None

    def to_wire(self, locator: dict[str, Any] | None = None) -> dict[str, Any]:
        obj: dict[str, Any] = {
            "id": self.id,
            "canonicalId": self.canonical_id,
            "title": self.title,
            "author": self.author,
            "year": self.year,
            "format": self.fmt,
            "genre": self.genre,
            "subgenre": "",
            "summary": self.summary,
            "shelves": [self.genre],
            "bytes": self.size_bytes,
            "hasCover": bool(self.cover_path or self.epub_cover_entry),
            "notesVersion": "v1" if self.notes_dir and (self.notes_dir / "notes.json").is_file() else None,
        }
        if locator:
            obj["locator"] = locator
        if self.point:
            obj["point"] = self.point
        return obj


@dataclass
class LibraryState:
    books_dir: Path
    passphrase: str
    server_name: str = "Home Library"
    manifold_url: str | None = None
    state_path: Path | None = None
    cookie_secret: bytes = field(default_factory=lambda: secrets.token_bytes(32))
    lock: threading.RLock = field(default_factory=threading.RLock)
    books: dict[str, BookRecord] = field(default_factory=dict)
    locators: dict[str, dict[str, Any]] = field(default_factory=dict)
    failed_attempts: dict[str, tuple[int, float]] = field(default_factory=dict)

    def scan(self) -> None:
        resolved_root = self.books_dir.resolve()
        found: dict[str, BookRecord] = {}
        for p in sorted(resolved_root.rglob("*")):
            if not p.is_file():
                continue
            ext = p.suffix.lower()
            if ext not in BOOK_EXTENSIONS:
                continue
            rel = p.relative_to(resolved_root).as_posix()
            book_id = hashlib.sha256(rel.encode("utf-8")).hexdigest()[:16]
            fmt = "epub" if ext == ".epub" else "pdf"
            genre = p.parent.name if p.parent != resolved_root else "Library"
            title = p.stem
            author = "Unknown"
            canonical_id = extract_canonical_id(p.stem)
            epub_cover: str | None = None
            if fmt == "epub":
                title, author, epub_cid, epub_cover = inspect_epub_metadata(p)
                canonical_id = epub_cid or canonical_id

            cover_path = None
            for cname in COVER_NAMES:
                cand = p.parent / cname
                if cand.is_file():
                    cover_path = cand
                    break
            if cover_path is None:
                sidecar_jpg = p.with_suffix(".jpg")
                sidecar_png = p.with_suffix(".png")
                if sidecar_jpg.is_file():
                    cover_path = sidecar_jpg
                elif sidecar_png.is_file():
                    cover_path = sidecar_png

            notes_dir = p.with_suffix(".notes")
            found[book_id] = BookRecord(
                id=book_id,
                path=p.resolve(),
                fmt=fmt,
                title=title,
                author=author,
                year=None,
                canonical_id=canonical_id,
                genre=genre,
                summary="",
                size_bytes=p.stat().st_size,
                cover_path=cover_path,
                epub_cover_entry=epub_cover,
                notes_dir=notes_dir if notes_dir.is_dir() else None,
            )

        with self.lock:
            self.books = found
            self._load_state()
        if self.manifold_url:
            self.enrich_via_manifold_shards()

    def enrich_via_manifold_shards(self) -> None:
        if not self.manifold_url:
            return
        with self.lock:
            prefixes = {shard_prefix(b.canonical_id) for b in self.books.values() if b.canonical_id}
        if not prefixes:
            return
        hub = self.manifold_url.rstrip("/")
        coords: dict[str, dict[str, float]] = {}
        for prefix in sorted(prefixes):
            url = f"{hub}/api/v1/shard/{prefix}?domain=reader"
            try:
                req = urllib.request.Request(url, headers={"Accept": "application/json"})
                with urllib.request.urlopen(req, timeout=8) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                for w in payload.get("works", []):
                    wid = w.get("workId")
                    if wid and "x" in w and "y" in w:
                        coords[wid] = {"x": float(w["x"]), "y": float(w["y"])}
            except Exception:
                continue
        if coords:
            with self.lock:
                for b in self.books.values():
                    if b.canonical_id and b.canonical_id in coords:
                        b.point = coords[b.canonical_id]

    def _load_state(self) -> None:
        if not self.state_path or not self.state_path.is_file():
            return
        try:
            raw = json.loads(self.state_path.read_text(encoding="utf-8"))
            if isinstance(raw.get("locators"), dict):
                self.locators = raw["locators"]
        except Exception:
            pass

    def _save_state(self) -> None:
        if not self.state_path:
            return
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"locators": self.locators}, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, self.state_path)

    def make_cookie_token(self) -> str:
        exp = str(int(time.time()) + 30 * 86400)
        sig = hmac.new(self.cookie_secret, exp.encode("utf-8"), hashlib.sha256).hexdigest()
        return f"{exp}.{sig}"

    def verify_cookie_token(self, token: str | None) -> bool:
        if not token or "." not in token:
            return False
        exp, sig = token.split(".", 1)
        expected = hmac.new(self.cookie_secret, exp.encode("utf-8"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return False
        try:
            return int(exp) >= int(time.time())
        except ValueError:
            return False

    def record_progress(self, events: list[dict[str, Any]]) -> int:
        accepted = 0
        with self.lock:
            for evt in events:
                bid = str(evt.get("bookId") or "").strip()
                if bid not in self.books:
                    continue
                cand = {
                    "spine": int(evt.get("spine") or 0),
                    "fraction": max(0.0, min(1.0, float(evt.get("fraction") or 0.0))),
                    "wordOffset": evt.get("wordOffset"),
                    "pageIndex": evt.get("pageIndex"),
                    "updatedAt": str(evt.get("updatedAt") or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")),
                }
                prev = self.locators.get(bid)
                if not prev or cand["updatedAt"] >= prev.get("updatedAt", ""):
                    self.locators[bid] = cand
                accepted += 1
            self._save_state()
        return accepted


def make_handler(state: LibraryState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:
            return

        def _send_json(self, code: int, obj: Any, extra_headers: dict[str, str] | None = None) -> None:
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            if extra_headers:
                for k, v in extra_headers.items():
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _is_authenticated(self) -> bool:
            raw_cookie = self.headers.get("Cookie", "")
            jar = cookies.SimpleCookie()
            jar.load(raw_cookie)
            morsel = jar.get("cohort_reader_session")
            return bool(morsel and state.verify_cookie_token(morsel.value))

        def _read_json_body(self) -> Any:
            length = int(self.headers.get("Content-Length", "0") or 0)
            if length <= 0 or length > 2 * 1024 * 1024:
                return None
            raw = self.rfile.read(length)
            try:
                return json.loads(raw.decode("utf-8"))
            except Exception:
                return None

        def do_POST(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/api/login":
                ip = self.client_address[0]
                now = time.time()
                with state.lock:
                    cnt, until = state.failed_attempts.get(ip, (0, 0.0))
                    if now < until:
                        self._send_json(429, {"error": "rate_limited"})
                        return
                body = self._read_json_body()
                pw = str((body or {}).get("pass") or "")
                if not secrets.compare_digest(pw, state.passphrase):
                    with state.lock:
                        cnt, _ = state.failed_attempts.get(ip, (0, 0.0))
                        cnt += 1
                        lock_until = now + 60.0 if cnt >= 8 else 0.0
                        state.failed_attempts[ip] = (cnt, lock_until)
                    self._send_json(401, {"error": "unauthorized"})
                    return
                with state.lock:
                    state.failed_attempts.pop(ip, None)
                    count = len(state.books)
                tok = state.make_cookie_token()
                self._send_json(
                    200,
                    {"name": state.server_name, "count": count},
                    extra_headers={"Set-Cookie": f"cohort_reader_session={tok}; Path=/; HttpOnly; SameSite=Lax"},
                )
                return

            if not self._is_authenticated():
                self._send_json(401, {"error": "unauthorized"})
                return

            if parsed.path == "/api/progress":
                body = self._read_json_body() or {}
                events = body.get("events") if isinstance(body, dict) else None
                if not isinstance(events, list):
                    self._send_json(400, {"error": "invalid_events"})
                    return
                accepted = state.record_progress(events)
                self._send_json(200, {"accepted": accepted})
                return

            self._send_json(404, {"error": "not_found"})

        def do_HEAD(self) -> None:
            self._handle_get(send_body=False)

        def do_GET(self) -> None:
            self._handle_get(send_body=True)

        def _handle_get(self, send_body: bool) -> None:
            if not self._is_authenticated():
                self._send_json(401, {"error": "unauthorized"})
                return
            parsed = urllib.parse.urlparse(self.path)
            parts = [urllib.parse.unquote(p) for p in parsed.path.strip("/").split("/") if p]

            if parsed.path == "/api/home":
                with state.lock:
                    reading_ids = [bid for bid, loc in state.locators.items() if 0.0 < float(loc.get("fraction", 0)) < 0.98]
                    items = [b.to_wire(state.locators.get(b.id)) for b in state.books.values()]
                shelves = []
                if reading_ids:
                    shelves.append({"id": "reading", "title": "Reading Now", "itemIds": reading_ids})
                self._send_json(200, {"serverName": state.server_name, "shelves": shelves, "items": items})
                return

            if parsed.path == "/api/search":
                qs = urllib.parse.parse_qs(parsed.query)
                q = (qs.get("q", [""])[0]).strip().lower()
                limit = min(100, max(1, int(qs.get("limit", ["30"])[0])))
                with state.lock:
                    matches = [
                        b.to_wire(state.locators.get(b.id))
                        for b in state.books.values()
                        if not q
                        or q in b.title.lower()
                        or q in b.author.lower()
                        or q in b.genre.lower()
                        or (b.canonical_id and q in b.canonical_id.lower())
                    ][:limit]
                self._send_json(200, {"items": matches})
                return

            if len(parts) == 3 and parts[0] == "api" and parts[1] == "book":
                bid = parts[2]
                with state.lock:
                    rec = state.books.get(bid)
                if not rec or not rec.path.is_file():
                    self._send_json(404, {"error": "book_not_found"})
                    return
                total = rec.path.stat().st_size
                ctype = BOOK_EXTENSIONS.get(rec.path.suffix.lower(), "application/octet-stream")
                rng = parse_byte_range(self.headers.get("Range"), total)
                if rng is not None:
                    start, end = rng
                    length = end - start + 1
                    self.send_response(206)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                    self.send_header("Content-Length", str(length))
                    self.end_headers()
                    if send_body:
                        with rec.path.open("rb") as fh:
                            fh.seek(start)
                            remaining = length
                            while remaining > 0:
                                chunk = fh.read(min(65536, remaining))
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                                remaining -= len(chunk)
                    return

                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(total))
                self.end_headers()
                if send_body:
                    with rec.path.open("rb") as fh:
                        while chunk := fh.read(65536):
                            self.wfile.write(chunk)
                return

            if len(parts) == 3 and parts[0] == "api" and parts[1] == "cover":
                bid = parts[2]
                with state.lock:
                    rec = state.books.get(bid)
                if not rec:
                    self._send_json(404, {"error": "not_found"})
                    return
                data: bytes | None = None
                ctype = "image/jpeg"
                if rec.cover_path and rec.cover_path.is_file():
                    data = rec.cover_path.read_bytes()
                    ctype = "image/png" if rec.cover_path.suffix.lower() == ".png" else "image/jpeg"
                elif rec.epub_cover_entry and rec.path.is_file():
                    try:
                        with zipfile.ZipFile(rec.path, "r") as zf:
                            data = zf.read(rec.epub_cover_entry)
                        ctype = "image/png" if rec.epub_cover_entry.lower().endswith(".png") else "image/jpeg"
                    except Exception:
                        data = None
                if not data:
                    self._send_json(404, {"error": "no_cover"})
                    return
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if send_body:
                    self.wfile.write(data)
                return

            if len(parts) >= 3 and parts[0] == "api" and parts[1] == "notes":
                bid = parts[2]
                with state.lock:
                    rec = state.books.get(bid)
                if not rec or not rec.notes_dir:
                    self._send_json(404, {"error": "no_notes"})
                    return
                if len(parts) == 3:
                    notes_file = rec.notes_dir / "notes.json"
                    if not notes_file.is_file():
                        self._send_json(404, {"error": "no_notes"})
                        return
                    raw = notes_file.read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    if send_body:
                        self.wfile.write(raw)
                    return
                if len(parts) == 4:
                    asset = parts[3]
                    if "/" in asset or "\\" in asset or asset in (".", ".."):
                        self._send_json(400, {"error": "bad_asset"})
                        return
                    target = (rec.notes_dir / asset).resolve()
                    if not str(target).startswith(str(rec.notes_dir.resolve()) + os.sep) or not target.is_file():
                        self._send_json(404, {"error": "asset_not_found"})
                        return
                    data = target.read_bytes()
                    ctype = "image/png" if target.suffix.lower() == ".png" else "image/jpeg"
                    self.send_response(200)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    if send_body:
                        self.wfile.write(data)
                    return

            self._send_json(404, {"error": "not_found"})

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description="Reference BYO Home Library Server for Cohort Reader")
    parser.add_argument("--books-dir", required=True, help="Directory of your EPUB/PDF files")
    parser.add_argument("--pass", dest="passphrase", required=True, help="Server passphrase")
    parser.add_argument("--port", type=int, default=8696)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--name", default="Home Library")
    parser.add_argument("--manifold-url", default="https://manifold-chi.vercel.app")
    parser.add_argument("--state-file", default="~/.local/state/cohort-reader-byo/state.json")
    args = parser.parse_args()

    state = LibraryState(
        books_dir=Path(args.books_dir).expanduser(),
        passphrase=args.passphrase,
        server_name=args.name,
        manifold_url=args.manifold_url or None,
        state_path=Path(args.state_file).expanduser(),
    )
    state.scan()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    print(f"Cohort Reader BYO Server listening on http://{args.host}:{args.port} ({len(state.books)} books)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
