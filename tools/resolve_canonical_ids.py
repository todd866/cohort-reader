#!/usr/bin/env python3
"""Resolve canonical public identifiers (`doi:`, `pmid:`, `isbn:`, `arxiv:`, `gutenberg:`, `ol:`)
across a local PaperLibrary SQLite catalog without mutating `catalog.db`.

Priority order:
  1. Verified DOI (`doi:...`) from catalog.db
  2. Verified PMID (`pmid:...`) from catalog.db
  3. EPUB OPF `<dc:identifier>` inside local `.epub` books (`gutenberg:`, `isbn:`, `doi:`)
  4. Front-matter text scan (`text/`) for valid check-digit ISBN-13 or arXiv IDs
  5. Optional resumable Open Library title/author lookup (`--online-openlibrary`)

Unmatched local works remain `canonicalId: null` so they stay private and never enter Manifold.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

DOI_RE = re.compile(r"10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+")
ISBN_RE = re.compile(r"97[89][-\s]?(?:[0-9][-\s]?){10}")
ARXIV_RE = re.compile(r"(?:arxiv:\s*|https?://arxiv\.org/(?:abs|pdf)/)([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?|[a-z-]+(?:\.[a-z]{2})?/[0-9]{7})", re.I)
GUTENBERG_URL_RE = re.compile(r"(?:gutenberg\.org/ebooks/|urn:gutenberg:)([1-9][0-9]{0,7})", re.I)
OL_RE = re.compile(r"\b(OL[1-9][0-9]{0,10}[WM])\b")


def valid_isbn13(raw: str) -> str | None:
    digits = "".join(ch for ch in raw if ch.isdigit())
    if len(digits) != 13 or digits[:3] not in ("978", "979"):
        return None
    total = sum(int(ch) * (1 if i % 2 == 0 else 3) for i, ch in enumerate(digits[:12]))
    check = (10 - (total % 10)) % 10
    return digits if check == int(digits[12]) else None


def extract_id_from_text(text: str, *, allow_gutenberg_url: bool = True) -> str | None:
    if not text:
        return None
    if allow_gutenberg_url:
        mg = GUTENBERG_URL_RE.search(text)
        if mg:
            return f"gutenberg:{mg.group(1)}"
    for mi in ISBN_RE.finditer(text):
        clean = valid_isbn13(mi.group(0))
        if clean:
            return f"isbn:{clean}"
    ma = ARXIV_RE.search(text)
    if ma:
        return f"arxiv:{ma.group(1)}"
    return None


def inspect_epub_canonical_id(epub_path: Path) -> str | None:
    if not epub_path.is_file():
        return None
    try:
        with zipfile.ZipFile(epub_path, "r") as zf:
            c_xml = zf.read("META-INF/container.xml")
            c_root = ET.fromstring(c_xml)
            opf = None
            for el in c_root.iter():
                if el.tag.lower().endswith("rootfile"):
                    opf = el.attrib.get("full-path")
                    if opf:
                        break
            if not opf or opf not in zf.namelist():
                return None
            o_root = ET.fromstring(zf.read(opf))
            idents: list[str] = []
            for el in o_root.iter():
                tag = el.tag.lower().split("}")[-1]
                if tag == "identifier" and el.text:
                    idents.append(el.text.strip())
            for ident in idents:
                if ident.lower().startswith("urn:isbn:"):
                    clean = valid_isbn13(ident.split(":")[-1])
                    if clean:
                        return f"isbn:{clean}"
                found = extract_id_from_text(ident)
                if found:
                    return found
                md = DOI_RE.search(ident)
                if md:
                    return f"doi:{md.group(0).rstrip('.,;)>]')}"
    except Exception:
        return None
    return None


def lookup_openlibrary(title: str, authors: str) -> str | None:
    q = f"{title} {authors}".strip()
    if len(q) < 4:
        return None
    url = "https://openlibrary.org/search.json?" + urllib.parse.urlencode({"title": title, "author": authors, "limit": 1})
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "CohortReader/1.0 (https://github.com/todd866/cohort-reader)"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        docs = data.get("docs") or []
        if not docs:
            return None
        doc = docs[0]
        for isbn in doc.get("isbn") or []:
            clean = valid_isbn13(str(isbn))
            if clean:
                return f"isbn:{clean}"
        key = str(doc.get("key") or "")
        if key.startswith("/works/"):
            wid = key.split("/")[-1]
            if OL_RE.match(wid):
                return f"ol:{wid}"
    except Exception:
        return None
    return None


def resolve_corpus(
    corpus_dir: Path,
    out_path: Path,
    *,
    online_openlibrary: bool = False,
    ol_limit: int = 100,
) -> dict[str, dict]:
    db_path = corpus_dir / "catalog.db"
    if not db_path.is_file():
        raise FileNotFoundError(f"catalog.db not found at {db_path}")

    existing: dict[str, dict] = {}
    if out_path.is_file():
        try:
            existing = json.loads(out_path.read_text(encoding="utf-8"))
        except Exception:
            existing = {}

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            """
            SELECT p.slug, p.doi, p.pmid, p.title, p.authors, p.year, p.source,
                   p.pdf_path, p.text_path,
                   COALESCE(l.record_kind, '') AS record_kind,
                   COALESCE(l.genre, '') AS genre
            FROM papers p
            LEFT JOIN librarian l ON l.slug = p.slug
            ORDER BY p.slug
            """
        ).fetchall()
    finally:
        con.close()

    results: dict[str, dict] = {}
    ol_lookups = 0
    for row in rows:
        slug = str(row["slug"])
        doi = str(row["doi"] or "").strip()
        pmid = str(row["pmid"] or "").strip()
        pdf_path_raw = str(row["pdf_path"] or "").strip()
        text_path_raw = str(row["text_path"] or "").strip()
        title = str(row["title"] or "").strip()
        authors = str(row["authors"] or "").strip()

        canon: str | None = None
        origin = "unresolved"

        if doi and DOI_RE.match(doi):
            canon = f"doi:{doi}"
            origin = "catalog:doi"
        elif pmid and pmid.isdigit() and int(pmid) > 0:
            canon = f"pmid:{int(pmid)}"
            origin = "catalog:pmid"
        elif slug in existing and existing[slug].get("canonicalId"):
            canon = existing[slug]["canonicalId"]
            origin = existing[slug].get("resolutionOrigin", "cached")
        else:
            if pdf_path_raw.lower().endswith(".epub"):
                ep = Path(pdf_path_raw)
                if not ep.is_absolute():
                    ep = corpus_dir / ep
                canon = inspect_epub_canonical_id(ep)
                if canon:
                    origin = "epub:opf"

            if not canon and text_path_raw:
                tp = Path(text_path_raw)
                if not tp.is_absolute():
                    tp = corpus_dir / tp
                if tp.is_file():
                    try:
                        front = tp.read_text(encoding="utf-8", errors="ignore")[:18000]
                        canon = extract_id_from_text(front)
                        if canon:
                            origin = "text:frontmatter"
                    except OSError:
                        pass

            if not canon:
                canon = extract_id_from_text(title)
                if canon:
                    origin = "catalog:title"

            if not canon and online_openlibrary and ol_lookups < ol_limit and row["record_kind"] == "book":
                ol_lookups += 1
                canon = lookup_openlibrary(title, authors)
                if canon:
                    origin = "openlibrary"

        results[slug] = {
            "canonicalId": canon,
            "resolutionOrigin": origin,
            "kind": row["record_kind"] or ("book" if str(row["source"]).startswith("book:") else "paper"),
            "genre": row["genre"],
            "title": title,
            "authors": authors,
            "year": row["year"],
        }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, out_path)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve canonical IDs across PaperLibrary")
    parser.add_argument("--corpus", default="~/Projects/PaperLibrary")
    parser.add_argument("--out", default="~/.local/state/cohort-reader-embed/canonical-ids.json")
    parser.add_argument("--online-openlibrary", action="store_true")
    parser.add_argument("--ol-limit", type=int, default=100)
    args = parser.parse_args()

    res = resolve_corpus(
        Path(args.corpus).expanduser(),
        Path(args.out).expanduser(),
        online_openlibrary=args.online_openlibrary,
        ol_limit=args.ol_limit,
    )
    counts = Counter()
    for v in res.values():
        cid = v.get("canonicalId")
        ns = cid.split(":", 1)[0] if cid else "unresolved"
        counts[ns] += 1
    print(f"Resolved {len(res)} total works -> {dict(counts)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
