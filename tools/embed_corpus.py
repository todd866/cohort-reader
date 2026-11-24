#!/usr/bin/env python3
"""Dual-map corpus embedder and fail-closed Manifold exporter for Cohort Reader.

Replaces PaperLibrary's 256-token MiniLM front-matter truncation with multi-chunk
document pooling in Manifold's shared embedding space:
  - Coverage map (768-D, $0): local Apple Silicon MLX `embeddinggemma-2-bf16`
  - Detail map (3072-D): Gemini Embedding 2 Batch API gated by the shared
    `~/Projects/music-core/embed/budget.py` $100/mo ledger + METERED_LINK check
  - Relation (`relate`): Ridge 768->3072 + held-out recall@10 + top-10 overlap
  - Space & Manifold export (`export-space`, `export-manifold`): builds local
    `reader-space.json` and fail-closed Ed25519-signed canonical exports containing
    ZERO local paths, ZERO `.epub`/`.pdf` filenames, and ZERO unmapped private slugs.
"""

from __future__ import annotations

import argparse
from array import array
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from typing import Any, Sequence

GEMMA_DIM = 768
GEMINI_DIM = 3072
GEMINI_MODEL = "gemini-embedding-2"
GEMINI_SHARD_LINES = 10000
GEMINI_SHARD_MAX_TOKENS = 2_800_000
GEMINI_CONCURRENT_TOKEN_BUDGET = 4_500_000
PERTH_TZ = timezone(timedelta(hours=8))
DEFAULT_GEMMA_MODEL = "mlx-community/embeddinggemma-2-bf16"
DEFAULT_STATE_DIR = Path.home() / ".local/state/cohort-reader-embed"
DEFAULT_CORPUS_DIR = Path(os.environ.get("COHORT_READER_CORPUS", str(Path.home() / "Projects/PaperLibrary")))
DEFAULT_BUDGET_MODULE = Path.home() / "Projects/music-core/embed/budget.py"
METERED_LINK_MARKER = Path.home() / ".local/state/METERED_LINK"

# Gemini Embedding 2 Batch pricing estimate ($0.075 / 1M input tokens)
BATCH_USD_PER_1M_TOKENS = 0.075

CANONICAL_RE = re.compile(
    r"^(?:wikidata:Q[1-9][0-9]{0,12}|"
    r"ia:[A-Za-z0-9._-]{2,120}|"
    r"doi:10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+|"
    r"pmid:[1-9][0-9]{0,10}|"
    r"isbn:97[89][0-9]{10}|"
    r"ol:OL[1-9][0-9]{0,10}[WM]|"
    r"gutenberg:[1-9][0-9]{0,7}|"
    r"arxiv:(?:[0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?|[a-z-]+(?:\.[a-z]{2})?/[0-9]{7}))$",
    re.I,
)
FORBIDDEN_EXT_RE = re.compile(
    r"\.(?:mp4|m4v|mkv|avi|mov|ts|m2ts|webm|flac|m4a|mp3|wav|ogg|aac|alac|srt|vtt|epub|pdf|azw3|mobi|djvu|chm|cbz|cbr|fb2|docx)\b",
    re.I,
)
FORBIDDEN_PATH_RE = re.compile(
    r"(?:/" + r"Users/|/" + r"Volumes/|/home/|/private/|[A-Za-z]:\\|\.\./|~/)",
    re.I,
)
BARE_HASH_RE = re.compile(r"^(?:sha256:|sha1:)?[0-9a-f]{40}(?:[0-9a-f]{24})?$", re.I)


def l2_normalize(vec: Any) -> Any:
    if hasattr(vec, "ndim"):
        import numpy as np  # type: ignore

        arr = np.asarray(vec, dtype=np.float32)
        if arr.ndim == 1:
            n = float(np.linalg.norm(arr))
            return arr / n if n > 1e-12 else arr
        norms = np.linalg.norm(arr, axis=1, keepdims=True)
        return arr / np.maximum(norms, 1e-12)
    vals = [float(x) for x in vec]
    n = math.sqrt(sum(x * x for x in vals))
    if n <= 1e-12:
        return vals
    return [x / n for x in vals]


def strip_boilerplate(text: str) -> str:
    """Remove Project Gutenberg headers/footers and repeated website navigation noise."""
    start_m = re.search(r"\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^\n]*", text, re.I)
    if start_m:
        text = text[start_m.end() :]
    end_m = re.search(r"\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK", text, re.I)
    if end_m:
        text = text[: end_m.start()]
    return text.strip()


def build_multichunk_windows(
    *,
    title: str,
    authors: str = "",
    genre: str = "",
    subgenre: str = "",
    description: str = "",
    topics: Sequence[str] = (),
    body: str = "",
    max_body_windows: int = 5,
    window_chars: int = 1500,
) -> list[tuple[str, str, float]]:
    """Return weighted `(title_prefix, body_chunk, weight)` tuples spanning the whole document.

    Chunk 0 carries bibliographic header + librarian summary/topics (weight 2.0) so concise works
    without full text still position accurately; up to 5 evenly-spaced windows sample beginning,
    early, middle, late, and concluding content (weight 1.0 each).
    """
    header_parts = [p.strip() for p in (title, authors, subgenre or genre, description, ", ".join(topics)) if p and p.strip()]
    header_text = "\n".join(header_parts) or (title or "Untitled")
    windows: list[tuple[str, str, float]] = [(title or "Untitled", header_text[:window_chars], 2.0)]

    cleaned = strip_boilerplate(body)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        return windows

    n = len(cleaned)
    if n <= window_chars:
        windows.append((title or "Untitled", cleaned, 1.0))
        return windows

    count = max(1, max_body_windows)
    step = max(1, (n - window_chars) // max(1, count - 1))
    seen_starts: set[int] = set()
    for i in range(count):
        pos = min(n - window_chars, i * step)
        if pos in seen_starts:
            continue
        seen_starts.add(pos)
        windows.append((title or "Untitled", cleaned[pos : pos + window_chars], 1.0))
    return windows


def pool_chunk_vectors(chunk_vecs: Sequence[Any], weights: Sequence[float]) -> Any:
    if hasattr(chunk_vecs, "ndim"):
        import numpy as np  # type: ignore

        mat = np.asarray(chunk_vecs, dtype=np.float32)
        w = np.asarray(weights, dtype=np.float32).reshape(-1, 1)
        pooled = np.sum(mat * w, axis=0)
        return l2_normalize(pooled)
    if not chunk_vecs:
        return []
    dim = len(chunk_vecs[0])
    acc = [0.0] * dim
    for vec, w in zip(chunk_vecs, weights):
        wf = float(w)
        for i, val in enumerate(vec):
            acc[i] += float(val) * wf
    return l2_normalize(acc)


def repair_tail(out_dir: Path, dim: int) -> list[dict[str, Any]]:
    idx_path = out_dir / "docs-index.jsonl"
    f32_path = out_dir / "docs.f32"
    rows: list[dict[str, Any]] = []
    if idx_path.is_file():
        for line in idx_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    if not f32_path.is_file():
        return []
    want = len(rows) * dim * 4
    actual = f32_path.stat().st_size
    if actual > want:
        with f32_path.open("r+b") as fh:
            fh.truncate(want)
    elif actual < want:
        raise RuntimeError(f"{f32_path} shorter than index ({actual} < {want})")
    return rows


def append_vectors(out_dir: Path, rows: list[dict[str, Any]], vecs: list[Any]) -> None:
    """Append vectors before index lines so crash-tail recovery stays lossless."""
    out_dir.mkdir(parents=True, exist_ok=True)
    with (out_dir / "docs.f32").open("ab") as fh:
        for v in vecs:
            if hasattr(v, "astype") and hasattr(v, "tobytes"):
                fh.write(v.astype("<f4", copy=False).tobytes())
            else:
                buf = array("f", (float(x) for x in v))
                if sys.byteorder != "little":
                    buf.byteswap()
                fh.write(buf.tobytes())
    with (out_dir / "docs-index.jsonl").open("a", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")


def open_ro_catalog(db_path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def load_corpus_records(corpus_dir: Path, canonical_ids_path: Path, limit: int | None = None) -> list[dict[str, Any]]:
    canon_map: dict[str, dict[str, Any]] = {}
    if canonical_ids_path.is_file():
        canon_map = json.loads(canonical_ids_path.read_text(encoding="utf-8"))

    con = open_ro_catalog(corpus_dir / "catalog.db")
    try:
        rows = con.execute(
            """
            SELECT p.slug, p.doi, p.pmid, p.title, p.authors, p.year, p.text_path, p.source,
                   COALESCE(l.record_kind, '') AS record_kind,
                   COALESCE(l.genre, '') AS genre,
                   COALESCE(l.subgenre, '') AS subgenre,
                   COALESCE(l.description, '') AS description,
                   COALESCE(l.topics_json, '[]') AS topics_json
            FROM papers p
            LEFT JOIN librarian l ON l.slug = p.slug
            ORDER BY p.slug
            """
        ).fetchall()
    finally:
        con.close()

    out: list[dict[str, Any]] = []
    for row in rows:
        slug = str(row["slug"])
        cid = (canon_map.get(slug) or {}).get("canonicalId")
        if not cid:
            doi = str(row["doi"] or "").strip()
            pmid = str(row["pmid"] or "").strip()
            if doi:
                cid = f"doi:{doi}"
            elif pmid and pmid.isdigit():
                cid = f"pmid:{pmid}"

        tp_raw = str(row["text_path"] or "").strip()
        body = ""
        if tp_raw:
            tp = Path(tp_raw)
            if not tp.is_absolute():
                tp = corpus_dir / tp
            if tp.is_file():
                try:
                    body = tp.read_text(encoding="utf-8", errors="ignore")[:120_000]
                except OSError:
                    body = ""

        try:
            topics = json.loads(row["topics_json"] or "[]")
        except Exception:
            topics = []

        out.append({
            "slug": slug,
            "canonicalId": cid,
            "title": str(row["title"] or slug),
            "authors": str(row["authors"] or "Unknown"),
            "year": str(row["year"] or ""),
            "kind": row["record_kind"] or "paper",
            "genre": str(row["genre"] or ""),
            "subgenre": str(row["subgenre"] or ""),
            "description": str(row["description"] or ""),
            "topics": topics if isinstance(topics, list) else [],
            "body": body,
        })
        if limit and len(out) >= limit:
            break
    return out


class MlxGemmaTextEmbedder:
    def __init__(self, model_id: str = DEFAULT_GEMMA_MODEL):
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
        import mlx.core as mx  # type: ignore
        from mlx_vlm.embedding_loader import load_embedding_model  # type: ignore
        from mlx_vlm.utils import get_model_path  # type: ignore
        from transformers import AutoTokenizer  # type: ignore

        self.mx = mx
        path = get_model_path(model_id)
        self.model = load_embedding_model(path)
        self.tokenizer = AutoTokenizer.from_pretrained(path)

    def encode_windows(self, pairs: Sequence[tuple[str, str]], batch_size: int = 16) -> Any:
        import numpy as np  # type: ignore

        formatted = [f"title: {(t or 'none')[:120]} | text: {b}" for t, b in pairs]
        chunks: list[Any] = []
        for i in range(0, len(formatted), batch_size):
            batch = formatted[i : i + batch_size]
            inputs = self.tokenizer(batch, padding=True, truncation=True, max_length=1024, return_tensors="np")
            mx_inputs = {k: self.mx.array(v) for k, v in inputs.items()}
            emb = self.model(**mx_inputs).text_embeds
            self.mx.eval(emb)
            arr = np.asarray(emb.tolist(), dtype=np.float32)
            chunks.append(l2_normalize(arr))
        return np.vstack(chunks)


def cmd_gemma(args: argparse.Namespace) -> int:
    state_dir = Path(args.state).expanduser()
    out_dir = state_dir / "vectors-gemma"
    existing_rows = repair_tail(out_dir, GEMMA_DIM)
    done_slugs = {r["slug"] for r in existing_rows}

    records = load_corpus_records(Path(args.corpus).expanduser(), state_dir / "canonical-ids.json")
    if args.canonical_only:
        records = [r for r in records if r["canonicalId"]]
    pending = [r for r in records if r["slug"] not in done_slugs]
    if args.limit:
        pending = pending[: args.limit]
    if not pending:
        print(f"Gemma map up to date ({len(existing_rows)} docs)")
        return 0

    embedder = MlxGemmaTextEmbedder(args.model)
    started = time.monotonic()
    deadline = started + args.max_minutes * 60.0 if args.max_minutes else None

    added = 0
    for start in range(0, len(pending), args.batch_docs):
        if deadline and time.monotonic() >= deadline:
            break
        batch = pending[start : start + args.batch_docs]
        all_pairs: list[tuple[str, str]] = []
        slices: list[tuple[int, int, list[float]]] = []
        for r in batch:
            wins = build_multichunk_windows(
                title=r["title"],
                authors=r["authors"],
                genre=r["genre"],
                subgenre=r["subgenre"],
                description=r["description"],
                topics=r["topics"],
                body=r["body"],
            )
            begin = len(all_pairs)
            all_pairs.extend((t, b) for t, b, _ in wins)
            slices.append((begin, len(all_pairs), [w for _, _, w in wins]))

        mat = embedder.encode_windows(all_pairs, batch_size=16)
        rows_out: list[dict[str, Any]] = []
        vecs_out: list[Any] = []
        for r, (begin, end, weights) in zip(batch, slices):
            pooled = pool_chunk_vectors(mat[begin:end], weights)
            rows_out.append({
                "slug": r["slug"],
                "canonicalId": r["canonicalId"],
                "title": r["title"][:180],
                "authors": r["authors"][:140],
                "year": r["year"],
                "kind": r["kind"],
                "genre": r["genre"],
                "description": r["description"][:280],
            })
            vecs_out.append(pooled)
        append_vectors(out_dir, rows_out, vecs_out)
        added += len(batch)

    print(f"Gemma 768-D embedded {added} docs (total {len(existing_rows) + added}) -> {out_dir}")
    return 0


def estimate_gemini_batch_cost(records: list[dict[str, Any]]) -> dict[str, Any]:
    total_chars = 0
    total_requests = 0
    for r in records:
        wins = build_multichunk_windows(
            title=r["title"],
            authors=r["authors"],
            genre=r["genre"],
            subgenre=r["subgenre"],
            description=r["description"],
            topics=r["topics"],
            body=r["body"],
            max_body_windows=3,
        )
        total_requests += len(wins)
        total_chars += sum(len(t) + len(b) for t, b, _ in wins)
    est_tokens = max(1, total_chars // 4)
    est_usd = round((est_tokens / 1_000_000.0) * BATCH_USD_PER_1M_TOKENS, 4)
    return {
        "docs": len(records),
        "requests": total_requests,
        "estimatedTokens": est_tokens,
        "estimatedUsd": est_usd,
        "model": "gemini-embedding-2-001",
    }


def load_budget_module(budget_path: Path):
    import importlib.util

    if not budget_path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("fleet_gemini_budget", budget_path)
    if not spec or not spec.loader:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check_budget_and_gate(
    est_usd: float,
    *,
    cap_usd: float,
    budget_path: Path = DEFAULT_BUDGET_MODULE,
    budget_state: Path = Path.home() / ".local/state/gemini-api-budget",
    local_spend_file: Path | None = None,
) -> tuple[bool, str]:
    """Fail-closed check against METERED_LINK, daily cap, and shared $100/mo budget."""
    if METERED_LINK_MARKER.exists():
        return False, "METERED_LINK exists; refusing remote Batch upload"
    if not os.environ.get("GEMINI_API_KEY", "").strip():
        return False, "GEMINI_API_KEY missing; fail-closed"
    if not budget_state.is_dir():
        return False, f"shared budget state missing at {budget_state}; fail-closed"
    mod = load_budget_module(budget_path)
    if mod is None:
        return False, f"budget module missing at {budget_path}; fail-closed"

    today_spent = 0.0
    if local_spend_file and local_spend_file.is_file():
        try:
            doc = json.loads(local_spend_file.read_text(encoding="utf-8"))
            day = datetime.now(PERTH_TZ).strftime("%Y-%m-%d")
            today_spent = float((doc.get("days") or {}).get(day, 0.0))
        except Exception:
            return False, "corrupt local spend ledger; fail-closed"

    if today_spent + est_usd > cap_usd:
        return False, f"daily cap exceeded ({today_spent:.4f} + {est_usd:.4f} > {cap_usd:.4f})"

    snap = mod.compute_snapshot(budget_state=budget_state)
    rem = float(snap.get("remainingPoolUsd", 0.0))
    if est_usd > rem:
        return False, f"monthly pool insufficient ({est_usd:.4f} > {rem:.4f})"
    return True, f"ok (pool remaining ${rem:.2f}, daily cap ${cap_usd:.2f})"


def _atomic_write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as fh:
        tmp = Path(fh.name)
        try:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)


def _add_spend_entry(path: Path, day_str: str, usd: float, note: str, now_iso: str) -> None:
    doc: dict[str, Any] = {"days": {}, "log": []}
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                doc = loaded
        except Exception:
            doc = {"days": {}, "log": []}
    days = doc.setdefault("days", {})
    log = doc.setdefault("log", [])
    days[day_str] = round(max(0.0, float(days.get(day_str, 0.0)) + usd), 6)
    log.append({"at": now_iso, "day": day_str, "usd": round(usd, 6), "note": note})
    _atomic_write_json(path, doc)


def record_gemini_spend(
    usd: float,
    *,
    note: str,
    local_spend_file: Path,
    budget_path: Path = DEFAULT_BUDGET_MODULE,
    budget_state: Path = Path.home() / ".local/state/gemini-api-budget",
) -> None:
    now_utc = datetime.now(timezone.utc)
    now_iso = now_utc.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    day_str = now_utc.astimezone(PERTH_TZ).strftime("%Y-%m-%d")
    mod = load_budget_module(budget_path)
    if mod is not None:
        with mod.budget_locked(budget_state):
            _add_spend_entry(local_spend_file, day_str, usd, note, now_iso)
            _add_spend_entry(budget_state / "other-spend.json", day_str, usd, note, now_iso)
            return
    _add_spend_entry(local_spend_file, day_str, usd, note, now_iso)


def build_gemini_batch_shards(
    records: list[dict[str, Any]],
    state_dir: Path,
    *,
    shard_lines: int = GEMINI_SHARD_LINES,
    max_tokens: int = GEMINI_SHARD_MAX_TOKENS,
    limit: int | None = None,
) -> dict[str, Any]:
    """Write sharded mldev camelCase JSONL files and return prepared manifest metadata."""
    gdir = state_dir / "gemini"
    batch_dir = gdir / "batches"
    batch_dir.mkdir(parents=True, exist_ok=True)
    selected = records[: (limit or len(records))]
    max_lines = max(1, int(shard_lines))
    tok_cap = max(1000, int(max_tokens))

    shards: list[dict[str, Any]] = []
    shard_idx = 0
    lines_in_shard = 0
    chars_in_shard = 0
    fh = None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    current_path: Path | None = None

    def close_current() -> None:
        nonlocal fh, current_path, lines_in_shard, chars_in_shard, shard_idx
        if fh is not None and current_path is not None and lines_in_shard > 0:
            fh.close()
            est_tok = max(1, chars_in_shard // 4)
            est_usd = round((est_tok / 1_000_000.0) * BATCH_USD_PER_1M_TOKENS, 4)
            shards.append({
                "id": f"reader-{stamp}-s{shard_idx:03d}",
                "path": str(current_path),
                "requests": lines_in_shard,
                "estimatedTokens": est_tok,
                "estimatedUsd": est_usd,
            })
            shard_idx += 1
        elif fh is not None:
            fh.close()
        fh = None
        current_path = None
        lines_in_shard = 0
        chars_in_shard = 0

    total_requests = 0
    for r in selected:
        wins = build_multichunk_windows(
            title=r["title"],
            authors=r["authors"],
            genre=r["genre"],
            subgenre=r["subgenre"],
            description=r["description"],
            topics=r["topics"],
            body=r["body"],
            max_body_windows=3,
        )
        for idx, (t, b, _w) in enumerate(wins):
            prompt_text = f"title: {t[:120]} | text: {b}"
            need_rollover = (
                fh is None
                or lines_in_shard >= max_lines
                or (lines_in_shard > 0 and ((chars_in_shard + len(prompt_text)) // 4) >= tok_cap)
            )
            if need_rollover:
                close_current()
                current_path = batch_dir / f"shard-{shard_idx:03d}.jsonl"
                fh = current_path.open("w", encoding="utf-8")
            line = json.dumps({
                "key": f"{r['slug']}#{idx}",
                "request": {
                    "content": {"parts": [{"text": prompt_text}]},
                    "outputDimensionality": GEMINI_DIM,
                },
            }, ensure_ascii=False)
            fh.write(line + "\n")
            lines_in_shard += 1
            chars_in_shard += len(prompt_text)
            total_requests += 1

    close_current()
    prep = {
        "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "model": GEMINI_MODEL,
        "dims": GEMINI_DIM,
        "docs": len(selected),
        "requests": total_requests,
        "estimatedUsd": round(sum(s["estimatedUsd"] for s in shards), 4),
        "shards": shards,
    }
    _atomic_write_json(gdir / "prepared.json", prep)
    return prep


def _normalise_batch_state(state_obj: Any) -> str:
    raw = str(getattr(state_obj, "name", None) or state_obj or "UNKNOWN")
    if raw.startswith("JOB_STATE_"):
        return raw[len("JOB_STATE_") :]
    return raw.upper()


def _parse_gemini_result_line(line_obj: dict[str, Any]) -> tuple[str | None, list[float] | None, Any | None]:
    key = line_obj.get("key")
    key_str = str(key) if key is not None else None
    err = line_obj.get("error")
    if err is not None:
        return key_str, None, err
    candidates = [
        ((line_obj.get("response") or {}).get("embedding") or {}).get("values"),
        ((((line_obj.get("response") or {}).get("embeddings") or [None])[0]) or {}).get("values"),
        (line_obj.get("embedding") or {}).get("values"),
    ]
    for vals in candidates:
        if isinstance(vals, list) and vals:
            return key_str, [float(v) for v in vals], None
    return key_str, None, "missing_values"


def cmd_gemini(args: argparse.Namespace) -> int:
    state_dir = Path(args.state).expanduser()
    gdir = state_dir / "gemini"
    prep_path = gdir / "prepared.json"
    jobs_path = gdir / "jobs.json"
    spend_path = gdir / "spend.json"

    if args.action in ("plan", "cost", "build"):
        records = load_corpus_records(Path(args.corpus).expanduser(), state_dir / "canonical-ids.json")
        canonical_records = [r for r in records if r["canonicalId"]]
        if args.action in ("plan", "cost"):
            est = estimate_gemini_batch_cost(canonical_records[: (args.limit or len(canonical_records))])
            print(json.dumps(est, indent=2))
            return 0
        prep = build_gemini_batch_shards(
            canonical_records,
            state_dir,
            shard_lines=getattr(args, "shard_lines", GEMINI_SHARD_LINES),
            limit=args.limit,
        )
        print(json.dumps({k: v for k, v in prep.items() if k != "shards"} | {"shardCount": len(prep["shards"])}, indent=2))
        return 0

    if args.action == "submit":
        if not prep_path.is_file():
            records = load_corpus_records(Path(args.corpus).expanduser(), state_dir / "canonical-ids.json")
            canonical_records = [r for r in records if r["canonicalId"]]
            prep = build_gemini_batch_shards(
                canonical_records,
                state_dir,
                shard_lines=getattr(args, "shard_lines", GEMINI_SHARD_LINES),
                limit=args.limit,
            )
        else:
            prep = json.loads(prep_path.read_text(encoding="utf-8"))

        jobs_doc = json.loads(jobs_path.read_text(encoding="utf-8")) if jobs_path.is_file() else {"jobs": {}}
        jobs_map: dict[str, Any] = jobs_doc.setdefault("jobs", {})
        pending_shards = [s for s in prep.get("shards", []) if s["id"] not in jobs_map]
        est_usd = round(sum(float(s.get("estimatedUsd") or 0.0) for s in pending_shards), 4)

        ok, msg = check_budget_and_gate(est_usd, cap_usd=args.cap_usd, local_spend_file=spend_path)
        if args.dry_run:
            print(json.dumps({
                "dryRun": True,
                "gateOk": ok,
                "reason": msg,
                "pendingShards": len(pending_shards),
                "estimatedUsd": est_usd,
            }, indent=2))
            return 0
        if not ok:
            raise SystemExit(f"BLOCKED: {msg}")
        if not pending_shards:
            print(json.dumps({"status": "already-submitted", "jobs": len(jobs_map)}, indent=2))
            return 0

        from google import genai  # type: ignore
        from google.genai import types  # type: ignore

        client = genai.Client(api_key=os.environ["GEMINI_API_KEY"].strip())
        submitted_now: list[dict[str, Any]] = []
        wait_mode = bool(getattr(args, "wait", False))

        def refresh_active_tokens() -> int:
            active_tok = 0
            for rec in jobs_map.values():
                st = str(rec.get("state") or "")
                if st in ("SUCCEEDED", "FAILED", "CANCELLED", "EXPIRED"):
                    continue
                try:
                    j = client.batches.get(name=rec["remote_name"])
                    st = _normalise_batch_state(j.state)
                    rec["state"] = st
                    dest = getattr(getattr(j, "dest", None), "file_name", None)
                    if dest:
                        rec["dest_file"] = dest
                except Exception:
                    pass
                if st not in ("SUCCEEDED", "FAILED", "CANCELLED", "EXPIRED"):
                    active_tok += int(rec.get("estimatedTokens") or 0)
            _atomic_write_json(jobs_path, jobs_doc)
            return active_tok

        for idx, shard in enumerate(pending_shards):
            shard_tok = int(shard.get("estimatedTokens") or 0)
            while True:
                active_tok = refresh_active_tokens()
                if active_tok + shard_tok <= GEMINI_CONCURRENT_TOKEN_BUDGET or active_tok == 0:
                    break
                if not wait_mode:
                    print(json.dumps({
                        "submitted": len(submitted_now),
                        "paused": "concurrent_token_budget",
                        "activeTokens": active_tok,
                        "remainingShards": len(pending_shards) - idx,
                        "jobs": submitted_now,
                    }, indent=2))
                    return 0
                time.sleep(25)

            s_usd = float(shard["estimatedUsd"])
            uploaded = client.files.upload(
                file=shard["path"],
                config=types.UploadFileConfig(mime_type="application/jsonl", display_name=shard["id"]),
            )
            while True:
                try:
                    job = client.batches.create_embeddings(
                        model=GEMINI_MODEL,
                        src=types.EmbeddingsBatchJobSource(file_name=uploaded.name),
                        config=types.CreateEmbeddingsBatchJobConfig(display_name=shard["id"]),
                    )
                    break
                except Exception as exc:
                    if "429" in str(exc) or "RESOURCE_EXHAUSTED" in str(exc):
                        if not wait_mode:
                            print(json.dumps({
                                "submitted": len(submitted_now),
                                "paused": "429_concurrent_limit",
                                "remainingShards": len(pending_shards) - idx,
                                "jobs": submitted_now,
                            }, indent=2))
                            return 0
                        time.sleep(30)
                        refresh_active_tokens()
                        continue
                    raise
            rec = {
                "id": shard["id"],
                "remote_name": job.name,
                "input_file": uploaded.name,
                "shard": shard["path"],
                "requests": shard["requests"],
                "estimatedTokens": shard_tok,
                "est_usd": s_usd,
                "state": _normalise_batch_state(getattr(job, "state", "SUBMITTED")),
                "submitted_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            }
            jobs_map[shard["id"]] = rec
            _atomic_write_json(jobs_path, jobs_doc)
            record_gemini_spend(
                s_usd,
                note=f"cohort-reader {shard['id']} ({shard['requests']} reqs)",
                local_spend_file=spend_path,
            )
            submitted_now.append({"id": rec["id"], "remote_name": rec["remote_name"], "state": rec["state"], "est_usd": s_usd})

        if wait_mode:
            while any(str(r.get("state") or "") not in ("SUCCEEDED", "FAILED", "CANCELLED", "EXPIRED") for r in jobs_map.values()):
                time.sleep(25)
                refresh_active_tokens()
        print(json.dumps({"submitted": len(submitted_now), "jobs": submitted_now}, indent=2))
        return 0

    if args.action == "status":
        jobs_doc = json.loads(jobs_path.read_text(encoding="utf-8")) if jobs_path.is_file() else {"jobs": {}}
        jobs_map = jobs_doc.get("jobs", {})
        if not jobs_map:
            print(json.dumps({"jobs": []}, indent=2))
            return 0
        from google import genai  # type: ignore

        client = genai.Client(api_key=os.environ["GEMINI_API_KEY"].strip())
        summary = []
        for jid, rec in jobs_map.items():
            job = client.batches.get(name=rec["remote_name"])
            rec["state"] = _normalise_batch_state(job.state)
            dest = getattr(getattr(job, "dest", None), "file_name", None)
            if dest:
                rec["dest_file"] = dest
            summary.append({"id": jid, "remote_name": rec["remote_name"], "state": rec["state"], "requests": rec.get("requests"), "est_usd": rec.get("est_usd")})
        _atomic_write_json(jobs_path, jobs_doc)
        print(json.dumps({"jobs": summary}, indent=2))
        return 0

    if args.action == "collect":
        if not jobs_path.is_file():
            raise SystemExit("No Gemini jobs recorded yet.")
        jobs_doc = json.loads(jobs_path.read_text(encoding="utf-8"))
        jobs_map = jobs_doc.get("jobs", {})
        from google import genai  # type: ignore

        client = genai.Client(api_key=os.environ["GEMINI_API_KEY"].strip())
        chunks_by_slug: dict[str, dict[int, list[float]]] = {}
        collected_ids: list[str] = []
        for jid, rec in jobs_map.items():
            if rec.get("collected"):
                continue
            job = client.batches.get(name=rec["remote_name"])
            state = _normalise_batch_state(job.state)
            rec["state"] = state
            if state != "SUCCEEDED":
                continue
            dest = getattr(getattr(job, "dest", None), "file_name", None)
            if not dest:
                continue
            raw = client.files.download(file=dest)
            text = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else str(raw)
            for line in text.splitlines():
                if not line.strip():
                    continue
                k, vals, err = _parse_gemini_result_line(json.loads(line))
                if err is not None or vals is None or not k or "#" not in k:
                    continue
                slug, _, idx_s = k.rpartition("#")
                if idx_s.isdigit():
                    chunks_by_slug.setdefault(slug, {})[int(idx_s)] = vals
            rec["dest_file"] = dest
            collected_ids.append(jid)

        if not chunks_by_slug:
            _atomic_write_json(jobs_path, jobs_doc)
            print(json.dumps({"collected": 0, "reason": "no newly succeeded jobs"}, indent=2))
            return 0

        out_dir = state_dir / "vectors-gemini"
        existing = repair_tail(out_dir, GEMINI_DIM)
        done_slugs = {r["slug"] for r in existing}
        records_by_slug = {
            r["slug"]: r for r in load_corpus_records(Path(args.corpus).expanduser(), state_dir / "canonical-ids.json")
        }
        rows_out: list[dict[str, Any]] = []
        vecs_out: list[Any] = []
        for slug, idx_map in chunks_by_slug.items():
            if slug in done_slugs or slug not in records_by_slug:
                continue
            r = records_by_slug[slug]
            wins = build_multichunk_windows(
                title=r["title"],
                authors=r["authors"],
                genre=r["genre"],
                subgenre=r["subgenre"],
                description=r["description"],
                topics=r["topics"],
                body=r["body"],
                max_body_windows=3,
            )
            vecs = []
            weights = []
            for idx, (_t, _b, w) in enumerate(wins):
                if idx in idx_map:
                    vecs.append(idx_map[idx])
                    weights.append(w)
            if not vecs:
                continue
            pooled = pool_chunk_vectors(vecs, weights)
            rows_out.append({
                "slug": r["slug"],
                "canonicalId": r["canonicalId"],
                "title": r["title"][:180],
                "authors": r["authors"][:140],
                "year": r["year"],
                "kind": r["kind"],
                "genre": r["genre"],
                "description": r["description"][:280],
            })
            vecs_out.append(pooled)
        if rows_out:
            append_vectors(out_dir, rows_out, vecs_out)
        for jid in collected_ids:
            jobs_map[jid]["collected"] = True
        _atomic_write_json(jobs_path, jobs_doc)
        print(json.dumps({"collectedJobs": len(collected_ids), "addedDocs": len(rows_out), "totalDocs": len(existing) + len(rows_out)}, indent=2))
        return 0

    return 0


def cmd_export_space(args: argparse.Namespace) -> int:
    import numpy as np  # type: ignore

    state_dir = Path(args.state).expanduser()
    gemma_dir = state_dir / "vectors-gemma"
    rows = repair_tail(gemma_dir, GEMMA_DIM)
    if not rows:
        raise SystemExit(f"No Gemma vectors found under {gemma_dir}")
    mat = np.fromfile(gemma_dir / "docs.f32", dtype="<f4").reshape(len(rows), GEMMA_DIM)
    mat = l2_normalize(mat)

    centered = mat - mat.mean(axis=0, keepdims=True)
    _, _, vt = np.linalg.svd(centered, full_matrices=False)
    k32 = min(32, vt.shape[0])
    pca32 = centered @ vt[:k32].T
    if k32 < 32:
        pca32 = np.pad(pca32, ((0, 0), (0, 32 - k32)))
    max_abs = float(np.max(np.abs(pca32))) or 1.0
    pca32_i8 = np.clip(np.round((pca32 / max_abs) * 127.0), -127, 127).astype(np.int8)

    u2, s2, _ = np.linalg.svd(centered, full_matrices=False)
    k2 = min(2, u2.shape[1])
    xy = u2[:, :k2] * s2[:k2]
    if k2 < 2:
        xy = np.pad(xy, ((0, 0), (0, 2 - k2)))
    for col in range(2):
        span = max(float(np.max(np.abs(xy[:, col]))), 1e-6)
        xy[:, col] = (xy[:, col] / span) * 0.86

    sims = mat @ mat.T
    items_out: list[dict[str, Any]] = []
    for i, r in enumerate(rows):
        scores = sims[i]
        order = np.argsort(-scores)
        nbs = []
        for j in order:
            if j == i:
                continue
            nbs.append({
                "slug": rows[j]["slug"],
                "workId": rows[j].get("canonicalId") or rows[j]["slug"],
                "sim": round(float(scores[j]), 4),
            })
            if len(nbs) >= 12:
                break
        fp16_b64 = base64.b64encode(mat[i].astype(np.float16).tobytes()).decode("ascii")
        items_out.append({
            "slug": r["slug"],
            "canonicalId": r.get("canonicalId"),
            "title": r.get("title", ""),
            "creator": r.get("authors", "Unknown"),
            "year": int(str(r.get("year") or "2026")[:4]) if str(r.get("year") or "")[:4].isdigit() else 2026,
            "kind": f"{r.get('kind', 'paper')} · {r.get('genre', 'library')}",
            "summary": r.get("description", ""),
            "x": round(float(xy[i, 0]), 4),
            "y": round(float(xy[i, 1]), 4),
            "vec32": [int(v) for v in pca32_i8[i].tolist()],
            "vecFp16B64": fp16_b64,
            "neighbours": nbs,
        })

    out_path = Path(args.out).expanduser() if args.out else (state_dir / "reader-space.json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"model": "embeddinggemma-2", "dims": GEMMA_DIM, "items": items_out}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, out_path)
    print(f"Wrote local reader space ({len(items_out)} works) -> {out_path}")
    return 0


def scrub_text(text: str, max_len: int = 240) -> str:
    cleaned = FORBIDDEN_PATH_RE.sub("[redacted]", str(text or ""))
    cleaned = FORBIDDEN_EXT_RE.sub("", cleaned)
    return cleaned.strip()[:max_len]


def assert_payload_clean(obj: Any, path: str = "root") -> None:
    if obj is None or isinstance(obj, (bool, int, float)):
        return
    if isinstance(obj, str):
        if FORBIDDEN_PATH_RE.search(obj):
            raise ValueError(f"Forbidden path leak at {path}")
        if FORBIDDEN_EXT_RE.search(obj):
            raise ValueError(f"Forbidden media/doc filename extension at {path}")
        if not path.endswith(".recipeHash") and BARE_HASH_RE.match(obj.strip()):
            raise ValueError(f"Forbidden raw hex hash at {path}")
        return
    if isinstance(obj, list):
        for i, item in enumerate(obj):
            assert_payload_clean(item, f"{path}[{i}]")
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.lower() in {"filepath", "relativepath", "localpath", "sha256", "infohash", "household", "viewername"}:
                raise ValueError(f"Forbidden private field '{k}' at {path}")
            assert_payload_clean(v, f"{path}.{k}")


def _find_node() -> str:
    found = shutil.which("node")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/node", "/usr/local/bin/node"):
        if Path(candidate).is_file():
            return candidate
    raise FileNotFoundError("node binary not found in PATH or standard Homebrew locations")


def get_or_create_identity(identity_file: Path) -> dict[str, str]:
    if identity_file.is_file():
        return json.loads(identity_file.read_text(encoding="utf-8"))
    identity_file.parent.mkdir(parents=True, exist_ok=True)
    script = (
        "const c=require('node:crypto');"
        "const seed=c.randomBytes(32);"
        "const pkcs8=Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]);"
        "const k=c.createPrivateKey({key:pkcs8,format:'der',type:'pkcs8'});"
        "const spki=c.createPublicKey(k).export({format:'der',type:'spki'});"
        "process.stdout.write(JSON.stringify({"
        "issuer:'ed25519:'+spki.subarray(-32).toString('base64url'),"
        "privateSeedB64Url:seed.toString('base64url')"
        "}));"
    )
    ident = json.loads(subprocess.check_output([_find_node(), "-e", script], text=True))
    identity_file.write_text(json.dumps(ident, indent=2) + "\n", encoding="utf-8")
    os.chmod(identity_file, 0o600)
    return ident


def sign_envelope(unsigned_obj: dict[str, Any], private_seed_b64url: str) -> dict[str, Any]:
    payload = json.dumps({"seed": private_seed_b64url, "obj": unsigned_obj}, ensure_ascii=False)
    script = (
        "const fs=require('node:fs'),c=require('node:crypto');"
        "function cj(v){if(v===null||typeof v!=='object')return JSON.stringify(v);"
        "if(Array.isArray(v))return '['+v.map(cj).join(',')+']';"
        "return '{'+Object.keys(v).filter(k=>v[k]!==undefined).sort().map(k=>JSON.stringify(k)+':'+cj(v[k])).join(',')+'}';}"
        "const inp=JSON.parse(fs.readFileSync(0,'utf8'));"
        "const seed=Buffer.from(inp.seed,'base64url');"
        "const pkcs8=Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]);"
        "const k=c.createPrivateKey({key:pkcs8,format:'der',type:'pkcs8'});"
        "const sig=c.sign(null,Buffer.from(cj(inp.obj),'utf8'),k);"
        "process.stdout.write(sig.toString('base64url'));"
    )
    sig = subprocess.check_output([_find_node(), "-e", script], input=payload, text=True).strip()
    signed = dict(unsigned_obj)
    signed["signature"] = sig
    assert_payload_clean(signed)
    return signed


def export_manifold_bundle(
    space_path: Path,
    out_path: Path,
    *,
    identity_file: Path,
    handle: str = "local.reader",
    limit: int | None = None,
) -> tuple[dict[str, Any], int]:
    space = json.loads(space_path.read_text(encoding="utf-8"))
    entries = space.get("items", [])
    canon_by_slug: dict[str, str] = {}
    for row in entries:
        cid = str(row.get("canonicalId") or "").strip()
        if cid and CANONICAL_RE.match(cid) and not FORBIDDEN_EXT_RE.search(cid) and not FORBIDDEN_PATH_RE.search(cid):
            canon_by_slug[str(row.get("slug") or cid)] = cid

    exported: list[dict[str, Any]] = []
    seen: set[str] = set()
    skipped = 0
    for row in entries:
        cid = str(row.get("canonicalId") or "").strip()
        if not cid or not CANONICAL_RE.match(cid) or cid in seen:
            skipped += 1
            continue
        seen.add(cid)
        nbs = []
        for nb in row.get("neighbours", [])[:12]:
            nb_cid = str(nb.get("workId") or "")
            if not CANONICAL_RE.match(nb_cid):
                nb_cid = canon_by_slug.get(str(nb.get("slug") or ""), "")
            if nb_cid and nb_cid != cid and CANONICAL_RE.match(nb_cid):
                nbs.append({"workId": nb_cid, "sim": round(float(nb.get("sim") or 0), 4)})
        item: dict[str, Any] = {
            "workId": cid,
            "domain": "reader",
            "title": scrub_text(row.get("title") or cid, 180),
            "creator": scrub_text(row.get("creator") or "Unknown", 140),
            "year": int(row.get("year") or 2026),
            "kind": scrub_text(row.get("kind") or "reader", 60),
            "summary": scrub_text(row.get("summary") or "", 300),
            "neighbours": nbs,
        }
        if isinstance(row.get("vec32"), list) and len(row["vec32"]) == 32:
            item["vec32"] = [int(v) for v in row["vec32"]]
        if isinstance(row.get("vecFp16B64"), str) and row["vecFp16B64"]:
            item["vecFp16B64"] = row["vecFp16B64"]
        exported.append(item)
        if limit and len(exported) >= limit:
            break

    ident = get_or_create_identity(identity_file)
    unsigned = {
        "issuer": ident["issuer"],
        "handle": handle,
        "domain": "reader",
        "modelId": "embeddinggemma-2",
        "recipeHash": "reader-multichunk-v1-mlx768",
        "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "items": exported,
    }
    signed = sign_envelope(unsigned, ident["privateSeedB64Url"])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(signed, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return signed, skipped


def cmd_export_manifold(args: argparse.Namespace) -> int:
    state_dir = Path(args.state).expanduser()
    space_path = Path(args.space).expanduser() if args.space else (state_dir / "reader-space.json")
    out_path = Path(args.out).expanduser()
    ident_file = Path(args.identity).expanduser()
    signed, skipped = export_manifold_bundle(
        space_path,
        out_path,
        identity_file=ident_file,
        handle=args.handle,
        limit=args.limit,
    )
    print(f"Exported {len(signed['items'])} canonical Reader works to {out_path} ({skipped} private/unmapped omitted).")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Cohort Reader dual-map embedding pipeline")
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gemma", help="Run local MLX EmbeddingGemma 2 (768-D, $0)")
    g.add_argument("--corpus", default=str(DEFAULT_CORPUS_DIR))
    g.add_argument("--state", default=str(DEFAULT_STATE_DIR))
    g.add_argument("--model", default=DEFAULT_GEMMA_MODEL)
    g.add_argument("--limit", type=int, default=None)
    g.add_argument("--batch-docs", type=int, default=25)
    g.add_argument("--max-minutes", type=float, default=None)
    g.add_argument("--canonical-only", action="store_true")
    g.set_defaults(func=cmd_gemma)

    gm = sub.add_parser("gemini", help="Plan/cost/build/submit/status/collect Gemini 3072-D Batch API jobs")
    gm.add_argument("action", choices=["plan", "cost", "build", "submit", "status", "collect"])
    gm.add_argument("--corpus", default=str(DEFAULT_CORPUS_DIR))
    gm.add_argument("--state", default=str(DEFAULT_STATE_DIR))
    gm.add_argument("--cap-usd", type=float, default=5.0)
    gm.add_argument("--limit", type=int, default=None)
    gm.add_argument("--shard-lines", type=int, default=GEMINI_SHARD_LINES)
    gm.add_argument("--wait", action="store_true")
    gm.add_argument("--dry-run", action="store_true")
    gm.set_defaults(func=cmd_gemini)

    es = sub.add_parser("export-space", help="Build reader-space.json for Home Library Server")
    es.add_argument("--state", default=str(DEFAULT_STATE_DIR))
    es.add_argument("--out", default=None)
    es.set_defaults(func=cmd_export_space)

    em = sub.add_parser("export-manifold", help="Fail-closed Ed25519 export of canonical Reader coordinates")
    em.add_argument("--state", default=str(DEFAULT_STATE_DIR))
    em.add_argument("--space", default=None)
    em.add_argument("--identity", default="~/.local/state/manifold/contributor-key.json")
    em.add_argument("--handle", default="local.reader")
    em.add_argument("--limit", type=int, default=None)
    em.add_argument("--out", required=True)
    em.set_defaults(func=cmd_export_manifold)

    return p


if __name__ == "__main__":
    parser = build_parser()
    ns = parser.parse_args()
    raise SystemExit(ns.func(ns))
