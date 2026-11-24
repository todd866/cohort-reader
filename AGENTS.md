# AGENTS.md — Coding Agent Guide for Cohort Reader

Welcome. Cohort Reader is a universal Swift 6 iOS + macOS application structured into dependency-light SwiftPM modules so agents and contributors can verify changes headlessly without launching GUI windows.

## Fast Verification Loop

1. **SwiftPM library & integration tests (offline, fastest):**
   ```sh
   swift test
   ```
2. **Headless light & dark UI snapshots (`iPhone 390x844` and `macOS 1280x800`):**
   ```sh
   swift run SnapshotTool /tmp/cohort-reader-shots
   ```
   Inspect rendered PNGs visually to verify zero clipping, crisp light/dark contrast, and aligned tabular figures.
3. **Xcode iOS + macOS compilation:**
   ```sh
   xcodegen generate
   xcodebuild -project CohortReader.xcodeproj -scheme CohortReader-iOS -destination 'platform=iOS Simulator,name=iPhone Duo' CODE_SIGNING_ALLOWED=NO build
   xcodebuild -project CohortReader.xcodeproj -scheme CohortReader-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
   ```
4. **BYO server & pipeline tests:**
   ```sh
   python3 -m unittest discover -s examples/byo-backend -v
   python3 -m unittest discover -s tools -v
   ```

## Module Boundaries

- `ReaderModel`: pure `Sendable`/`Codable`/`Hashable` domain models, monotonic LWW `ReadingLocator` merge, and offline open-access showcase catalog. No SQLite, no UI.
- `EPUBEngine`: clean-room MIT ZIP reader/writer (`zlib` only), OPF/NAV/NCX parser, chapter HTML composer, and verbatim margin-note anchor folder.
- `PDFEngine`: native `PDFKit` metadata/outline extractor, canonical ID detector (`doi:`, `isbn:` Mod-10 checked, `arxiv:`), and thumbnail renderer.
- `ReaderStorage`: actor-isolated WAL SQLite3 + FTS5 store, offline file cache (`isExcludedFromBackup = true`), pending progress outbox, and Cohort handoff payload builder.
- `ManifoldClient`: k-anonymous 2-hex prefix shard client (`CryptoKit` SHA-256), Ed25519 lens ranking over `vec32`, and Open Access URL resolver.
- `HomeLibraryClient`: Keychain-backed HTTPS cookie client implementing the 6 Home Library Server endpoints with HTTP `206` range resume.
- `ReaderKit`: umbrella module exporting core modules + `ReaderViewModel` + single-viewport Instrument UX SwiftUI screens (`ShelfView`, `ReaderPaneView`, `ManifoldMapView`, `SearchLibraryView`, `SettingsSheet`).

## Rules

- **Clean-room MIT only:** never import GPL/AGPL code (e.g., Okular, Poppler, MuPDF). Use Apple `PDFKit`, `WebKit`, and system `zlib` + `sqlite3`.
- **Strict Swift 6 concurrency:** keep exported types `Sendable`; isolate SQLite connections inside `actor ReaderStore`.
- **Zero copyrighted media in repo:** only metadata, public-domain showcase coordinates, and clean-room code enter the public tree.
- **Never launch a visible simulator or app window during automated QA.**
