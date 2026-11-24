# Cohort Reader (iOS & macOS)

**A thin, clean-room MIT native EPUB & PDF reader built on open Manifold coordinates, signed Reading Lenses, offline margin notes, and your own AI-built Home Library backend.**

Cohort Reader distributes **zero copyrighted books**. Cold launches work immediately offline with open-access public-domain showcase editions, k-anonymous [Manifold](https://manifold-chi.vercel.app) embeddings (`reader` domain), and Ed25519-signed Reading Lenses. When you want your full personal library on your phone and Mac, connect your own self-hosted backend (`docs/BYO-BACKEND.md`) or import local `.epub` / `.pdf` files via `Files.app`.

## Three-Layer Ecosystem

1. **Open Coordinates & Lenses (`ManifoldClient`):** Pulls 1/256th k-anonymous hex shards (`GET /api/v1/shard/:prefix?domain=reader`) and signed Reading Lenses (`isbn:`, `ol:`, `gutenberg:`, `arxiv:`, `doi:`, `pmid:`, `wikidata:`, `ia:`) without ever disclosing your library inventory.
2. **Thin Native Client (`ReaderKit`, `EPUBEngine`, `PDFEngine`, `ReaderStorage`):**
   - **Native PDF (`PDFKit`) & clean-room EPUB (`zlib` + `WKWebView`):** No GPL dependencies. Paper, Sepia, and Ink reading themes, typography controls, and tabular reading telemetry.
   - **Offline Margin Notes:** Anchored verbatim passages inside nonfiction/science chapters open Wikipedia context and Natural Earth locator maps offline.
   - **Exact-Word Locator Sync:** Monotonic `{spine, fraction, wordOffset, updatedAt}` merge with 1-tap offline caching (`isExcludedFromBackup = true`) for flights and instant local storage eviction.
   - **Cohort Handoff:** Send any highlight or passage straight into [Cohort](https://cohort.md) (`cohort://draft?...`) as an active-recall card seed, and inspect cross-domain resonances between books, papers, and USMLE/clinical concepts.
3. **You + Your AI Backend (`examples/byo-backend/`):** Zero-dependency Python starter server turning any folder of `.epub`/`.pdf` files into a range-streaming, passphrase-protected Home Library Server.

## Quick Start

```sh
# 1. Run SwiftPM unit & integration tests (offline, zero external deps)
swift test

# 2. Render headless light & dark SwiftUI UI snapshots (iPhone 390x844 + macOS 1280x800)
swift run SnapshotTool /tmp/cohort-reader-shots

# 3. Generate Xcode project and build universal iOS + macOS targets
xcodegen generate
xcodebuild -project CohortReader.xcodeproj -scheme CohortReader-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project CohortReader.xcodeproj -scheme CohortReader-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# 4. Run the reference BYO Home Library server & tests
python3 -m unittest discover -s examples/byo-backend -v
python3 examples/byo-backend/server.py --books-dir ~/Books --pass "choose-a-strong-passphrase"
```

## Architecture & Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — SwiftPM module graph & clean-room boundaries
- [`docs/BYO-BACKEND.md`](docs/BYO-BACKEND.md) — Home Library HTTP contract & k-anonymous Manifold enrichment
- [`AGENTS.md`](AGENTS.md) — Contributor & coding agent verification loop

## License

MIT — see [`LICENSE`](LICENSE).
