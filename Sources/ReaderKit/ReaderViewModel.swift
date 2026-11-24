import EPUBEngine
import Foundation
import HomeLibraryClient
import ManifoldClient
import Observation
import PDFEngine
import PDFKit
import ReaderModel
import ReaderStorage
import SwiftUI

public enum ReaderTab: String, CaseIterable, Sendable {
    case shelf = "Library"
    case read = "Read"
    case map = "Atlas"
    case search = "Search"

    public var symbol: String {
        switch self {
        case .shelf: return "books.vertical"
        case .read: return "book.pages"
        case .map: return "sparkles"
        case .search: return "magnifyingglass"
        }
    }
}

public enum SearchScope: String, CaseIterable, Sendable {
    case all = "All"
    case books = "Books"
    case papers = "Papers"
    case offline = "Offline"
}

@Observable
@MainActor
public final class ReaderViewModel {
    public let store: ReaderStore
    private let defaults: UserDefaults

    public var selectedTab: ReaderTab = .shelf
    public var books: [BookItem] = []
    public var shelves: [LibraryShelf] = []
    public var activeShelfFilter: String = "All"
    public var shelfUsesListLayout: Bool = false

    // Manifold coordinates & Reading Lenses
    public var manifoldWorks: [ManifoldReaderWork] = ShowcaseCatalog.works
    public var lenses: [ReaderLens] = ShowcaseCatalog.lenses
    public var selectedLensId: String = ShowcaseCatalog.lenses.first?.id ?? ""
    public var selectedMapWorkId: String = "isbn:9780300078152"
    public var shardCacheHits: Int = 0
    public var manifoldHubURL: String
    public var presentedDiscoveryWork: ManifoldReaderWork?
    public var wishlistIds: Set<String> = []

    // Home Library Server & Smart Offline Download
    public var serverURL: String
    public var serverPassphrase: String = ""
    public var isServerConnected: Bool = false
    public var serverName: String = ""
    public var serverStatusMessage: String = "Offline"
    public var pendingOutboxCount: Int = 0
    public var autoDownloadEnabled: Bool = true
    public var autoDownloadBudgetMB: Int = 350
    public var autoDownloadActiveTitle: String?
    public var autoDownloadedCount: Int = 0

    // Active Reader Session
    public var activeBook: BookItem?
    public var activeEPUB: EPUBDocument?
    public var activeEPUBSpineIndex: Int = 0
    public var activePDFURL: URL?
    public var activePDFMetadata: PDFMetadataSummary?
    public var activePDFPageIndex: Int = 0
    public var activeNotes: [MarginNote] = []
    public var presentedMarginNote: MarginNote?
    public var isTOCPresented: Bool = false
    public var tocSegment: Int = 0
    public var isTypographyPresented: Bool = false
    public var isReaderChromeHidden: Bool = false
    public var typography: ReaderTypography = .default
    public var activeHighlights: [ReadingHighlight] = []
    public var activeSelectionText: String = ""
    public var pendingCohortDraft: CohortCardDraft?
    public var cohortDraftNote: String = ""
    public var isImporterPresented: Bool = false
    public var lastHandoffMessage: String?

    // Search
    public var searchQuery: String = ""
    public var searchScope: SearchScope = .all
    public var serverSearchResults: [BookItem] = []
    public var isSearchingServer: Bool = false

    // Settings & Errors
    public var isSettingsPresented: Bool = false
    public var offlineBytes: Int64 = 0
    public var bannerError: String?
    public var isBusyBookId: String?

    private var readingStartAt: Date = Date()
    private var autoDownloadTask: Task<Void, Never>?
    private var manifoldSyncedOnce: Bool = false
    private var allowBackgroundSync: Bool = true

    public init(store: ReaderStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        let savedHub = defaults.string(forKey: "cohortReader.manifoldHub") ?? ManifoldReaderClient.defaultHub
        let plistServer = (Bundle.main.object(forInfoDictionaryKey: "CohortReaderDefaultServer") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let savedServer = defaults.string(forKey: "cohortReader.serverURL") ?? plistServer
        if let typoData = defaults.data(forKey: "cohortReader.typography"),
           let decoded = try? JSONDecoder().decode(ReaderTypography.self, from: typoData) {
            self.typography = decoded
        }
        if defaults.object(forKey: "cohortReader.autoDownloadEnabled") != nil {
            self.autoDownloadEnabled = defaults.bool(forKey: "cohortReader.autoDownloadEnabled")
        }
        let savedBudget = defaults.integer(forKey: "cohortReader.autoDownloadBudgetMB")
        if savedBudget > 0 {
            self.autoDownloadBudgetMB = savedBudget
        }
        self.shelfUsesListLayout = defaults.bool(forKey: "cohortReader.shelfUsesListLayout")
        self.manifoldHubURL = savedHub
        self.serverURL = savedServer
        if !savedServer.isEmpty {
            self.serverPassphrase = ReaderKeychain.loadPassword(server: savedServer) ?? ""
        }
    }

    public func savePreferences() {
        defaults.set(autoDownloadEnabled, forKey: "cohortReader.autoDownloadEnabled")
        defaults.set(autoDownloadBudgetMB, forKey: "cohortReader.autoDownloadBudgetMB")
        defaults.set(shelfUsesListLayout, forKey: "cohortReader.shelfUsesListLayout")
    }

    public func bootstrap(loadSampleBook: Bool = true, runNetworkSync: Bool = true) async {
        self.allowBackgroundSync = runNetworkSync
        do {
            wishlistIds = (try? await store.listWishlistIds()) ?? []
            var current = try await store.listBooks()
            if current.isEmpty {
                let openSeedItems = ShowcaseCatalog.works
                    .filter { $0.epubURL != nil || $0.openAccessURL != nil }
                    .map { $0.toBookItem() }
                try await store.upsertBooks(openSeedItems)

                if loadSampleBook {
                    let sampleData = try SampleShowcaseEPUB.buildFrankensteinSampleData()
                    let url = try await store.storeOfflineBookData(sampleData, bookId: "gutenberg-84", format: .epub)
                    try await store.saveMarginNotes(bookId: "gutenberg-84", notes: ShowcaseCatalog.sampleMarginNotes)
                    _ = try await store.saveLocator(
                        bookId: "gutenberg-84",
                        locator: ReadingLocator(spine: 0, fraction: 0.14, wordOffset: 42, updatedAt: Date()),
                        enqueueSync: false
                    )
                    if var frank = openSeedItems.first(where: { $0.id == "gutenberg-84" }) {
                        frank.isOfflineCached = true
                        frank.localFilePath = url.path
                        frank.bytes = Int64(sampleData.count)
                        try await store.upsertBooks([frank])
                    }
                }
                current = try await store.listBooks()
            }

            books = visibleLibraryBooks(from: current)
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            pendingOutboxCount = (try? await store.pendingSyncEvents().count) ?? 0

            let lastId = defaults.string(forKey: "cohortReader.lastBookId")
            let initial = (lastId.flatMap { id in books.first(where: { $0.id == id && ($0.isOfflineCached || $0.canonicalId == "gutenberg:84") }) })
                ?? books.first(where: { $0.isOfflineCached })
            if let initial {
                await openBook(initial, switchTab: false)
            }

            if runNetworkSync && !serverURL.isEmpty && !isServerConnected {
                await syncServerCatalog(silent: true)
            }
        } catch {
            bannerError = error.localizedDescription
        }
    }

    private func visibleLibraryBooks(from raw: [BookItem]) -> [BookItem] {
        raw.filter { book in
            if book.source == .showcase && !book.isOfflineCached && book.epubURL == nil && book.openAccessURL == nil {
                return false
            }
            return true
        }
    }

    public static func normalizedTitleKey(_ raw: String) -> String {
        let head = raw.components(separatedBy: CharacterSet(charactersIn: ":—")).first ?? raw
        let noParen = head.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let cleaned = noParen.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let trimmed: [String]
        if let first = cleaned.first, ["the", "a", "an"].contains(first), cleaned.count > 1 {
            trimmed = Array(cleaned.dropFirst())
        } else {
            trimmed = cleaned
        }
        return trimmed.joined(separator: " ")
    }

    public func ownedBook(for work: ManifoldReaderWork) -> BookItem? {
        if let exact = books.first(where: { $0.canonicalId == work.workId }) {
            return exact
        }
        let targetKey = Self.normalizedTitleKey(work.title)
        guard targetKey.count >= 5 else { return nil }
        return books.first { book in
            let bKey = Self.normalizedTitleKey(book.title)
            return bKey == targetKey || (bKey.count >= 10 && bKey.hasPrefix(targetKey))
        }
    }

    public var continueReadingBook: BookItem? {
        books.first { ($0.locator?.fraction ?? 0) > 0 && ($0.locator?.fraction ?? 0) < 0.98 && ($0.isOfflineCached || $0.source == .homeServer) }
            ?? books.first(where: \.isOfflineCached)
    }

    public var recommendedDiscoveryWorks: [ManifoldReaderWork] {
        let unowned = manifoldWorks.filter { ownedBook(for: $0) == nil }
        guard !unowned.isEmpty else { return [] }

        let seedVectors: [[Int]] = {
            var vecs: [[Int]] = []
            if let activeCid = activeBook?.canonicalId,
               let activeWork = manifoldWorks.first(where: { $0.workId == activeCid }),
               !activeWork.vec32.isEmpty {
                vecs.append(activeWork.vec32)
            }
            for w in manifoldWorks where ownedBook(for: w) != nil && !w.vec32.isEmpty {
                vecs.append(w.vec32)
            }
            if vecs.isEmpty, let lens = lenses.first(where: { $0.id == selectedLensId }) {
                let byId = Dictionary(uniqueKeysWithValues: manifoldWorks.map { ($0.workId, $0) })
                for anc in lens.anchors {
                    if let aw = byId[anc.workId], !aw.vec32.isEmpty {
                        vecs.append(aw.vec32)
                    }
                }
            }
            return Array(vecs.prefix(8))
        }()

        return unowned.sorted { a, b in
            let sa = discoveryAffinityScore(for: a, seedVectors: seedVectors)
            let sb = discoveryAffinityScore(for: b, seedVectors: seedVectors)
            if abs(sa - sb) > 0.0001 { return sa > sb }
            return a.title < b.title
        }
    }

    private func discoveryAffinityScore(for work: ManifoldReaderWork, seedVectors: [[Int]]) -> Double {
        let baseSim: Double
        if seedVectors.isEmpty || work.vec32.isEmpty {
            baseSim = 0.25
        } else {
            let best = seedVectors.map { LensRanker.cosine($0, work.vec32) }.max() ?? 0.0
            let mean = seedVectors.map { LensRanker.cosine($0, work.vec32) }.reduce(0, +) / Double(seedVectors.count)
            baseSim = best * 0.65 + mean * 0.35
        }
        let wishBoost = wishlistIds.contains(work.workId) ? 0.35 : 0.0
        let byoDiversityBoost = (work.epubURL == nil && work.openAccessURL == nil) ? 0.04 : 0.0
        return baseSim + wishBoost + byoDiversityBoost
    }

    public func openOrInspect(_ work: ManifoldReaderWork) async {
        if let owned = ownedBook(for: work) {
            await openBook(owned)
        } else {
            presentedDiscoveryWork = work
        }
    }

    public func toggleWishlist(workId: String) async {
        let nextSaved = !wishlistIds.contains(workId)
        if nextSaved {
            wishlistIds.insert(workId)
        } else {
            wishlistIds.remove(workId)
        }
        try? await store.setWishlisted(workId: workId, saved: nextSaved)
    }

    public func downloadDiscoveryWork(_ work: ManifoldReaderWork) async {
        var book = work.toBookItem()
        if book.openAccessURL == nil, let oa = OpenAccessResolver.directDownloadURL(for: work.workId) {
            book.epubURL = oa.absoluteString
        }
        try? await store.upsertBooks([book])
        books = visibleLibraryBooks(from: (try? await store.listBooks()) ?? books)
        await downloadForOffline(book)
        if let updated = books.first(where: { $0.id == book.id }), updated.isOfflineCached {
            presentedDiscoveryWork = nil
            await openBook(updated, switchTab: true)
        }
    }

    public static func prioritizedAutoDownloadCandidates(
        from items: [BookItem],
        maxSingleBytes: Int64 = 35 * 1024 * 1024
    ) -> [BookItem] {
        let eligible = items.filter { book in
            guard book.source == .homeServer, !book.isOfflineCached else { return false }
            guard book.bytes > 0, book.bytes <= maxSingleBytes else { return false }
            return true
        }
        func score(_ book: BookItem) -> Int {
            var pts = 0
            if let frac = book.locator?.fraction, frac > 0, frac < 0.98 { pts += 1000 }
            if book.notesVersion != nil { pts += 500 }
            if book.shelfNames.contains(where: { $0.caseInsensitiveCompare("Reading") == .orderedSame }) { pts += 300 }
            pts += (book.format == .epub ? 150 : 40)
            if !book.shelfNames.isEmpty { pts += 80 }
            return pts
        }
        return eligible.sorted { a, b in
            let sa = score(a)
            let sb = score(b)
            if sa != sb { return sa > sb }
            if a.bytes != b.bytes { return a.bytes < b.bytes }
            return a.title < b.title
        }
    }

    public func prefetchLikelyReads() async {
        guard allowBackgroundSync, autoDownloadEnabled, isServerConnected, !serverURL.isEmpty else { return }
        let budgetBytes = Int64(max(50, autoDownloadBudgetMB)) * 1024 * 1024
        var currentBytes = await store.cachedBookBytes()
        guard currentBytes < budgetBytes else { return }

        let candidates = Self.prioritizedAutoDownloadCandidates(from: books).prefix(24)
        for book in candidates {
            if Task.isCancelled || !autoDownloadEnabled || !isServerConnected { break }
            if currentBytes + book.bytes > budgetBytes && autoDownloadedCount >= 3 { break }

            autoDownloadActiveTitle = book.title
            defer { autoDownloadActiveTitle = nil }
            do {
                let data = try await HomeLibraryClient.downloadBook(baseURL: serverURL, bookId: book.id)
                if book.notesVersion != nil {
                    let notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: serverURL, bookId: book.id)) ?? []
                    if !notes.isEmpty {
                        try? await store.saveMarginNotes(bookId: book.id, notes: notes)
                    }
                }
                let url = try await store.storeOfflineBookData(data, bookId: book.id, format: book.format == .article ? .pdf : book.format)
                var updated = book
                updated.isOfflineCached = true
                updated.localFilePath = url.path
                updated.bytes = Int64(data.count)
                try await store.upsertBooks([updated])
                books = visibleLibraryBooks(from: try await store.listBooks())
                rebuildShelves()
                currentBytes = await store.cachedBookBytes()
                offlineBytes = currentBytes
                autoDownloadedCount += 1
            } catch {
                continue
            }
        }
    }

    public func rebuildShelves() {
        var list: [LibraryShelf] = []
        let readingIds = books
            .filter { ($0.locator?.fraction ?? 0) > 0 && ($0.locator?.fraction ?? 0) < 0.98 }
            .map(\.id)
        if !readingIds.isEmpty {
            list.append(LibraryShelf(id: "reading", title: "Reading Now", itemIds: readingIds))
        }
        let offlineIds = books.filter(\.isOfflineCached).map(\.id)
        if !offlineIds.isEmpty {
            list.append(LibraryShelf(id: "offline", title: "Downloaded", itemIds: offlineIds))
        }
        let genreGroups = Dictionary(grouping: books) { $0.genre.isEmpty ? "General" : $0.genre }
        for (genre, items) in genreGroups.sorted(by: { $0.value.count > $1.value.count }).prefix(6) {
            list.append(LibraryShelf(id: "genre:\(genre)", title: genre, itemIds: items.map(\.id)))
        }
        shelves = list
    }

    public var filteredShelfBooks: [BookItem] {
        switch activeShelfFilter {
        case "All":
            return books
        case "Reading", "Reading Now":
            return books.filter { ($0.locator?.fraction ?? 0) > 0 && ($0.locator?.fraction ?? 0) < 0.98 }
        case "Offline":
            return books.filter(\.isOfflineCached)
        case "Papers":
            return books.filter { $0.format == .article || ($0.canonicalId?.hasPrefix("doi:") ?? false) || ($0.canonicalId?.hasPrefix("pmid:") ?? false) || ($0.canonicalId?.hasPrefix("arxiv:") ?? false) }
        case "Books":
            return books.filter { $0.format == .epub || $0.genre == "Nonfiction" || $0.genre == "Literature" || ($0.canonicalId?.hasPrefix("gutenberg:") ?? false) || ($0.canonicalId?.hasPrefix("isbn:") ?? false) }
        default:
            return books.filter { $0.genre == activeShelfFilter || $0.shelfNames.contains(activeShelfFilter) }
        }
    }

    // MARK: - Open & Read

    public func openBook(_ book: BookItem, switchTab: Bool = true) async {
        bannerError = nil
        readingStartAt = Date()
        isReaderChromeHidden = false
        activeSelectionText = ""
        activeBook = book
        activeEPUB = nil
        activePDFURL = nil
        activePDFMetadata = nil
        defaults.set(book.id, forKey: "cohortReader.lastBookId")
        activeHighlights = (try? await store.listHighlights(bookId: book.id)) ?? []
        activeNotes = (try? await store.loadMarginNotes(bookId: book.id)) ?? []
        if activeNotes.isEmpty && book.canonicalId == "gutenberg:84" {
            activeNotes = ShowcaseCatalog.sampleMarginNotes
        }

        if let cid = book.canonicalId, manifoldWorks.contains(where: { $0.workId == cid }) {
            selectedMapWorkId = cid
        }

        if let localPath = book.localFilePath, FileManager.default.fileExists(atPath: localPath) {
            let url = URL(fileURLWithPath: localPath)
            loadLocalDocument(url: url, book: book)
        } else if book.source == .homeServer && isServerConnected {
            await downloadForOffline(book)
            if let updated = books.first(where: { $0.id == book.id }),
               let localPath = updated.localFilePath,
               FileManager.default.fileExists(atPath: localPath) {
                loadLocalDocument(url: URL(fileURLWithPath: localPath), book: updated)
            }
        } else if let cid = book.canonicalId,
                  let dlURL = URL(string: book.epubURL ?? "") ?? OpenAccessResolver.directDownloadURL(for: cid) {
            await fetchOpenAccessBook(book, from: dlURL)
        } else if book.canonicalId == "gutenberg:84" {
            if let data = try? SampleShowcaseEPUB.buildFrankensteinSampleData(),
               let url = try? await store.storeOfflineBookData(data, bookId: book.id, format: .epub) {
                loadLocalDocument(url: url, book: book)
            }
        }

        if activeNotes.isEmpty && book.source == .homeServer && book.notesVersion != nil && isServerConnected && !serverURL.isEmpty {
            let notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: serverURL, bookId: book.id)) ?? []
            if !notes.isEmpty {
                try? await store.saveMarginNotes(bookId: book.id, notes: notes)
                activeNotes = notes
            }
        }

        if switchTab {
            selectedTab = .read
        }
    }

    public func saveTypography() {
        if let data = try? JSONEncoder().encode(typography) {
            defaults.set(data, forKey: "cohortReader.typography")
        }
    }

    public func saveQuickHighlight(quote: String, note: String = "") async {
        guard let book = activeBook else { return }
        let highlight = ReadingHighlight(
            bookId: book.id,
            canonicalId: book.canonicalId,
            bookTitle: book.title,
            spine: activeEPUBSpineIndex,
            quote: quote,
            note: note,
            sentToCohort: false
        )
        try? await store.saveHighlight(highlight)
        activeHighlights = (try? await store.listHighlights(bookId: book.id)) ?? []
        activeSelectionText = ""
        lastHandoffMessage = "Saved highlight in \(book.title)"
    }

    private func loadLocalDocument(url: URL, book: BookItem) {
        if book.format == .epub {
            do {
                let doc = try EPUBParser.parse(url: url)
                activeEPUB = doc
                let spine = book.locator?.spine ?? 0
                activeEPUBSpineIndex = min(max(spine, 0), max(0, doc.spineHrefs.count - 1))
            } catch {
                bannerError = "Failed to open EPUB: \(error.localizedDescription)"
            }
        } else {
            activePDFURL = url
            activePDFMetadata = PDFInspector.inspect(url: url)
            if let count = activePDFMetadata?.pageCount, let loc = book.locator {
                activePDFPageIndex = loc.pageIndex ?? PDFInspector.pageIndex(forFraction: loc.fraction, pageCount: count)
            } else {
                activePDFPageIndex = 0
            }
        }
    }

    public func currentChapter() -> EPUBChapter? {
        activeEPUB?.chapter(at: activeEPUBSpineIndex)
    }

    public func currentChapterHTML() -> String {
        guard let chapter = currentChapter(),
              let raw = String(data: chapter.xhtmlData, encoding: .utf8) ?? String(data: chapter.xhtmlData, encoding: .isoLatin1) else {
            return ""
        }
        let chapterNotes = activeNotes.filter { $0.spine == chapter.index }
        let loc = activeBook?.locator
        let frac = (loc?.spine == chapter.index) ? (loc?.fraction ?? 0) : 0
        let word = (loc?.spine == chapter.index) ? loc?.wordOffset : nil
        return EPUBHTMLComposer.composeChapterHTML(
            rawXHTML: raw,
            typography: typography,
            notes: chapterNotes,
            initialFraction: frac,
            initialWordOffset: word
        )
    }

    public func selectEPUBSpine(_ index: Int) async {
        guard let doc = activeEPUB, index >= 0, index < doc.spineHrefs.count else { return }
        activeEPUBSpineIndex = index
        await recordProgress(spine: index, fraction: 0, wordOffset: 0, pageIndex: nil)
    }

    public func selectPDFPage(_ pageIndex: Int) async {
        guard let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        let clamped = min(max(pageIndex, 0), meta.pageCount - 1)
        activePDFPageIndex = clamped
        let frac = PDFInspector.fraction(forPage: clamped, pageCount: meta.pageCount)
        await recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
    }

    public func recordProgress(spine: Int, fraction: Double, wordOffset: Int?, pageIndex: Int?) async {
        guard var book = activeBook else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(readingStartAt)))
        readingStartAt = Date()
        let next = ReadingLocator(
            spine: spine,
            fraction: fraction,
            wordOffset: wordOffset,
            pageIndex: pageIndex,
            updatedAt: Date()
        )
        do {
            let merged = try await store.saveLocator(
                bookId: book.id,
                locator: next,
                enqueueSync: book.source == .homeServer,
                readingSeconds: elapsed,
                canonicalId: book.canonicalId
            )
            book.locator = merged
            activeBook = book
            if let idx = books.firstIndex(where: { $0.id == book.id }) {
                books[idx] = book
            }
            pendingOutboxCount = (try? await store.pendingSyncEvents().count) ?? 0
            if isServerConnected && elapsed >= 5 {
                await flushProgressOutbox()
            }
        } catch {
            bannerError = error.localizedDescription
        }
    }

    // MARK: - Local Files.app Import

    public func importLocalFile(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let isPDF = ext == "pdf"
            let format: BookFormat = isPDF ? .pdf : .epub
            let id = "local-\(abs(url.lastPathComponent.hashValue))-\(data.count)"

            var title = url.deletingPathExtension().lastPathComponent
            var author = "Imported"
            var canonicalId: String?
            var summary = ""

            if isPDF {
                if let meta = PDFInspector.inspect(data: data, fallbackTitle: title) {
                    title = meta.title
                    author = meta.author
                    canonicalId = meta.canonicalId
                    summary = String(meta.frontMatterText.prefix(240))
                }
            } else {
                let doc = try EPUBParser.parse(data: data)
                title = doc.title
                author = doc.author
                canonicalId = doc.canonicalId
            }

            let storedURL = try await store.storeOfflineBookData(data, bookId: id, format: format)
            var point: MapPoint?
            if let cid = canonicalId {
                point = await resolveManifoldCoordinate(for: cid)
            }

            let item = BookItem(
                id: id,
                canonicalId: canonicalId,
                title: title,
                author: author,
                format: format,
                source: .localImport,
                genre: "Imported",
                summary: summary,
                shelfNames: ["Imported"],
                bytes: Int64(data.count),
                isOfflineCached: true,
                localFilePath: storedURL.path,
                point: point,
                lastOpenedAt: Date()
            )
            try await store.upsertBooks([item])
            books = visibleLibraryBooks(from: try await store.listBooks())
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            await openBook(item, switchTab: true)
        } catch {
            bannerError = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Offline Caching & Eviction

    public func downloadForOffline(_ book: BookItem) async {
        guard isBusyBookId == nil else { return }
        isBusyBookId = book.id
        defer { isBusyBookId = nil }

        do {
            let data: Data
            if book.source == .homeServer && !serverURL.isEmpty {
                data = try await HomeLibraryClient.downloadBook(baseURL: serverURL, bookId: book.id)
                if book.notesVersion != nil {
                    let notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: serverURL, bookId: book.id)) ?? []
                    if !notes.isEmpty {
                        try await store.saveMarginNotes(bookId: book.id, notes: notes)
                        if activeBook?.id == book.id { activeNotes = notes }
                    }
                }
            } else if let cid = book.canonicalId,
                      let dlURL = URL(string: book.epubURL ?? "") ?? OpenAccessResolver.directDownloadURL(for: cid) {
                let (oaData, _) = try await URLSession.shared.data(from: dlURL)
                data = oaData
            } else if book.canonicalId == "gutenberg:84" {
                data = try SampleShowcaseEPUB.buildFrankensteinSampleData()
            } else {
                throw HomeLibraryError.emptyPayload
            }

            let url = try await store.storeOfflineBookData(data, bookId: book.id, format: book.format == .article ? .pdf : book.format)
            var updated = book
            updated.isOfflineCached = true
            updated.localFilePath = url.path
            updated.bytes = Int64(data.count)
            try await store.upsertBooks([updated])
            books = visibleLibraryBooks(from: try await store.listBooks())
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            if activeBook?.id == book.id {
                activeBook = updated
            }
        } catch {
            bannerError = "Download failed: \(error.localizedDescription)"
        }
    }

    public func fetchOpenAccessBook(_ book: BookItem, from url: URL) async {
        var copy = book
        copy.epubURL = url.absoluteString
        await downloadForOffline(copy)
        if let updated = books.first(where: { $0.id == book.id }),
           let path = updated.localFilePath,
           FileManager.default.fileExists(atPath: path) {
            loadLocalDocument(url: URL(fileURLWithPath: path), book: updated)
        }
    }

    public func evictOfflineBook(_ book: BookItem) async {
        do {
            try await store.evictOfflineBook(bookId: book.id)
            books = visibleLibraryBooks(from: try await store.listBooks())
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            if activeBook?.id == book.id {
                activeBook?.isOfflineCached = false
                activeBook?.localFilePath = nil
            }
        } catch {
            bannerError = error.localizedDescription
        }
    }

    // MARK: - Highlight -> Cohort Handoff

    public func prepareCohortDraft(quote: String) {
        guard let book = activeBook else { return }
        cohortDraftNote = ""
        pendingCohortDraft = CohortCardDraft(
            sourceBookId: book.id,
            canonicalId: book.canonicalId,
            sourceTitle: book.title,
            quote: quote,
            promptHint: "Key concept from \(book.title)",
            tags: ["reader", book.genre.lowercased().replacingOccurrences(of: " ", with: "-")]
        )
    }

    public func sendDraftToCohort(_ draft: CohortCardDraft, note: String) async -> URL? {
        guard let book = activeBook else { return nil }
        let highlight = ReadingHighlight(
            bookId: book.id,
            canonicalId: book.canonicalId,
            bookTitle: book.title,
            spine: activeEPUBSpineIndex,
            quote: draft.quote,
            note: note,
            sentToCohort: true
        )
        try? await store.saveHighlight(highlight)
        pendingCohortDraft = nil

        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dropDir = appSupport.appendingPathComponent("CohortReader/cohort-handoff", isDirectory: true)
            _ = try? CohortHandoff.writeDropFile(for: draft, in: dropDir)
        }
        lastHandoffMessage = "Staged card seed for Cohort (\(draft.sourceTitle))"
        return CohortHandoff.makeDraftURL(for: draft)
    }

    // MARK: - Manifold & Home Server Sync

    public func refreshManifold(silent: Bool = false) async {
        defaults.set(manifoldHubURL, forKey: "cohortReader.manifoldHub")
        do {
            let snap = try await ManifoldReaderClient.fetchSnapshot(hubBase: manifoldHubURL)
            if !snap.works.isEmpty { manifoldWorks = snap.works }
            if !snap.lenses.isEmpty {
                lenses = snap.lenses
                if !lenses.contains(where: { $0.id == selectedLensId }), let first = lenses.first {
                    selectedLensId = first.id
                }
            }
        } catch {
            if !silent {
                bannerError = "Manifold sync failed: \(error.localizedDescription)"
            }
        }
    }

    public func resolveManifoldCoordinate(for canonicalId: String) async -> MapPoint? {
        if let local = manifoldWorks.first(where: { $0.workId == canonicalId }) {
            return MapPoint(x: local.x, y: local.y)
        }
        let prefix = ManifoldReaderClient.workShardPrefix(canonicalId)
        do {
            let (raw, works): (Data, [ManifoldReaderWork])
            if let cached = try? await store.loadShardCache(prefix: prefix) {
                raw = cached
                struct ShardEnv: Decodable { var works: [ManifoldReaderWork] }
                works = (try? JSONDecoder().decode(ShardEnv.self, from: raw).works) ?? []
            } else {
                let fetched = try await ManifoldReaderClient.fetchShard(prefix: prefix, hubBase: manifoldHubURL)
                raw = fetched.rawData
                works = fetched.works
                try? await store.saveShardCache(prefix: prefix, jsonData: raw)
            }
            shardCacheHits += 1
            if let hit = works.first(where: { $0.workId == canonicalId }) {
                return MapPoint(x: hit.x, y: hit.y)
            }
        } catch {
            // Keep offline seamlessly
        }
        return nil
    }

    public func connectHomeServer() async {
        await syncServerCatalog(silent: false)
    }

    public func syncServerCatalog(silent: Bool = false) async {
        let clean = ReaderKeychain.normalizedServer(serverURL)
        guard !clean.isEmpty else { return }
        serverURL = clean
        defaults.set(clean, forKey: "cohortReader.serverURL")
        if !serverPassphrase.isEmpty {
            ReaderKeychain.savePassword(serverPassphrase, server: clean)
        }

        do {
            let name = try await HomeLibraryClient.signIn(baseURL: clean, password: serverPassphrase)
            let catalog = try await HomeLibraryClient.fetchHome(baseURL: clean)
            try await store.upsertBooks(catalog.items)
            for item in catalog.items {
                if let loc = item.locator {
                    _ = try? await store.saveLocator(bookId: item.id, locator: loc, enqueueSync: false)
                }
            }
            books = visibleLibraryBooks(from: try await store.listBooks())
            shelves = catalog.shelves.isEmpty ? shelves : catalog.shelves
            if catalog.shelves.isEmpty { rebuildShelves() }
            isServerConnected = true
            serverName = name
            serverStatusMessage = "\(name) · \(catalog.items.count) works"
            await flushProgressOutbox()
            if !manifoldSyncedOnce {
                manifoldSyncedOnce = true
                Task { await self.refreshManifold(silent: true) }
            }
            if autoDownloadEnabled {
                autoDownloadTask?.cancel()
                autoDownloadTask = Task { await self.prefetchLikelyReads() }
            }
        } catch {
            isServerConnected = false
            serverStatusMessage = "Disconnected"
            if !silent {
                bannerError = error.localizedDescription
            }
        }
    }

    public func flushProgressOutbox() async {
        guard isServerConnected, !serverURL.isEmpty else { return }
        do {
            let pending = try await store.pendingSyncEvents()
            guard !pending.isEmpty else { return }
            _ = try await HomeLibraryClient.pushProgress(baseURL: serverURL, events: pending)
            try await store.markSyncEventsDelivered(ids: pending.map(\.id))
            pendingOutboxCount = 0
        } catch {
            // Retain in SQLite outbox until back online
        }
    }

    public func runSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if isServerConnected && !q.isEmpty {
            isSearchingServer = true
            defer { isSearchingServer = false }
            if let remote = try? await HomeLibraryClient.search(baseURL: serverURL, query: q, limit: 35) {
                serverSearchResults = remote
                return
            }
        }
        serverSearchResults = []
    }

    public func rankedLensWorks() -> [RankedWork] {
        guard let lens = lenses.first(where: { $0.id == selectedLensId }) else {
            return manifoldWorks.map { RankedWork(work: $0, score: 0.5) }
        }
        return LensRanker.rank(works: manifoldWorks, lens: lens)
    }

    public func selectedMapWork() -> ManifoldReaderWork? {
        manifoldWorks.first(where: { $0.workId == selectedMapWorkId }) ?? manifoldWorks.first
    }
}
