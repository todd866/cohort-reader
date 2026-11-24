# Architecture

## SwiftPM Module Dependency Graph

```text
App (CohortReader-iOS / CohortReader-macOS) ──┐
SnapshotTool (macOS headless)              ────┴──► ReaderKit (SwiftUI UI + Umbrella)
                                                        │
        ┌──────────────┬──────────────┬─────────────────┼──────────────┐
        ▼              ▼              ▼                 ▼              ▼
    EPUBEngine     PDFEngine    ReaderStorage     ManifoldClient  HomeLibraryClient
        │              │              │                 │              │
        └──────────────┴──────────────┴─────────────────┴──────────────┘
                                      │
                                      ▼
                                 ReaderModel
```

- `EPUBEngine` links system `zlib` only (raw DEFLATE `inflateInit2_`/`deflateInit2_` with `-MAX_WBITS`).
- `PDFEngine` uses Apple `PDFKit` (`PDFDocument`).
- `ReaderStorage` links system `sqlite3` (WAL + FTS5) and manages `Documents/books/` + `Documents/notes/` offline cache with `isExcludedFromBackup = true`.
- `ManifoldClient` uses `CryptoKit` (`SHA256`) for k-anonymous 2-hex prefix shard lookups and local `vec32` cosine scoring.
- `HomeLibraryClient` uses `Security.framework` (Keychain) + `URLSession` (`HTTPCookieStorage.shared`) with `Range: bytes=...` resumable book caching.

## Monotonic Exact-Word Progress Sync

`ReadingLocator` records `(spine, fraction, wordOffset, pageIndex, updatedAt)` so positions transfer cleanly across different screen sizes (iPhone vs Mac) without pixel drift. Merging a remote locator applies monotonic Last-Write-Wins on `updatedAt`, queuing local updates into SQLite `pending_sync_outbox` while offline and flushing automatically upon reconnect.
