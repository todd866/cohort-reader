import CoreGraphics
import Foundation
import ImageIO
import PDFKit
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
