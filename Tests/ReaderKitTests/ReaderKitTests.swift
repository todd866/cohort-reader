import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SwiftUI
import Testing
@testable import EPUBEngine
@testable import HomeLibraryClient
@testable import ManifoldClient
@testable import PDFEngine
@testable import ReaderKit
@testable import ReaderModel
@testable import ReaderStorage

@Suite("CohortReader Core")
struct ReaderKitTests {
    @Test("Sample EPUB round-trip parses OPF, NAV TOC, canonical ID, and chapters")
    func epubRoundTrip() throws {
        let epubData = try SampleShowcaseEPUB.buildFrankensteinSampleData()
        let doc = try EPUBParser.parse(data: epubData)

        #expect(doc.title == "Frankenstein; or, The Modern Prometheus")
        #expect(doc.author == "Mary Wollstonecraft Shelley")
        #expect(doc.canonicalId == "gutenberg:84")
        #expect(doc.spineHrefs.count == 2)
        #expect(doc.toc.count == 2)

        let ch0 = try #require(doc.chapter(at: 0))
        #expect(ch0.title.contains("Letter I"))
        #expect(ch0.plainText.contains("St. Petersburgh"))
        #expect(ch0.wordCount > 40)

        let hits = MarginNoteHighlighter.matchingNotes(inText: ch0.plainText, notes: ShowcaseCatalog.sampleMarginNotes)
        #expect(hits.map(\.id).contains("note-petersburgh"))
    }

    @Test("ZIPArchive rejects path traversal entries")
    func zipRejectsTraversal() throws {
        #expect(throws: ZipError.self) {
            _ = try ZIPArchive.write([
                ZIPArchive.Entry(path: "../etc/passwd", data: Data("nope".utf8)),
            ])
        }
    }

    @Test("MarginNoteHighlighter folds curly punctuation and collapses whitespace")
    func marginFolding() {
        let raw = "In \u{201C}St.\u{00A0}Petersburgh\u{2014}17\u{201D}  ice"
        let folded = MarginNoteHighlighter.fold(raw)
        #expect(folded == "In \"St. Petersburgh-17\" ice")
    }

    @Test("CanonicalIDNormalizer validates ISBN-13 check digits and rejects corrupt ones")
    func isbnValidation() {
        #expect(CanonicalIDNormalizer.isValidISBN13("9780754615903") == true)
        #expect(CanonicalIDNormalizer.isValidISBN13("9780754615904") == false)
        #expect(CanonicalIDNormalizer.extractCanonicalId(from: "ISBN 978-0-691-14052-0") == "isbn:9780691140520")
        #expect(CanonicalIDNormalizer.extractCanonicalId(from: "arXiv:1706.03762v5") == "arxiv:1706.03762v5")
        #expect(CanonicalIDNormalizer.extractCanonicalId(from: "DOI: 10.1038/nrn2787.") == "doi:10.1038/nrn2787")
    }

    @Test("PDFInspector extracts metadata, canonical DOI, and maps page fractions")
    func pdfInspection() throws {
        let doc = PDFDocument()
        let page = PDFPage()
        doc.insert(page, at: 0)
        doc.insert(PDFPage(), at: 1)
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Active Inference Study",
            PDFDocumentAttribute.authorAttribute: "Karl Friston",
        ]
        let bytes = try #require(doc.dataRepresentation())
        let meta = try #require(PDFInspector.inspect(data: bytes, fallbackTitle: "Fallback"))
        #expect(meta.title == "Active Inference Study")
        #expect(meta.author == "Karl Friston")
        #expect(meta.pageCount == 2)
        #expect(PDFInspector.fraction(forPage: 1, pageCount: 2) == 1.0)
        #expect(PDFInspector.pageIndex(forFraction: 1.0, pageCount: 2) == 1)
    }

    @Test("ReaderStore FTS5 search, monotonic LWW locators, offline cache, and eviction")
    func storeLifecycle() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let store = try ReaderStore(dbPath: tmpDir.appendingPathComponent("test.sqlite").path, cacheRoot: tmpDir)
        let b1 = BookItem(
            id: "book-1",
            canonicalId: "doi:10.1038/nrn2787",
            title: "The Free-Energy Principle",
            author: "Karl Friston",
            year: 2010,
            format: .pdf,
            source: .homeServer,
            genre: "Neuroscience",
            summary: "Variational free energy minimization in biological brains."
        )
        try await store.upsertBooks([b1])

        let hits = try await store.searchBooks(query: "variational energy")
        #expect(hits.count == 1)
        #expect(hits.first?.id == "book-1")

        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let newer = try await store.saveLocator(
            bookId: "book-1",
            locator: ReadingLocator(spine: 3, fraction: 0.45, wordOffset: 800, updatedAt: t2),
            enqueueSync: true
        )
        #expect(newer.spine == 3)
        // Older timestamp must not overwrite newer position
        let staleMerge = try await store.saveLocator(
            bookId: "book-1",
            locator: ReadingLocator(spine: 1, fraction: 0.1, wordOffset: 50, updatedAt: t1),
            enqueueSync: false
        )
        #expect(staleMerge.spine == 3)
        #expect(staleMerge.fraction == 0.45)

        let outbox = try await store.pendingSyncEvents()
        #expect(outbox.count == 1)
        try await store.markSyncEventsDelivered(ids: outbox.map(\.id))
        #expect((try await store.pendingSyncEvents()).isEmpty)

        let epubData = try SampleShowcaseEPUB.buildFrankensteinSampleData()
        let cachedURL = try await store.storeOfflineBookData(epubData, bookId: "book-1", format: .epub)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(await store.cachedBookBytes() == Int64(epubData.count))

        try await store.evictOfflineBook(bookId: "book-1")
        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
        #expect(await store.cachedBookBytes() == 0)
    }

    @Test("Manifold k-anonymous shard prefix, lens ranking, and OpenAccessResolver")
    func manifoldMathAndShard() {
        // sha256("gutenberg:84")[:2] == "0a"
        #expect(ManifoldReaderClient.workShardPrefix("gutenberg:84") == "0a")
        #expect(OpenAccessResolver.directDownloadURL(for: "gutenberg:84")?.absoluteString == "https://www.gutenberg.org/ebooks/84.epub3.images")
        #expect(OpenAccessResolver.directDownloadURL(for: "arxiv:1706.03762")?.absoluteString == "https://arxiv.org/pdf/1706.03762.pdf")

        let lens = ShowcaseCatalog.lenses.first(where: { $0.id == "lens:reader:systems-and-science" })!
        let ranked = LensRanker.rank(works: ShowcaseCatalog.works, lens: lens)
        #expect(!ranked.isEmpty)
        let topIds = Set(ranked.prefix(4).map(\.work.workId))
        #expect(topIds.contains("doi:10.1038/nrn2787"))
    }

    @Test("HomeLibraryClient parses catalog, Range 206 download, notes, and progress")
    func homeLibraryMockRoundTrip() async throws {
        let epubBytes = try SampleShowcaseEPUB.buildFrankensteinSampleData()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHomeURLProtocol.self]
        MockHomeURLProtocol.payloadBytes = epubBytes
        let session = URLSession(configuration: config)

        let ack = try await HomeLibraryClient.signIn(baseURL: "https://mock.local", password: "secret", session: session)
        #expect(ack == "Mock Home")

        let home = try await HomeLibraryClient.fetchHome(baseURL: "https://mock.local", session: session)
        #expect(home.items.count == 1)
        #expect(home.items[0].canonicalId == "gutenberg:84")

        let prefix = Data(epubBytes.prefix(100))
        let merged = try await HomeLibraryClient.downloadBook(baseURL: "https://mock.local", bookId: "gutenberg-84", existingPrefix: prefix, session: session)
        #expect(merged == epubBytes)

        let notes = try await HomeLibraryClient.fetchMarginNotes(baseURL: "https://mock.local", bookId: "gutenberg-84", session: session)
        #expect(notes.count == 1)

        let pushed = try await HomeLibraryClient.pushProgress(
            baseURL: "https://mock.local",
            events: [PendingProgressEvent(bookId: "gutenberg-84", spine: 1, fraction: 0.5, readingSeconds: 30)],
            session: session
        )
        #expect(pushed == 1)
    }

    @Test("ManifoldReaderClient strictly filters works, lenses, and shards to domain == reader")
    func manifoldFiltersReaderDomainOnly() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockManifoldURLProtocol.self]
        let session = URLSession(configuration: config)

        let snap = try await ManifoldReaderClient.fetchSnapshot(hubBase: "https://mock-manifold.local", session: session)
        #expect(snap.works.count == 1)
        #expect(snap.works.first?.workId == "gutenberg:84")
        #expect(snap.lenses.count == 1)
        #expect(snap.lenses.first?.id == "lens:reader:systems")

        let shard = try await ManifoldReaderClient.fetchShard(prefix: "0a", hubBase: "https://mock-manifold.local", session: session)
        #expect(shard.works.map(\.workId) == ["gutenberg:84"])
    }

    @Test("AssetImageCache.downsampleCGImage shrinks large PNGs off-thread with aspect preserved")
    func imageIODownsampleCover() throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(
            CGContext(
                data: nil,
                width: 128,
                height: 192,
                bitsPerComponent: 8,
                bytesPerRow: 128 * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        ctx.setFillColor(red: 0.16, green: 0.34, blue: 0.56, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 192))
        let srcImage = try #require(ctx.makeImage())

        let pngBuf = try #require(CFDataCreateMutable(nil, 0))
        let dest = try #require(CGImageDestinationCreateWithData(pngBuf, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, srcImage, nil)
        #expect(CGImageDestinationFinalize(dest))

        let thumb = try #require(AssetImageCache.downsampleCGImage(data: pngBuf as Data, maxPixelSize: 64))
        #expect(thumb.width <= 64)
        #expect(thumb.height == 64)
        #expect(thumb.width < thumb.height)
    }

    @Test("Wishlist persistence, discovery ownership matching, and auto-download priority")
    @MainActor
    func discoveryAndAutoDownloadPriority() async throws {
        let store = try ReaderStore(dbPath: ":memory:")
        try await store.setWishlisted(workId: "isbn:9780300078152", saved: true)
        #expect(try await store.listWishlistIds() == ["isbn:9780300078152"])
        try await store.setWishlisted(workId: "isbn:9780300078152", saved: false)
        #expect((try await store.listWishlistIds()).isEmpty)

        let vm = ReaderViewModel(store: store, defaults: UserDefaults(suiteName: "cohort-reader-test-\(UUID().uuidString)")!)
        await vm.bootstrap(loadSampleBook: true, runNetworkSync: false)
        // Showcase seeds open-access editions, leaving unowned BYO titles in recommendedDiscoveryWorks
        #expect(vm.recommendedDiscoveryWorks.contains(where: { $0.workId == "isbn:9780300078152" }))

        let ownedByTitle = BookItem(
            id: "md5-scott",
            title: "Seeing Like a State: How Certain Schemes to Improve the Human Condition Have Failed",
            author: "James C. Scott",
            format: .epub,
            source: .homeServer
        )
        vm.books.append(ownedByTitle)
        let scottWork = try #require(vm.manifoldWorks.first(where: { $0.workId == "isbn:9780300078152" }))
        #expect(vm.ownedBook(for: scottWork)?.id == "md5-scott")
        #expect(!vm.recommendedDiscoveryWorks.contains(where: { $0.workId == "isbn:9780300078152" }))

        let active = BookItem(
            id: "b-active",
            title: "Active Book",
            author: "A",
            format: .pdf,
            source: .homeServer,
            bytes: 4_000_000,
            locator: ReadingLocator(spine: 1, fraction: 0.35)
        )
        let annotated = BookItem(
            id: "b-notes",
            title: "Annotated Book",
            author: "B",
            format: .epub,
            source: .homeServer,
            bytes: 8_000_000,
            notesVersion: "v1"
        )
        let readingShelf = BookItem(
            id: "b-reading-shelf",
            title: "Reading Shelf Book",
            author: "C",
            format: .epub,
            source: .homeServer,
            shelfNames: ["Reading"],
            bytes: 3_000_000
        )
        let oversized = BookItem(
            id: "b-huge",
            title: "Huge Scan",
            author: "D",
            format: .pdf,
            source: .homeServer,
            bytes: 90_000_000
        )
        let ranked = ReaderViewModel.prioritizedAutoDownloadCandidates(from: [oversized, readingShelf, annotated, active])
        #expect(ranked.map(\.id) == ["b-active", "b-notes", "b-reading-shelf"])
    }

    @Test("Typography backward-compatible decode, Auto theme resolution, highlight CSS/JS, and store eviction")
    @MainActor
    func typographyAndHighlightUpgrades() async throws {
        // 1. Default theme is Auto and legacy JSON without marginWidth/textAlignment decodes cleanly
        #expect(ReaderTypography.default.theme == .auto)
        let legacyJSON = Data("""
        {"theme":"Sepia","fontFamily":"Serif","fontSize":20,"lineHeight":1.65}
        """.utf8)
        let decoded = try JSONDecoder().decode(ReaderTypography.self, from: legacyJSON)
        #expect(decoded.theme == .sepia)
        #expect(decoded.marginWidth == .standard)
        #expect(decoded.textAlignment == .left)

        // 2. Adaptive Auto resolution maps dark -> Ink, light -> Paper
        #expect(ReaderPalette.resolvedTheme(.auto, colorScheme: .dark) == .ink)
        #expect(ReaderPalette.resolvedTheme(.auto, colorScheme: .light) == .paper)
        #expect(ReaderPalette.resolvedTheme(.sepia, colorScheme: .dark) == .sepia)

        // 3. HTML composer injects highlights and live typography updater without reload
        let sampleHL = ReadingHighlight(
            bookId: "gutenberg-84",
            canonicalId: "gutenberg:84",
            bookTitle: "Frankenstein",
            spine: 0,
            quote: "cold northern breeze"
        )
        let html = EPUBHTMLComposer.composeChapterHTML(
            rawXHTML: "<html><body><p>I feel a cold northern breeze play upon my cheeks.</p></body></html>",
            typography: ReaderTypography.default,
            notes: [],
            initialFraction: 0,
            initialWordOffset: nil,
            resolvedTheme: .ink,
            highlights: [sampleHL]
        )
        #expect(html.contains("--cr-bg: #111114"))
        #expect(html.contains("cold northern breeze"))
        #expect(html.contains("__cohortApplyTypography"))
        let updateJS = EPUBHTMLComposer.typographyUpdateJS(typography: decoded, resolvedTheme: .sepia)
        #expect(updateJS.contains("__cohortApplyTypography"))
        #expect(updateJS.contains("#F3EAD8"))

        // 4. ReaderStore deleteHighlight + evictAllCachedRemoteBooks preserves localImport
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-evict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try ReaderStore(dbPath: tmpDir.appendingPathComponent("s.sqlite").path, cacheRoot: tmpDir)

        try await store.saveHighlight(sampleHL)
        #expect(try await store.listHighlights(bookId: "gutenberg-84").count == 1)
        try await store.deleteHighlight(id: sampleHL.id)
        #expect(try await store.listHighlights(bookId: "gutenberg-84").isEmpty)

        let remoteBook = BookItem(id: "remote-1", title: "Remote", author: "R", format: .epub, source: .homeServer)
        let localBook = BookItem(id: "local-1", title: "Local", author: "L", format: .epub, source: .localImport)
        try await store.upsertBooks([remoteBook, localBook])
        let payload = try SampleShowcaseEPUB.buildFrankensteinSampleData()
        let remoteURL = try await store.storeOfflineBookData(payload, bookId: "remote-1", format: .epub)
        let localURL = try await store.storeOfflineBookData(payload, bookId: "local-1", format: .epub)

        try await store.evictAllCachedRemoteBooks()
        #expect(FileManager.default.fileExists(atPath: remoteURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: localURL.path) == true)
        let listed = try await store.listBooks()
        #expect(listed.first(where: { $0.id == "remote-1" })?.isOfflineCached == false)
        #expect(listed.first(where: { $0.id == "local-1" })?.isOfflineCached == true)

        // 5. In-book EPUB search locates passages across chapters
        let vm = ReaderViewModel(store: store, defaults: UserDefaults(suiteName: "cohort-reader-search-\(UUID().uuidString)")!)
        await vm.bootstrap(loadSampleBook: true, runNetworkSync: false)
        vm.tocSearchQuery = "Petersburgh"
        vm.runInBookSearch()
        #expect(vm.inBookMatches.contains(where: { $0.snippet.contains("Petersburgh") }))
    }

    @Test("Spine locator progress, SQLite persistence, recency-first auto-download, author-title matching, and resource lookup")
    @MainActor
    func progressRecencyMatchingAndEPUBResources() async throws {
        // 1. Spine-aware ReadingLocator & BookItem progress metrics
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_100_000)
        let senateLoc = ReadingLocator(
            spine: 19,
            fraction: 0.0,
            spineCount: 68,
            updatedAt: newerDate
        )
        #expect(abs(senateLoc.effectiveProgress - (19.0 / 68.0)) < 0.0001)
        let explicitLoc = ReadingLocator(
            spine: 19,
            fraction: 0.0,
            spineCount: 68,
            overallProgress: 0.294,
            updatedAt: newerDate
        )
        let senateBook = BookItem(
            id: "md5-629083e41a7eaf7c11e11eb3d301efbb",
            title: "Master of the Senate",
            author: "Robert A. Caro",
            format: .epub,
            source: .homeServer,
            bytes: 6_638_129,
            locator: explicitLoc
        )
        #expect(senateBook.isInProgress == true)
        #expect(senateBook.progressPercent == 29)

        let staleLoc = ReadingLocator(spine: 0, fraction: 0.05, spineCount: 68, overallProgress: 0.01, updatedAt: olderDate)
        let adopted = ReadingLocator.adoptIfNewer(local: staleLoc, remote: senateLoc)
        #expect(adopted?.spine == 19)
        #expect(adopted?.spineCount == 68)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-loc-mig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try ReaderStore(dbPath: tmpDir.appendingPathComponent("mig.sqlite").path, cacheRoot: tmpDir)
        try await store.upsertBooks([senateBook])
        _ = try await store.saveLocator(bookId: senateBook.id, locator: explicitLoc, enqueueSync: false)
        let reloaded = try await store.listBooks()
        let savedSenate = try #require(reloaded.first(where: { $0.id == senateBook.id }))
        #expect(savedSenate.locator?.spine == 19)
        #expect(savedSenate.locator?.spineCount == 68)
        #expect(abs((savedSenate.locator?.overallProgress ?? 0) - 0.294) < 0.001)
        #expect(savedSenate.isInProgress == true)

        // 2. prioritizedAutoDownloadCandidates puts newest in-progress book first
        let olderActive = BookItem(
            id: "older-active",
            title: "Older Read",
            author: "A",
            format: .epub,
            source: .homeServer,
            bytes: 1_500_000,
            locator: ReadingLocator(spine: 5, fraction: 0.1, spineCount: 30, updatedAt: olderDate)
        )
        let newerActive = BookItem(
            id: "newer-active",
            title: "Master of the Senate",
            author: "Robert A. Caro",
            format: .epub,
            source: .homeServer,
            bytes: 6_638_129,
            locator: senateLoc
        )
        let untouchedSmall = BookItem(
            id: "untouched-small",
            title: "Tiny Book",
            author: "B",
            format: .epub,
            source: .homeServer,
            bytes: 200_000,
            notesVersion: "v1"
        )
        let order = ReaderViewModel.prioritizedAutoDownloadCandidates(from: [untouchedSmall, olderActive, newerActive])
        #expect(order.map(\.id) == ["newer-active", "older-active", "untouched-small"])

        // 3. Author-prefixed title matching
        #expect(ReaderViewModel.normalizedTitleKey("David Graeber — Debt The First 5,000 Years") == "debt the first 5 000 years")
        let vm = ReaderViewModel(store: store, defaults: UserDefaults(suiteName: "cohort-reader-match-\(UUID().uuidString)")!)
        vm.books = [
            BookItem(
                id: "md5-debt",
                title: "David Graeber — Debt The First 5,000 Years",
                author: "David Graeber",
                format: .epub,
                source: .homeServer
            ),
        ]
        let debtWork = ManifoldReaderWork(
            workId: "isbn:9781612191294",
            title: "Debt: The First 5,000 Years",
            creator: "David Graeber",
            year: 2011,
            kind: "Nonfiction",
            format: .epub,
            summary: "History of debt and money.",
            shard: "00",
            x: 0.2,
            y: 0.3,
            vec32: Array(repeating: 0, count: 32)
        )
        #expect(vm.ownedBook(for: debtWork)?.id == "md5-debt")

        // 4. Root-OPF leading-slash resource lookup
        let doc = EPUBDocument(
            title: "Test",
            author: "A",
            canonicalId: nil,
            language: "en",
            opfDir: "",
            coverHref: "images/cover.jpg",
            spineHrefs: ["ch1.xhtml"],
            toc: [],
            resources: [
                "ch1.xhtml": Data("<html><body><p>Hello</p></body></html>".utf8),
                "images/cover.jpg": Data([0xFF, 0xD8, 0xFF]),
            ]
        )
        let img = try #require(doc.resourceData(forArchivePath: "//images/cover.jpg"))
        #expect(img.data == Data([0xFF, 0xD8, 0xFF]))
        #expect(img.mimeType == "image/jpeg")

        // 5. HomeLibraryClient.matchWorks round-trip
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHomeURLProtocol.self]
        let session = URLSession(configuration: config)
        let matched = try await HomeLibraryClient.matchWorks(
            baseURL: "https://mock.local",
            works: [(workId: "isbn:9780300078152", title: "Seeing Like a State", creator: "James C. Scott")],
            session: session
        )
        #expect(matched["isbn:9780300078152"]?.id == "md5-scott")

        // 6. Optional env-provided EPUB smoke check when set locally
        if let realPath = ProcessInfo.processInfo.environment["COHORT_READER_TEST_EPUB"],
           !realPath.isEmpty,
           FileManager.default.fileExists(atPath: realPath) {
            let realDoc = try EPUBParser.parse(url: URL(fileURLWithPath: realPath))
            #expect(!realDoc.spineHrefs.isEmpty)
            let sampleIdx = min(19, realDoc.spineHrefs.count - 1)
            let sampleCh = try #require(realDoc.chapter(at: sampleIdx))
            #expect(!sampleCh.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("PDF crop analyzer, column detector, search, vector signing flatten, and Quick Open tabs")
    @MainActor
    func pdfEnhancementsAndVectorSigning() async throws {
        // 1. Margin auto-crop trims wide margins while enclosing ink bounds
        let wideMarginURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wide-margin-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: wideMarginURL) }

        var letterBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        do {
            let ctx = try #require(CGContext(wideMarginURL as CFURL, mediaBox: &letterBox, nil))
            // Two pages (crop analyzer samples interior page indices)
            for pageNum in 0..<2 {
                ctx.beginPDFPage(nil)
                ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
                ctx.fill(CGRect(x: 170, y: 420, width: 280, height: 220))
                let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let attr = NSAttributedString(
                    string: "Page \(pageNum + 1) Bayesian inference content block",
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): bodyFont]
                )
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 170, y: 400)
                CTLineDraw(line, ctx)
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }

        let wideDoc = try #require(PDFDocument(url: wideMarginURL))
        let p1 = try #require(wideDoc.page(at: 1))
        let inkRect = try #require(PDFCropAnalyzer.computeInkCropRect(for: p1))
        #expect(inkRect.minX >= 145 && inkRect.minX <= 172)
        #expect(inkRect.maxX >= 445 && inkRect.maxX <= 495)
        #expect(inkRect.minY >= 380 && inkRect.maxY <= 665)

        let insets = try #require(PDFCropAnalyzer.computeDocumentCropInsets(for: wideDoc))
        PDFCropAnalyzer.applyCrop(insets, to: wideDoc)
        let croppedBounds = try #require(wideDoc.page(at: 1)).bounds(for: .cropBox)
        #expect(croppedBounds.width < 460)
        #expect(croppedBounds.height < 420)
        PDFCropAnalyzer.applyCrop(nil, to: wideDoc)
        #expect(wideDoc.page(at: 1)?.bounds(for: .cropBox).width == 612)

        // 2. PDF search finds text on page 2
        let hits = PDFSearch.search(document: wideDoc, query: "Bayesian")
        #expect(hits.count >= 1)
        #expect(hits.contains(where: { $0.pageIndex == 0 && $0.snippet.contains("Bayesian") }))

        // 3. Two-column academic detector separates left and right text streams
        let twoColURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-col-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: twoColURL) }
        do {
            let ctx = try #require(CGContext(twoColURL as CFURL, mediaBox: &letterBox, nil))
            ctx.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
            for row in 0..<8 {
                let y = 700 - CGFloat(row) * 20
                let leftAttr = NSAttributedString(
                    string: "Left column line \(row) with standard prose",
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                ctx.textPosition = CGPoint(x: 42, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(leftAttr), ctx)

                let rightAttr = NSAttributedString(
                    string: "Right column line \(row) with crisp spacing",
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                ctx.textPosition = CGPoint(x: 332, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(rightAttr), ctx)
            }
            ctx.endPDFPage()
            ctx.closePDF()
        }
        let colDoc = try #require(PDFDocument(url: twoColURL))
        let detectedCols = PDFColumnDetector.detectColumns(on: try #require(colDoc.page(at: 0)))
        #expect(detectedCols.count == 2)
        #expect(detectedCols[0].maxX < detectedCols[1].minX + 15)

        // 4. SignatureStore + PDFSigner vector flatten preserves text and stamps signature + date
        let sigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sigURL) }
        let sig = SavedSignature(
            label: "Primary",
            strokes: [[
                SignaturePoint(x: 0.1, y: 0.5),
                SignaturePoint(x: 0.5, y: 0.2),
                SignaturePoint(x: 0.9, y: 0.6),
            ]],
            inkColor: .navy,
            aspectRatio: 2.5
        )
        try SignatureStore.save([sig], to: sigURL)
        #expect(SignatureStore.load(from: sigURL).map(\.label) == ["Primary"])

        let srcPDFData = try Data(contentsOf: twoColURL)
        let stampedData = try PDFSigner.flattenStamps(
            [
                PDFStampPlacement(
                    pageIndex: 0,
                    normalizedRect: CodableRect(x: 0.25, y: 0.70, width: 0.35, height: 0.10),
                    kind: .signature(sig)
                ),
                PDFStampPlacement(
                    pageIndex: 0,
                    normalizedRect: CodableRect(x: 0.25, y: 0.84, width: 0.25, height: 0.05),
                    kind: .text("24 Nov 2026", .navy)
                ),
            ],
            onto: srcPDFData
        )
        let signedDoc = try #require(PDFDocument(data: stampedData))
        let signedPage = try #require(signedDoc.page(at: 0))
        let pageText = signedPage.string ?? ""
        #expect(pageText.contains("Left column line"))
        #expect(pageText.contains("24 Nov 2026"))

        // Render flattened signature region and verify blue ink pixels exist
        let renderW = 612
        let renderH = 792
        var rgba = [UInt8](repeating: 255, count: renderW * renderH * 4)
        let renderedOk: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress,
                  let bmp = CGContext(
                      data: base,
                      width: renderW,
                      height: renderH,
                      bitsPerComponent: 8,
                      bytesPerRow: renderW * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            bmp.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            bmp.fill(CGRect(x: 0, y: 0, width: renderW, height: renderH))
            signedPage.draw(with: .cropBox, to: bmp)
            return true
        }
        #expect(renderedOk)
        // Expected visual top-left y in 0.70...0.80 -> pixel rows ~554...634, cols ~153...367
        var blueInkHits = 0
        for row in 550..<638 {
            for col in 150..<370 {
                let off = (row * renderW + col) * 4
                let r = Int(rgba[off])
                let g = Int(rgba[off + 1])
                let b = Int(rgba[off + 2])
                if b > r + 20 && g < 160 && b > 50 {
                    blueInkHits += 1
                }
            }
        }
        #expect(blueInkHits > 30)

        // 5. Quick Open does not persist into library store until promoted, and supports search + jump history
        let dbTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-open-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dbTmp) }
        try FileManager.default.createDirectory(at: dbTmp, withIntermediateDirectories: true)
        let store = try ReaderStore(dbPath: dbTmp.appendingPathComponent("vm.sqlite").path, cacheRoot: dbTmp)
        let vm = ReaderViewModel(
            store: store,
            defaults: UserDefaults(suiteName: "cohort-pdf-vm-\(UUID().uuidString)")!,
            signatureStoreURL: sigURL
        )
        await vm.bootstrap(loadSampleBook: false, runNetworkSync: false)
        await vm.quickOpenExternalFile(from: wideMarginURL)
        #expect(vm.activeTabIsQuickOpen == true)
        #expect(vm.openTabs.count == 1)
        #expect((try await store.listBooks()).contains(where: { $0.id == vm.activeBook?.id }) == false)

        await vm.runPDFSearchNow(query: "Bayesian")
        #expect(!vm.inBookMatches.isEmpty)
        await vm.selectPDFPage(1, recordJump: true)
        #expect(vm.pdfJumpBackStack == [0])
        await vm.jumpBackInPDF()
        #expect(vm.activePDFPageIndex == 0)
        #expect(vm.pdfJumpForwardStack == [1])
    }

    @Test("EPUB paginated HTML composer, live highlight JS hook, and backward-compatible typography decoding")
    func epubPaginationAndTypographyBackwardCompat() throws {
        let legacyJSON = Data("""
        {"theme":"Paper","fontFamily":"Serif","fontSize":19,"lineHeight":1.6,"marginWidth":"Standard","textAlignment":"Left"}
        """.utf8)
        let decoded = try JSONDecoder().decode(ReaderTypography.self, from: legacyJSON)
        #expect(decoded.readingFlow == .scroll)

        var pagedTypo = ReaderTypography.default
        pagedTypo.readingFlow = .paginated
        let html = EPUBHTMLComposer.composeChapterHTML(
            rawXHTML: "<html><body><p>Hello world from chapter one.</p></body></html>",
            typography: pagedTypo,
            notes: [],
            initialFraction: 0.25,
            initialWordOffset: 2,
            resolvedTheme: .paper,
            highlights: []
        )
        #expect(html.contains("column-width"))
        #expect(html.contains("scroll-snap-type: x mandatory"))
        #expect(html.contains("IS_PAGINATED = true"))
        #expect(html.contains("window.__cohortAddHighlight"))

        let js = EPUBHTMLComposer.typographyUpdateJS(typography: pagedTypo, resolvedTheme: .sepia)
        #expect(js.contains("window.__cohortApplyTypography"))
    }

    @Test("EPUB footnote extraction finds target fragment and strips markup")
    func epubFootnotePreviewExtraction() {
        let xhtml = """
        <html><body>
          <aside id="fn1" epub:type="footnote"><p>See <em>Caro</em>, The Power Broker (1974), p. 412.</p></aside>
        </body></html>
        """
        let doc = EPUBDocument(
            title: "Sample",
            author: "Tester",
            canonicalId: nil,
            language: "en",
            opfDir: "OEBPS",
            coverHref: nil,
            spineHrefs: ["OEBPS/ch1.xhtml"],
            toc: [],
            resources: ["OEBPS/ch1.xhtml": Data(xhtml.utf8)]
        )
        let preview = doc.extractFootnotePreview(archivePath: "OEBPS/ch1.xhtml", fragmentId: "fn1")
        #expect(preview == "See Caro, The Power Broker (1974), p. 412.")
    }

    @Test("ReaderStore highlight tombstones and two-way remote merge")
    func storeHighlightTombstonesAndMerge() async throws {
        let store = try ReaderStore(dbPath: ":memory:")
        let h1 = ReadingHighlight(id: "hl-1", bookId: "b1", bookTitle: "Book", spine: 0, quote: "First quote")
        let h2 = ReadingHighlight(id: "hl-2", bookId: "b1", bookTitle: "Book", spine: 1, quote: "Second quote")
        try await store.saveHighlight(h1)
        try await store.saveHighlight(h2)
        try await store.deleteHighlight(id: "hl-1")

        let deletedIds = try await store.listDeletedHighlightIds()
        #expect(deletedIds == ["hl-1"])

        let remoteKeep = ReadingHighlight(id: "hl-3", bookId: "b1", bookTitle: "Book", spine: 2, quote: "From other device")
        try await store.mergeRemoteHighlights([h1, remoteKeep], deletedIds: ["hl-2"])

        let merged = try await store.listHighlights(bookId: "b1")
        #expect(merged.map(\.id) == ["hl-3"])
        let allDeleted = try await store.listDeletedHighlightIds()
        #expect(allDeleted.contains("hl-1"))
        #expect(allDeleted.contains("hl-2"))
    }

    @Test("HomeLibraryClient syncHighlights and uploadToInbox")
    func clientSyncHighlightsAndInbox() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHomeURLProtocol.self]
        let session = URLSession(configuration: config)

        let local = [ReadingHighlight(id: "hl-local", bookId: "b1", bookTitle: "Book", spine: 0, quote: "Local line")]
        let synced = try await HomeLibraryClient.syncHighlights(
            baseURL: "https://mock.home.local",
            highlights: local,
            deletedIds: ["hl-old"],
            session: session
        )
        #expect(synced.deletedIds.contains("hl-old"))
        #expect(synced.highlights.contains(where: { $0.id == "hl-remote" }))

        let uploaded = try await HomeLibraryClient.uploadToInbox(
            baseURL: "https://mock.home.local",
            data: Data("%PDF-1.4\n%%EOF\n".utf8),
            filename: "contract.pdf",
            title: "Signed Contract",
            author: "Test Author",
            session: session
        )
        #expect(uploaded.id == "inbox-1234abcd")
        #expect(uploaded.format == .pdf)
        #expect(uploaded.shelfNames == ["Synced Inbox"])
    }

    @Test("ReaderViewModel cold-launch external open guard, tab cycling, and Handoff continuity")
    @MainActor
    func vmLaunchGuardTabsAndHandoff() async throws {
        let dbTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-eco-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dbTmp) }
        try FileManager.default.createDirectory(at: dbTmp, withIntermediateDirectories: true)

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdfA = dbTmp.appendingPathComponent("alpha.pdf")
        let pdfB = dbTmp.appendingPathComponent("beta.pdf")
        for (url, label) in [(pdfA, "Alpha Page 1"), (pdfB, "Beta Page 1")] {
            let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            let line2 = CTLineCreateWithAttributedString(NSAttributedString(string: "\(label) Page 2"))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line2, ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }

        let store = try ReaderStore(dbPath: dbTmp.appendingPathComponent("vm.sqlite").path, cacheRoot: dbTmp)
        let sigURL = dbTmp.appendingPathComponent("sigs.json")
        let vm = ReaderViewModel(
            store: store,
            defaults: UserDefaults(suiteName: "cohort-eco-vm-\(UUID().uuidString)")!,
            signatureStoreURL: sigURL
        )

        // Opening an external file before bootstrap finishes must prevent sample Frankenstein from stealing focus
        await vm.quickOpenExternalFile(from: pdfA)
        await vm.bootstrap(loadSampleBook: true, runNetworkSync: false)
        #expect(vm.activePDFURL == pdfA)
        #expect(vm.selectedTab == .read)

        // Open a second tab and cycle next/prev
        await vm.quickOpenExternalFile(from: pdfB)
        #expect(vm.openTabs.count == 2)
        #expect(vm.activePDFURL == pdfB)
        await vm.selectAdjacentTab(delta: 1)
        #expect(vm.activePDFURL == pdfA)
        await vm.selectAdjacentTab(delta: -1)
        #expect(vm.activePDFURL == pdfB)

        // Handoff to an existing library book navigates directly to the handed-off spine
        await vm.handleHandoffActivity([
            "bookId": "gutenberg-84",
            "title": "Frankenstein",
            "spine": 1,
            "fraction": 0.5,
        ])
        #expect(vm.activeBook?.id == "gutenberg-84")
        #expect(vm.activeEPUBSpineIndex == 1)
    }
}

private final class MockManifoldURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        var body = Data()
        if path == "/api/v1/works" || path == "/api/v1/shard/0a" {
            body = Data("""
            {
              "works": [
                {"workId":"wikidata:Q752509","domain":"tv","title":"Sintel","creator":"Colin Levy","year":2010},
                {"workId":"gutenberg:84","domain":"reader","title":"Frankenstein","creator":"Mary Shelley","year":1818,"format":"epub"}
              ]
            }
            """.utf8)
        } else if path == "/api/v1/lenses" {
            body = Data("""
            {
              "lenses": [
                {"id":"lens:tv:mood","domain":"tv","name":"TV Mood","summary":"TV lens","anchors":[]},
                {"id":"lens:reader:systems","domain":"reader","name":"Systems","summary":"Reader lens","anchors":[]}
              ]
            }
            """.utf8)
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockHomeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payloadBytes = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = Data()

        if path == "/api/login" {
            body = Data("{\"name\":\"Mock Home\"}".utf8)
        } else if path == "/api/home" {
            body = Data("""
            {
              "serverName": "Mock Home",
              "shelves": [{"id": "reading", "title": "Reading Now", "itemIds": ["gutenberg-84"]}],
              "items": [{
                "id": "gutenberg-84",
                "canonicalId": "gutenberg:84",
                "title": "Frankenstein",
                "author": "Mary Shelley",
                "year": 1818,
                "format": "epub",
                "bytes": \(Self.payloadBytes.count),
                "hasCover": false,
                "notesVersion": "v1"
              }]
            }
            """.utf8)
        } else if path == "/api/book/gutenberg-84" {
            headers["Content-Type"] = "application/epub+zip"
            if let rangeHeader = request.value(forHTTPHeaderField: "Range"),
               rangeHeader.hasPrefix("bytes="),
               let start = Int(rangeHeader.dropFirst("bytes=".count).split(separator: "-").first ?? "") {
                status = 206
                body = Data(Self.payloadBytes.dropFirst(start))
            } else {
                body = Self.payloadBytes
            }
        } else if path == "/api/notes/gutenberg-84" {
            body = Data("""
            {"notes":[{"id":"n1","spine":0,"anchor":"St. Petersburgh","kind":"place","label":"Saint Petersburg","note":"Port city.","source":"Wikipedia"}]}
            """.utf8)
        } else if path == "/api/progress" {
            body = Data("{\"accepted\":1}".utf8)
        } else if path == "/api/match" {
            body = Data("""
            {
              "matches": {
                "isbn:9780300078152": {
                  "id": "md5-scott",
                  "title": "Seeing Like a State",
                  "author": "James C. Scott",
                  "format": "epub",
                  "bytes": 2400000,
                  "hasCover": true
                }
              }
            }
            """.utf8)
        } else if path == "/api/highlights" {
            body = Data("""
            {
              "highlights": [{
                "id": "hl-remote",
                "bookId": "b1",
                "bookTitle": "Book",
                "spine": 1,
                "quote": "Remote quote",
                "note": "",
                "sentToCohort": false,
                "createdAt": "2026-11-24T08:00:00Z"
              }],
              "deletedIds": ["hl-old"]
            }
            """.utf8)
        } else if path == "/api/inbox" {
            body = Data("""
            {
              "item": {
                "id": "inbox-1234abcd",
                "title": "Signed Contract",
                "author": "Test Author",
                "format": "pdf",
                "shelves": ["Synced Inbox"],
                "bytes": 16,
                "hasCover": false
              }
            }
            """.utf8)
        } else {
            status = 404
        }

        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
