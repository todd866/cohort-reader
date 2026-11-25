# Bring-Your-Own Home Library Backend Spec

**Cohort Reader** ships as a thin native client (iOS & macOS) over an open-access public-domain showcase and shared [Manifold](https://manifold-chi.vercel.app) coordinates. When you want to read your own personal books and papers across devices, **you and your AI agent run your own Home Library Server** while Manifold distributes only canonical coordinates and signed Reading Lenses.

A zero-dependency Python 3 reference implementation lives at [`examples/byo-backend/server.py`](../examples/byo-backend/server.py).

## Wire Contract (`HomeLibraryClient`)

The native app stores your server passphrase in the system Keychain, authenticates via `POST /api/login` (`HTTPCookieStorage`), and caches selected books + margin notes locally for airplane-mode reading.

### 1. `POST /api/login`

Authenticate and receive an `HttpOnly` session cookie.

Request:
```json
{
  "pass": "your-server-passphrase",
  "name": "Cohort Reader"
}
```
Response (`200 OK`): `{ "name": "My Home Library", "count": 420 }`. Return `401 Unauthorized` on mismatch.

### 2. `GET /api/home`

Return curated shelves (`readingNow`, focus shelves, recently added) and canonical library items. Every tile requires non-null string `id`, `title`, and `author`.

```json
{
  "serverName": "My Home Library",
  "shelves": [
    {
      "id": "reading",
      "title": "Reading Now",
      "itemIds": ["gutenberg-84"]
    }
  ],
  "items": [
    {
      "id": "gutenberg-84",
      "canonicalId": "gutenberg:84",
      "title": "Frankenstein; or, The Modern Prometheus",
      "author": "Mary Shelley",
      "year": 1818,
      "format": "epub",
      "genre": "Fiction",
      "subgenre": "Gothic Sci-Fi",
      "summary": "...",
      "bytes": 412000,
      "hasCover": true,
      "notesVersion": "v1",
      "locator": {
        "spine": 4,
        "fraction": 0.31,
        "wordOffset": 1420,
        "updatedAt": "2026-11-24T06:00:00Z"
      },
      "point": { "x": 0.14, "y": -0.32 }
    }
  ]
}
```

### 3. `GET /api/search?q=<query>&limit=30`

Search the personal library via FTS5, semantic vectors, or hybrid rank fusion. Returns `{ "items": [ ...same item schema as /api/home... ] }`.

### 4. `GET /api/book/<id>` (and `HEAD /api/book/<id>`)

Stream the `.epub` or `.pdf` bytes for `<id>`.

- Require session cookie (`401` if unauthenticated).
- Support `Accept-Ranges: bytes` and HTTP `206 Partial Content` (`Content-Range: bytes <start>-<end>/<total>`) for resumable large-PDF/EPUB caching over mobile connections.
- Confine `<id>` strictly to known catalog IDs; never resolve raw filesystem paths or `..` segments.

### 5. `GET /api/cover/<id>`

Serve cover artwork (`.jpg`/`.png`/`.webp`) or `404` when none exists (the client renders a clean modernist typographic cover automatically).

### 6. `GET /api/notes/<id>` and `GET /api/notes/<id>/<asset>`

Return offline-cacheable margin notes (`{ "notes": [ ... ] }`) matching the schema:
`id`, `spine` (int), `anchor` (verbatim folded text phrase), `kind`, `label`, `note`, `source`, `credit`, `image` (asset filename or null), `map` (asset filename or null).

### 7. `POST /api/progress`

Persist monotonic reading locators and sessions from the device.

Request:
```json
{
  "events": [
    {
      "bookId": "gutenberg-84",
      "canonicalId": "gutenberg:84",
      "spine": 5,
      "fraction": 0.42,
      "wordOffset": 2180,
      "pageIndex": null,
      "updatedAt": "2026-11-24T06:12:00Z",
      "readingSeconds": 480
    }
  ]
}
```
Response (`200 OK`): `{ "accepted": 1, "locators": { "gutenberg-84": { ...authoritative latest locator... } } }`.

## K-Anonymous Manifold Shard Join

To enrich your private books and papers without revealing your filenames or reading list:

1. Extract `isbn:`, `doi:`, `pmid:`, `arxiv:`, `ol:`, or `gutenberg:` locally from OPF metadata or PDF front-matter.
2. Compute `prefix = sha256(workId)[:2]` (lowercase hex).
3. Request `GET https://manifold-chi.vercel.app/api/v1/shard/<prefix>?domain=reader` and join vectors locally in memory.

For the PaperLibrary service on the M2, `tailscale serve --bg --https=8445 http://127.0.0.1:8696` exposes the loopback server to the tailnet. Its passphrase is configured in `~/.config/cohort-reader/server.env` (mode 600).
