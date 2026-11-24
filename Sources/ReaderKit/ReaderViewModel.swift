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

import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct OpenReaderTab: Identifiable, Sendable, Hashable {
    public var id: String
    public var book: BookItem
    public var isTemporaryQuickOpen: Bool

    public init(id: String? = nil, book: BookItem, isTemporaryQuickOpen: Bool = false) {
        self.id = id ?? book.id
        self.book = book
        self.isTemporaryQuickOpen = isTemporaryQuickOpen
    }
}

public struct InBookSearchHit: Identifiable, Sendable, Hashable {
    public var id: String
    public var spineIndex: Int
    public var chapterTitle: String
    public var snippet: String

    public init(id: String, spineIndex: Int, chapterTitle: String, snippet: String) {
        self.id = id
        self.spineIndex = spineIndex
        self.chapterTitle = chapterTitle
        self.snippet = snippet
    }
}

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

public enum ActiveReaderSheet: Identifiable, Sendable {
    case settings
    case marginNote(MarginNote)
    case discovery(ManifoldReaderWork)
    case cohortDraft(CohortCardDraft)
    case toc
    case typography
    case pdfSign

    public var id: String {
        switch self {
        case .settings: return "settings"
        case .marginNote(let note): return "note:\(note.id)"
        case .discovery(let work): return "discovery:\(work.workId)"
        case .cohortDraft(let draft): return "cohort:\(draft.sourceBookId):\(draft.quote.prefix(24))"
        case .toc: return "toc"
        case .typography: return "typography"
        case .pdfSign: return "pdf-sign"
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
    public var shelfSortOrder: ShelfSortOrder = .recent

    // Manifold coordinates & Reading Lenses
    public var manifoldWorks: [ManifoldReaderWork] = ShowcaseCatalog.works
    public var lenses: [ReaderLens] = ShowcaseCatalog.lenses
    public var selectedLensId: String = ShowcaseCatalog.lenses.first?.id ?? ""
    public var selectedMapWorkId: String = "isbn:9780300078152"
    public var mapZoom: CGFloat = 1.0
    public var mapPan: CGSize = .zero
    public var mapGestureStartZoom: CGFloat?
    public var mapGestureStartPan: CGSize?
    public var shardCacheHits: Int = 0
    public var manifoldHubURL: String
    public var wishlistIds: Set<String> = []
    public var serverOwnedWorkIds: [String: String] = [:]

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

    // Active Reader Session & Multi-Document Tabs
    public var openTabs: [OpenReaderTab] = []
    public var activeBook: BookItem?
    public var activeEPUB: EPUBDocument?
    public var activeEPUBSpineIndex: Int = 0
    public var activePDFURL: URL?
    public var activePDFMetadata: PDFMetadataSummary?
    public var activePDFPageIndex: Int = 0
    public var activeNotes: [MarginNote] = []
    public var tocSegment: Int = 0
    public var tocSearchQuery: String = ""
    public var inBookMatches: [InBookSearchHit] = []
    public var scrubChapterTarget: Int?
    public var scrubPDFPageTarget: Int?
    public var isReaderChromeHidden: Bool = false
    public var typography: ReaderTypography = .default
    public var activeHighlights: [ReadingHighlight] = []
    public var activeSelectionText: String = ""
    public var cohortDraftNote: String = ""
    public var isImporterPresented: Bool = false
    public var lastHandoffMessage: String?

    // Lightweight PDF Reader & Vector Signing
    public var pdfAppearance: PDFPaperAppearance = .auto
    public var pdfAutoCropEnabled: Bool = false
    public var pdfTwoColumnMode: Bool = false
    public var pdfTwoColumnStep: Int = 0
    public var pdfDetectedColumnCount: Int = 1
    public var pdfZoomScale: Double = 1.0
    public var pdfJumpBackStack: [Int] = []
    public var pdfJumpForwardStack: [Int] = []
    public var activePDFSearchHighlight: String?
    public var activePDFPageFrame: CGRect = .zero

    public var savedSignatures: [SavedSignature] = []
    public var signatureDraftStrokes: [[SignaturePoint]] = []
    public var signatureDraftCurrentStroke: [SignaturePoint] = []
    public var signatureDraftInk: SignatureInkColor = .navy
    public var signatureDraftTypedText: String = ""
    public var signatureDraftMode: Int = 0
    public var signatureDraftCustomText: String = ""
    public var pendingPDFStamps: [PDFStampPlacement] = []
    public var selectedStampId: String?
    public var stampDragOriginRect: CodableRect?
    public var stampResizeOriginRect: CodableRect?
    public var isExportingSignedPDF: Bool = false
    public var exportedSignedPDFData: Data?
    public var exportedSignedFilename: String = "document-signed.pdf"
    public var lastSignedSavePath: String?
    public var localLibraryMirrorPath: String = ""
    public var signatureStoreURL: URL?

    // Search
    public var searchQuery: String = ""
    public var searchScope: SearchScope = .all
    public var serverSearchResults: [BookItem] = []
    public var isSearchingServer: Bool = false

    // Settings, Sheets & Errors
    public var activeSheet: ActiveReaderSheet?
    public var openingBookId: String?
    public var offlineBytes: Int64 = 0
    public var bannerError: String?
    public var isBusyBookId: String?

    private var readingStartAt: Date = Date()
    private var autoDownloadTask: Task<Void, Never>?
    private var openBookTask: Task<Void, Never>?
    private var pdfSearchTask: Task<Void, Never>?
    private var openBookGeneration: Int = 0
    private var manifoldSyncedOnce: Bool = false
    private var allowBackgroundSync: Bool = true
    private var quickOpenScopedURLs: [String: URL] = [:]
    private var localMirrorScopedURL: URL?

    public init(store: ReaderStore, defaults: UserDefaults = .standard, signatureStoreURL: URL? = SignatureStore.defaultURL()) {
        self.store = store
        self.defaults = defaults
        self.signatureStoreURL = signatureStoreURL
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
        if let rawSort = defaults.string(forKey: "cohortReader.shelfSortOrder"),
           let parsedSort = ShelfSortOrder(rawValue: rawSort) {
            self.shelfSortOrder = parsedSort
        }
        if let rawAppearance = defaults.string(forKey: "cohortReader.pdfAppearance"),
           let parsedAppearance = PDFPaperAppearance(rawValue: rawAppearance) {
            self.pdfAppearance = parsedAppearance
        }
        self.pdfAutoCropEnabled = defaults.bool(forKey: "cohortReader.pdfAutoCropEnabled")
        self.savedSignatures = SignatureStore.load(from: signatureStoreURL)
        #if os(macOS)
        if let bmData = defaults.data(forKey: "cohortReader.localMirrorBookmark") {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bmData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if resolved.startAccessingSecurityScopedResource() {
                    self.localMirrorScopedURL = resolved
                }
                self.localLibraryMirrorPath = resolved.path
            }
        }
        #endif
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
        defaults.set(shelfSortOrder.rawValue, forKey: "cohortReader.shelfSortOrder")
        defaults.set(pdfAppearance.rawValue, forKey: "cohortReader.pdfAppearance")
        defaults.set(pdfAutoCropEnabled, forKey: "cohortReader.pdfAutoCropEnabled")
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
        var source = raw
        if let dashRange = raw.range(of: "—") {
            let before = raw[..<dashRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = raw[dashRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let beforeWords = before.split(whereSeparator: \.isWhitespace).map(String.init)
            let firstLower = beforeWords.first?.lowercased() ?? ""
            let startsWithArticle = ["the", "a", "an"].contains(firstLower)
            if (2...4).contains(beforeWords.count),
               !startsWithArticle,
               before.rangeOfCharacter(from: .decimalDigits) == nil,
               after.count >= 4 {
                source = after
            }
        }
        let head = source.components(separatedBy: CharacterSet(charactersIn: ":—")).first ?? source
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
        if let mappedBookId = serverOwnedWorkIds[work.workId],
           let mapped = books.first(where: { $0.id == mappedBookId }) {
            return mapped
        }
        if let exact = books.first(where: { $0.canonicalId == work.workId }) {
            return exact
        }
        let targetKey = Self.normalizedTitleKey(work.title)
        guard targetKey.count >= 4 else { return nil }
        return books.first { book in
            let bKey = Self.normalizedTitleKey(book.title)
            return bKey == targetKey || (bKey.count >= targetKey.count + 2 && bKey.hasPrefix(targetKey + " "))
        }
    }

    public var continueReadingBook: BookItem? {
        books.first { $0.isInProgress && ($0.isOfflineCached || $0.source == .homeServer) }
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

    public func transitionSheet(to next: ActiveReaderSheet) {
        if activeSheet != nil {
            activeSheet = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                self.activeSheet = next
            }
        } else {
            activeSheet = next
        }
    }

    public func requestFileImport() {
        let hadSheet = activeSheet != nil
        activeSheet = nil
        if hadSheet {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                self.isImporterPresented = true
            }
        } else {
            isImporterPresented = true
        }
    }

    public func openOrInspect(_ work: ManifoldReaderWork) async {
        if let owned = ownedBook(for: work) {
            await openBook(owned)
        } else {
            activeSheet = .discovery(work)
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
        await downloadForOffline(book, forceImmediate: true)
        if let updated = books.first(where: { $0.id == book.id }), updated.isOfflineCached {
            activeSheet = nil
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
            if book.isInProgress { pts += 1000 }
            if book.notesVersion != nil { pts += 500 }
            if book.shelfNames.contains(where: { $0.caseInsensitiveCompare("Reading") == .orderedSame }) { pts += 300 }
            pts += (book.format == .epub ? 150 : 40)
            if !book.shelfNames.isEmpty { pts += 80 }
            return pts
        }
        return eligible.sorted { a, b in
            if a.isInProgress != b.isInProgress {
                return a.isInProgress
            }
            if a.isInProgress && b.isInProgress {
                let da = a.locator?.updatedAt ?? a.lastOpenedAt ?? .distantPast
                let db = b.locator?.updatedAt ?? b.lastOpenedAt ?? .distantPast
                if da != db { return da > db }
                if abs(a.effectiveProgress - b.effectiveProgress) > 0.0001 {
                    return a.effectiveProgress > b.effectiveProgress
                }
            }
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
            .filter(\.isInProgress)
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

    public func manifoldWork(for book: BookItem) -> ManifoldReaderWork? {
        if let mappedWorkId = serverOwnedWorkIds.first(where: { $0.value == book.id })?.key,
           let mapped = manifoldWorks.first(where: { $0.workId == mappedWorkId }) {
            return mapped
        }
        if let cid = book.canonicalId, let exact = manifoldWorks.first(where: { $0.workId == cid }) {
            return exact
        }
        let targetKey = Self.normalizedTitleKey(book.title)
        guard targetKey.count >= 4 else { return nil }
        return manifoldWorks.first { work in
            let wKey = Self.normalizedTitleKey(work.title)
            return wKey == targetKey
                || (wKey.count >= targetKey.count + 2 && wKey.hasPrefix(targetKey + " "))
                || (targetKey.count >= wKey.count + 2 && targetKey.hasPrefix(wKey + " "))
        }
    }

    public func focusWorkInAtlas(_ work: ManifoldReaderWork) {
        selectedMapWorkId = work.workId
        mapZoom = 1.0
        mapPan = .zero
        activeSheet = nil
        selectedTab = .map
    }

    public func focusBookInAtlas(_ book: BookItem) {
        if let work = manifoldWork(for: book) {
            focusWorkInAtlas(work)
        }
    }

    public var wishlistedDiscoveryWorks: [ManifoldReaderWork] {
        manifoldWorks.filter { wishlistIds.contains($0.workId) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public var filteredShelfBooks: [BookItem] {
        let base: [BookItem]
        switch activeShelfFilter {
        case "All":
            base = books
        case "Reading", "Reading Now":
            base = books.filter(\.isInProgress)
        case "Offline":
            base = books.filter(\.isOfflineCached)
        case "Saved":
            base = books.filter { $0.canonicalId.map(wishlistIds.contains) == true }
        case "Papers":
            base = books.filter { $0.format == .article || ($0.canonicalId?.hasPrefix("doi:") ?? false) || ($0.canonicalId?.hasPrefix("pmid:") ?? false) || ($0.canonicalId?.hasPrefix("arxiv:") ?? false) }
        case "Books":
            base = books.filter { $0.format == .epub || $0.genre == "Nonfiction" || $0.genre == "Literature" || ($0.canonicalId?.hasPrefix("gutenberg:") ?? false) || ($0.canonicalId?.hasPrefix("isbn:") ?? false) }
        default:
            base = books.filter { $0.genre == activeShelfFilter || $0.shelfNames.contains(activeShelfFilter) }
        }

        switch shelfSortOrder {
        case .recent:
            return base
        case .title:
            return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:
            return base.sorted {
                let cmp = $0.author.localizedCaseInsensitiveCompare($1.author)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .progress:
            return base.sorted {
                let fa = $0.effectiveProgress
                let fb = $1.effectiveProgress
                if abs(fa - fb) > 0.0001 { return fa > fb }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    // MARK: - Open & Read

    public var activeTabIsQuickOpen: Bool {
        guard let activeId = activeBook?.id else { return false }
        return openTabs.first(where: { $0.id == activeId })?.isTemporaryQuickOpen == true
    }

    private func upsertOpenTab(for book: BookItem, isTemporaryQuickOpen: Bool? = nil) {
        if let idx = openTabs.firstIndex(where: { $0.id == book.id }) {
            let temp = isTemporaryQuickOpen ?? openTabs[idx].isTemporaryQuickOpen
            openTabs[idx] = OpenReaderTab(id: book.id, book: book, isTemporaryQuickOpen: temp)
        } else {
            openTabs.append(OpenReaderTab(id: book.id, book: book, isTemporaryQuickOpen: isTemporaryQuickOpen ?? false))
        }
    }

    public func localMirrorFileURL(for book: BookItem) -> URL? {
        guard !localLibraryMirrorPath.isEmpty else { return nil }
        let root = URL(fileURLWithPath: localLibraryMirrorPath, isDirectory: true)
        let subdirs: [String] = (book.format == .epub) ? ["books"] : ["pdfs", "papers"]
        let ext = (book.format == .epub) ? "epub" : "pdf"
        for sub in subdirs {
            let candidate = root.appendingPathComponent(sub, isDirectory: true)
                .appendingPathComponent("\(book.id).\(ext)")
            if FileManager.default.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    #if os(macOS)
    public func setLocalLibraryMirror(url: URL) {
        localMirrorScopedURL?.stopAccessingSecurityScopedResource()
        localMirrorScopedURL = nil
        if let bm = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bm, forKey: "cohortReader.localMirrorBookmark")
        }
        if url.startAccessingSecurityScopedResource() {
            localMirrorScopedURL = url
        }
        localLibraryMirrorPath = url.path
    }

    public func clearLocalLibraryMirror() {
        localMirrorScopedURL?.stopAccessingSecurityScopedResource()
        localMirrorScopedURL = nil
        defaults.removeObject(forKey: "cohortReader.localMirrorBookmark")
        localLibraryMirrorPath = ""
    }

    public func chooseLocalLibraryMirrorWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link Mirror"
        panel.message = "Choose your local PaperLibrary folder so the Mac app opens owned books and PDFs directly from disk."
        if panel.runModal() == .OK, let url = panel.url {
            setLocalLibraryMirror(url: url)
        }
    }

    public func openExternalFileWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.pdf]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        panel.allowedContentTypes = types
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await self.quickOpenExternalFile(from: url) }
        }
    }
    #endif

    public func quickOpenExternalFile(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        let ext = url.pathExtension.lowercased()
        let isPDF = ext != "epub"
        let format: BookFormat = isPDF ? .pdf : .epub
        let id = "quick-\(abs(url.path.hashValue))"
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var title = fallbackTitle
        var author = "Quick Open"
        var canonicalId: String?
        var summary = ""

        if isPDF {
            let meta = await Task.detached(priority: .userInitiated) {
                PDFInspector.inspect(url: url)
            }.value
            if let meta {
                title = meta.title
                author = meta.author
                canonicalId = meta.canonicalId
                summary = String(meta.frontMatterText.prefix(240))
            }
        } else {
            let doc = try? await Task.detached(priority: .userInitiated) {
                try EPUBParser.parse(url: url)
            }.value
            if let doc {
                title = doc.title
                author = doc.author
                canonicalId = doc.canonicalId
            }
        }

        if accessed {
            quickOpenScopedURLs[id]?.stopAccessingSecurityScopedResource()
            quickOpenScopedURLs[id] = url
        }

        let quickBook = BookItem(
            id: id,
            canonicalId: canonicalId,
            title: title,
            author: author,
            format: format,
            source: .localImport,
            genre: isPDF ? "PDF Document" : "EPUB",
            summary: summary,
            shelfNames: [],
            bytes: fileSize,
            isOfflineCached: true,
            localFilePath: url.path,
            lastOpenedAt: Date()
        )
        upsertOpenTab(for: quickBook, isTemporaryQuickOpen: true)
        await openBook(quickBook, switchTab: true)
    }

    public func promoteActiveQuickOpenToLibrary() async {
        guard let book = activeBook,
              activeTabIsQuickOpen,
              let path = book.localFilePath else { return }
        let tempId = book.id
        await importLocalFile(from: URL(fileURLWithPath: path))
        if activeBook?.id != tempId {
            openTabs.removeAll { $0.id == tempId }
            quickOpenScopedURLs.removeValue(forKey: tempId)?.stopAccessingSecurityScopedResource()
        }
    }

    public func selectTab(id: String) async {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        if activeBook?.id == tab.book.id {
            selectedTab = .read
            return
        }
        await openBook(tab.book, switchTab: true)
    }

    public func closeTab(id: String) async {
        let wasActive = activeBook?.id == id
        let idx = openTabs.firstIndex(where: { $0.id == id })
        openTabs.removeAll { $0.id == id }
        quickOpenScopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()

        guard wasActive else { return }
        openBookGeneration += 1
        openBookTask?.cancel()
        openBookTask = nil
        openingBookId = nil
        pdfSearchTask?.cancel()
        pendingPDFStamps = []
        selectedStampId = nil
        pdfJumpBackStack = []
        pdfJumpForwardStack = []
        activePDFSearchHighlight = nil

        if !openTabs.isEmpty {
            let nextIdx = min(idx ?? 0, openTabs.count - 1)
            await openBook(openTabs[nextIdx].book, switchTab: true)
        } else {
            activeBook = nil
            activeEPUB = nil
            activePDFURL = nil
            activePDFMetadata = nil
            selectedTab = .shelf
        }
    }

    public func cancelActiveOpen() {
        openBookGeneration += 1
        openBookTask?.cancel()
        openBookTask = nil
        openingBookId = nil
        if selectedTab == .read && activeEPUB == nil && activePDFURL == nil {
            selectedTab = .shelf
        }
    }

    public func openBook(_ book: BookItem, switchTab: Bool = true) async {
        autoDownloadTask?.cancel()
        autoDownloadActiveTitle = nil
        openBookTask?.cancel()
        pdfSearchTask?.cancel()
        openBookGeneration += 1
        let generation = openBookGeneration

        bannerError = nil
        readingStartAt = Date()
        isReaderChromeHidden = false
        activeSelectionText = ""
        activeBook = book
        upsertOpenTab(for: book)
        activeEPUB = nil
        activePDFURL = nil
        activePDFMetadata = nil
        pendingPDFStamps = []
        selectedStampId = nil
        pdfJumpBackStack = []
        pdfJumpForwardStack = []
        activePDFSearchHighlight = nil
        pdfZoomScale = 1.0
        pdfTwoColumnMode = false
        pdfTwoColumnStep = 0
        pdfDetectedColumnCount = 1
        activePDFPageFrame = .zero
        openingBookId = book.id
        if switchTab {
            selectedTab = .read
        }
        if !activeTabIsQuickOpen {
            defaults.set(book.id, forKey: "cohortReader.lastBookId")
        }
        activeHighlights = (try? await store.listHighlights(bookId: book.id)) ?? []
        activeNotes = (try? await store.loadMarginNotes(bookId: book.id)) ?? []
        tocSearchQuery = ""
        inBookMatches = []
        scrubChapterTarget = nil
        scrubPDFPageTarget = nil
        if activeNotes.isEmpty && book.canonicalId == "gutenberg:84" {
            activeNotes = ShowcaseCatalog.sampleMarginNotes
        }

        if let work = manifoldWork(for: book) {
            selectedMapWorkId = work.workId
        }

        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            defer {
                if self.openBookGeneration == generation {
                    self.openingBookId = nil
                }
            }
            guard !Task.isCancelled, self.openBookGeneration == generation else { return }

            if let localPath = book.localFilePath, FileManager.default.fileExists(atPath: localPath) {
                let url = URL(fileURLWithPath: localPath)
                await self.loadLocalDocument(url: url, book: book, generation: generation)
            } else if let mirrorURL = self.localMirrorFileURL(for: book) {
                await self.loadLocalDocument(url: mirrorURL, book: book, generation: generation)
            } else if book.source == .homeServer && self.isServerConnected {
                await self.downloadForOffline(book, forceImmediate: true)
                guard !Task.isCancelled, self.openBookGeneration == generation else { return }
                if let updated = self.books.first(where: { $0.id == book.id }),
                   let localPath = updated.localFilePath,
                   FileManager.default.fileExists(atPath: localPath) {
                    await self.loadLocalDocument(url: URL(fileURLWithPath: localPath), book: updated, generation: generation)
                }
            } else if let cid = book.canonicalId,
                      let dlURL = URL(string: book.epubURL ?? "") ?? OpenAccessResolver.directDownloadURL(for: cid) {
                await self.fetchOpenAccessBook(book, from: dlURL, generation: generation)
            } else if book.canonicalId == "gutenberg:84" {
                if let data = try? SampleShowcaseEPUB.buildFrankensteinSampleData(),
                   let url = try? await self.store.storeOfflineBookData(data, bookId: book.id, format: .epub) {
                    await self.loadLocalDocument(url: url, book: book, generation: generation)
                }
            } else {
                self.bannerError = "Offline copy not available yet."
            }

            guard !Task.isCancelled, self.openBookGeneration == generation else { return }
            if self.activeNotes.isEmpty && book.source == .homeServer && book.notesVersion != nil && self.isServerConnected && !self.serverURL.isEmpty {
                let notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: self.serverURL, bookId: book.id)) ?? []
                if !notes.isEmpty && self.openBookGeneration == generation {
                    try? await self.store.saveMarginNotes(bookId: book.id, notes: notes)
                    self.activeNotes = notes
                }
            }
        }
        openBookTask = task
        await task.value
    }

    public func saveTypography() {
        if let data = try? JSONEncoder().encode(typography) {
            defaults.set(data, forKey: "cohortReader.typography")
        }
    }

    public func saveQuickHighlight(quote: String, note: String = "") async {
        guard let book = activeBook else { return }
        let pageOrSpine = activePDFURL != nil ? activePDFPageIndex : activeEPUBSpineIndex
        let highlight = ReadingHighlight(
            bookId: book.id,
            canonicalId: book.canonicalId,
            bookTitle: book.title,
            spine: pageOrSpine,
            quote: quote,
            note: note,
            sentToCohort: false
        )
        try? await store.saveHighlight(highlight)
        activeHighlights = (try? await store.listHighlights(bookId: book.id)) ?? []
        activeSelectionText = ""
        lastHandoffMessage = "Saved highlight in \(book.title)"
    }

    public func deleteHighlight(_ highlight: ReadingHighlight) async {
        try? await store.deleteHighlight(id: highlight.id)
        activeHighlights.removeAll { $0.id == highlight.id }
    }

    public func runInBookSearch() {
        let q = tocSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        pdfSearchTask?.cancel()
        if let pdfURL = activePDFURL, activeEPUB == nil {
            guard q.count >= 2 else {
                inBookMatches = []
                activePDFSearchHighlight = nil
                return
            }
            activePDFSearchHighlight = q
            pdfSearchTask = Task {
                await self.runPDFSearchNow(url: pdfURL, query: q)
            }
            return
        }

        guard q.count >= 2, let doc = activeEPUB else {
            inBookMatches = []
            return
        }
        var results: [InBookSearchHit] = []
        for idx in 0..<doc.spineHrefs.count {
            guard let chapter = doc.chapter(at: idx) else { continue }
            let text = chapter.plainText
            var searchStart = text.startIndex
            while results.count < 30,
                  let found = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                let rawStart = text.index(found.lowerBound, offsetBy: -36, limitedBy: text.startIndex) ?? text.startIndex
                let rawEnd = text.index(found.upperBound, offsetBy: 56, limitedBy: text.endIndex) ?? text.endIndex
                let slice = text[rawStart..<rawEnd]
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = rawStart > text.startIndex ? "..." : ""
                let suffix = rawEnd < text.endIndex ? "..." : ""
                results.append(
                    InBookSearchHit(
                        id: "\(idx):\(results.count)",
                        spineIndex: idx,
                        chapterTitle: chapter.title,
                        snippet: "\(prefix)\(slice)\(suffix)"
                    )
                )
                searchStart = found.upperBound
            }
            if results.count >= 30 { break }
        }
        inBookMatches = results
    }

    public func runPDFSearchNow(url: URL? = nil, query: String? = nil) async {
        let q = (query ?? tocSearchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let targetURL = url ?? activePDFURL else {
            inBookMatches = []
            activePDFSearchHighlight = nil
            return
        }
        activePDFSearchHighlight = q
        let matches = await Task.detached(priority: .userInitiated) {
            PDFSearch.search(url: targetURL, query: q, limit: 40)
        }.value
        guard !Task.isCancelled else { return }
        inBookMatches = matches.map {
            InBookSearchHit(
                id: $0.id,
                spineIndex: $0.pageIndex,
                chapterTitle: "Page \($0.pageIndex + 1)",
                snippet: $0.snippet
            )
        }
    }

    public func estimatedChapterMinutesRemaining() -> Int? {
        guard let ch = currentChapter(), ch.wordCount >= 40 else { return nil }
        let loc = activeBook?.locator
        let frac = (loc?.spine == ch.index) ? min(max(loc?.fraction ?? 0, 0), 1) : 0
        let remainingWords = max(0, Int(Double(ch.wordCount) * (1.0 - frac)))
        guard remainingWords > 0 else { return 0 }
        return max(1, Int(ceil(Double(remainingWords) / 230.0)))
    }

    private func loadLocalDocument(url: URL, book: BookItem, generation: Int? = nil) async {
        guard generation == nil || (generation == openBookGeneration && !Task.isCancelled) else { return }
        if book.format == .epub {
            do {
                let doc = try await Task.detached(priority: .userInitiated) {
                    try EPUBParser.parse(url: url)
                }.value
                guard generation == nil || (generation == openBookGeneration && !Task.isCancelled) else { return }
                activeEPUB = doc
                let spine = book.locator?.spine ?? 0
                activeEPUBSpineIndex = min(max(spine, 0), max(0, doc.spineHrefs.count - 1))
                if !AssetImageCache.shared.hasImage(forBookId: book.id),
                   let coverHref = doc.coverHref,
                   let coverData = doc.resourceData(forArchivePath: coverHref)?.data ?? doc.resources[coverHref] {
                    let bookId = book.id
                    Task {
                        await AssetImageCache.shared.registerLocalCover(data: coverData, bookId: bookId)
                    }
                }
            } catch {
                guard generation == nil || generation == openBookGeneration else { return }
                bannerError = "Failed to open EPUB: \(error.localizedDescription)"
            }
        } else {
            let meta = await Task.detached(priority: .userInitiated) {
                PDFInspector.inspect(url: url)
            }.value
            guard generation == nil || (generation == openBookGeneration && !Task.isCancelled) else { return }
            activePDFURL = url
            activePDFMetadata = meta
            if let count = meta?.pageCount, let loc = book.locator {
                activePDFPageIndex = loc.pageIndex ?? PDFInspector.pageIndex(forFraction: loc.effectiveProgress, pageCount: count)
            } else {
                activePDFPageIndex = 0
            }
            if !AssetImageCache.shared.hasImage(forBookId: book.id) {
                let bookId = book.id
                Task {
                    let pngData = await Task.detached(priority: .utility) {
                        PDFInspector.renderFirstPagePNG(url: url, maxDimension: 360)
                    }.value
                    if let pngData {
                        await AssetImageCache.shared.registerLocalCover(data: pngData, bookId: bookId)
                    }
                }
            }
        }
    }

    public func currentChapter() -> EPUBChapter? {
        activeEPUB?.chapter(at: activeEPUBSpineIndex)
    }

    public func currentChapterHTML(resolvedTheme: ReaderTheme? = nil) -> String {
        guard let chapter = currentChapter(),
              let raw = String(data: chapter.xhtmlData, encoding: .utf8) ?? String(data: chapter.xhtmlData, encoding: .isoLatin1) else {
            return ""
        }
        let chapterNotes = activeNotes.filter { $0.spine == chapter.index }
        let chapterHighlights = activeHighlights.filter { $0.spine == chapter.index }
        let loc = activeBook?.locator
        let frac = (loc?.spine == chapter.index) ? (loc?.fraction ?? 0) : 0
        let word = (loc?.spine == chapter.index) ? loc?.wordOffset : nil
        return EPUBHTMLComposer.composeChapterHTML(
            rawXHTML: raw,
            typography: typography,
            notes: chapterNotes,
            initialFraction: frac,
            initialWordOffset: word,
            resolvedTheme: resolvedTheme,
            highlights: chapterHighlights
        )
    }

    public func selectEPUBSpine(_ index: Int) async {
        guard let doc = activeEPUB, index >= 0, index < doc.spineHrefs.count else { return }
        activeEPUBSpineIndex = index
        await recordProgress(spine: index, fraction: 0, wordOffset: 0, pageIndex: nil)
    }

    public func selectPDFPage(_ pageIndex: Int, recordJump: Bool = false) async {
        guard let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        let clamped = min(max(pageIndex, 0), meta.pageCount - 1)
        if clamped != activePDFPageIndex {
            if recordJump || abs(clamped - activePDFPageIndex) > 1 {
                pdfJumpBackStack.append(activePDFPageIndex)
                if pdfJumpBackStack.count > 30 {
                    pdfJumpBackStack.removeFirst(pdfJumpBackStack.count - 30)
                }
                pdfJumpForwardStack = []
            }
        }
        activePDFPageIndex = clamped
        pdfTwoColumnStep = 0
        let frac = PDFInspector.fraction(forPage: clamped, pageCount: meta.pageCount)
        await recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
    }

    public func jumpBackInPDF() async {
        guard let prev = pdfJumpBackStack.popLast(),
              let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        pdfJumpForwardStack.append(activePDFPageIndex)
        let clamped = min(max(prev, 0), meta.pageCount - 1)
        activePDFPageIndex = clamped
        pdfTwoColumnStep = 0
        let frac = PDFInspector.fraction(forPage: clamped, pageCount: meta.pageCount)
        await recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
    }

    public func jumpForwardInPDF() async {
        guard let next = pdfJumpForwardStack.popLast(),
              let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        pdfJumpBackStack.append(activePDFPageIndex)
        let clamped = min(max(next, 0), meta.pageCount - 1)
        activePDFPageIndex = clamped
        pdfTwoColumnStep = 0
        let frac = PDFInspector.fraction(forPage: clamped, pageCount: meta.pageCount)
        await recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
    }

    public func stepPDFColumn(delta: Int) async {
        guard let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        if !pdfTwoColumnMode || pdfDetectedColumnCount < 2 {
            await selectPDFPage(activePDFPageIndex + delta)
            return
        }
        if delta > 0 {
            if pdfTwoColumnStep == 0 {
                pdfTwoColumnStep = 1
            } else if activePDFPageIndex + 1 < meta.pageCount {
                await selectPDFPage(activePDFPageIndex + 1)
                pdfTwoColumnStep = 0
            }
        } else if delta < 0 {
            if pdfTwoColumnStep == 1 {
                pdfTwoColumnStep = 0
            } else if activePDFPageIndex > 0 {
                await selectPDFPage(activePDFPageIndex - 1)
                pdfTwoColumnStep = 1
            }
        }
    }

    public func zoomInPDF() {
        pdfZoomScale = min(3.0, pdfZoomScale + 0.2)
    }

    public func zoomOutPDF() {
        pdfZoomScale = max(0.5, pdfZoomScale - 0.2)
    }

    public func resetPDFZoom() {
        pdfZoomScale = 1.0
    }

    public func setPDFAppearance(_ appearance: PDFPaperAppearance) {
        pdfAppearance = appearance
        savePreferences()
    }

    public func cyclePDFAppearance() {
        let all = PDFPaperAppearance.allCases
        if let idx = all.firstIndex(of: pdfAppearance) {
            pdfAppearance = all[(idx + 1) % all.count]
        } else {
            pdfAppearance = .auto
        }
        savePreferences()
    }

    public func togglePDFAutoCrop() {
        pdfAutoCropEnabled.toggle()
        savePreferences()
    }

    // MARK: - Lightweight Vector PDF Signing

    public func commitDraftStroke() {
        guard !signatureDraftCurrentStroke.isEmpty else { return }
        signatureDraftStrokes.append(signatureDraftCurrentStroke)
        signatureDraftCurrentStroke = []
    }

    public func undoDraftStroke() {
        if !signatureDraftStrokes.isEmpty {
            _ = signatureDraftStrokes.popLast()
        }
    }

    public func clearDraftSignature() {
        signatureDraftStrokes = []
        signatureDraftCurrentStroke = []
        signatureDraftTypedText = ""
    }

    public func saveAndPlaceDraftSignature() {
        let created: SavedSignature
        if signatureDraftMode == 1 {
            let trimmed = signatureDraftTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            created = SavedSignature(
                label: trimmed,
                strokes: [],
                typedText: trimmed,
                inkColor: signatureDraftInk,
                aspectRatio: max(1.8, min(4.2, Double(trimmed.count) * 0.32))
            )
        } else {
            var allStrokes = signatureDraftStrokes
            if !signatureDraftCurrentStroke.isEmpty {
                allStrokes.append(signatureDraftCurrentStroke)
            }
            guard !allStrokes.isEmpty else { return }
            created = SavedSignature(
                label: "Signature \(savedSignatures.count + 1)",
                strokes: allStrokes,
                typedText: nil,
                inkColor: signatureDraftInk,
                aspectRatio: 2.6
            )
        }
        savedSignatures.insert(created, at: 0)
        try? SignatureStore.save(savedSignatures, to: signatureStoreURL)
        clearDraftSignature()
        placeSavedSignature(created)
        activeSheet = nil
    }

    public func placeSavedSignature(_ sig: SavedSignature) {
        let width = 0.34
        let height = min(0.22, max(0.075, width / sig.aspectRatio * 0.95))
        let offset = Double(pendingPDFStamps.filter { $0.pageIndex == activePDFPageIndex }.count % 4) * 0.03
        let stamp = PDFStampPlacement(
            pageIndex: activePDFPageIndex,
            normalizedRect: CodableRect(
                x: min(0.62, 0.30 + offset),
                y: min(0.76, 0.64 + offset),
                width: width,
                height: height
            ),
            kind: .signature(sig)
        )
        pendingPDFStamps.append(stamp)
        selectedStampId = stamp.id
        activeSheet = nil
    }

    public func placeQuickTextStamp(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let width = min(0.42, max(0.14, Double(clean.count) * 0.019 + 0.06))
        let offset = Double(pendingPDFStamps.filter { $0.pageIndex == activePDFPageIndex }.count % 4) * 0.025
        let stamp = PDFStampPlacement(
            pageIndex: activePDFPageIndex,
            normalizedRect: CodableRect(
                x: min(0.55, 0.32 + offset),
                y: min(0.84, 0.77 + offset),
                width: width,
                height: 0.052
            ),
            kind: .text(clean, signatureDraftInk)
        )
        pendingPDFStamps.append(stamp)
        selectedStampId = stamp.id
        activeSheet = nil
    }

    public func deleteSavedSignature(id: String) {
        savedSignatures.removeAll { $0.id == id }
        try? SignatureStore.save(savedSignatures, to: signatureStoreURL)
    }

    public func updatePendingStamp(id: String, normalizedRect: CodableRect) {
        guard let idx = pendingPDFStamps.firstIndex(where: { $0.id == id }) else { return }
        let w = min(max(normalizedRect.width, 0.08), 0.92)
        let h = min(max(normalizedRect.height, 0.035), 0.65)
        let x = min(max(normalizedRect.x, 0.01), max(0.01, 0.99 - w))
        let y = min(max(normalizedRect.y, 0.01), max(0.01, 0.99 - h))
        pendingPDFStamps[idx].normalizedRect = CodableRect(x: x, y: y, width: w, height: h)
    }

    public func removePendingStamp(id: String) {
        pendingPDFStamps.removeAll { $0.id == id }
        if selectedStampId == id { selectedStampId = nil }
    }

    public func clearPendingStamps() {
        pendingPDFStamps = []
        selectedStampId = nil
        stampDragOriginRect = nil
        stampResizeOriginRect = nil
    }

    public static func suggestedSignedFilename(for book: BookItem?, url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let raw = (book?.title.isEmpty == false) ? book!.title : base
        let cleaned = raw
            .replacingOccurrences(of: #"[^A-Za-z0-9._ -]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "document" : String(cleaned.prefix(64))
        return stem.hasSuffix("-signed") ? "\(stem).pdf" : "\(stem)-signed.pdf"
    }

    public func prepareSignedPDFExport() async -> Data? {
        guard let sourceURL = activePDFURL, !pendingPDFStamps.isEmpty else { return nil }
        let stamps = pendingPDFStamps
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let raw = try Data(contentsOf: sourceURL)
                return try PDFSigner.flattenStamps(stamps, onto: raw)
            }.value
            exportedSignedPDFData = data
            exportedSignedFilename = Self.suggestedSignedFilename(for: activeBook, url: sourceURL)
            return data
        } catch {
            bannerError = "Could not sign PDF: \(error.localizedDescription)"
            return nil
        }
    }

    #if os(macOS)
    public func saveSignedPDFWithPanel() async {
        guard let data = await prepareSignedPDFExport(),
              let sourceURL = activePDFURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = exportedSignedFilename
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                try data.write(to: dest, options: .atomic)
                lastSignedSavePath = dest.path
                lastHandoffMessage = "Saved signed PDF: \(dest.lastPathComponent)"
                clearPendingStamps()
            } catch {
                bannerError = "Failed to save signed PDF: \(error.localizedDescription)"
            }
        }
    }
    #endif

    public func recordProgress(spine: Int, fraction: Double, wordOffset: Int?, pageIndex: Int?) async {
        guard var book = activeBook else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(readingStartAt)))
        readingStartAt = Date()
        let spineCount = activeEPUB?.spineHrefs.count ?? activePDFMetadata?.pageCount ?? book.locator?.spineCount
        let overall: Double? = {
            if let count = spineCount, count > 0 {
                return min(max((Double(spine) + fraction) / Double(count), 0), 1)
            }
            return fraction
        }()
        let next = ReadingLocator(
            spine: spine,
            fraction: fraction,
            wordOffset: wordOffset,
            pageIndex: pageIndex,
            spineCount: spineCount,
            overallProgress: overall,
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

    public func downloadForOffline(_ book: BookItem, forceImmediate: Bool = false) async {
        if !forceImmediate {
            guard isBusyBookId == nil else { return }
        }
        let prevBusy = isBusyBookId
        isBusyBookId = book.id
        defer {
            if isBusyBookId == book.id {
                isBusyBookId = (prevBusy == book.id) ? nil : prevBusy
            }
        }

        do {
            try Task.checkCancellation()
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

            try Task.checkCancellation()
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
                activeBook = books.first(where: { $0.id == book.id }) ?? updated
            }
        } catch is CancellationError {
            return
        } catch {
            bannerError = "Download failed: \(error.localizedDescription)"
        }
    }

    public func fetchOpenAccessBook(_ book: BookItem, from url: URL, generation: Int? = nil) async {
        var copy = book
        copy.epubURL = url.absoluteString
        await downloadForOffline(copy, forceImmediate: true)
        guard generation == nil || (generation == openBookGeneration && !Task.isCancelled) else { return }
        if let updated = books.first(where: { $0.id == book.id }),
           let path = updated.localFilePath,
           FileManager.default.fileExists(atPath: path) {
            await loadLocalDocument(url: URL(fileURLWithPath: path), book: updated, generation: generation)
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

    public func clearOfflineCache() async {
        autoDownloadTask?.cancel()
        autoDownloadActiveTitle = nil
        do {
            try await store.evictAllCachedRemoteBooks()
            books = visibleLibraryBooks(from: try await store.listBooks())
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            if activeBook?.source != .localImport {
                activeBook?.isOfflineCached = false
                activeBook?.localFilePath = nil
            }
        } catch {
            bannerError = error.localizedDescription
        }
    }

    public func triggerManualPrefetch() {
        autoDownloadTask?.cancel()
        autoDownloadTask = Task { await self.prefetchLikelyReads() }
    }

    // MARK: - Highlight -> Cohort Handoff

    public func prepareCohortDraft(quote: String) {
        guard let book = activeBook else { return }
        cohortDraftNote = ""
        let draft = CohortCardDraft(
            sourceBookId: book.id,
            canonicalId: book.canonicalId,
            sourceTitle: book.title,
            quote: quote,
            promptHint: "Key concept from \(book.title)",
            tags: ["reader", book.genre.lowercased().replacingOccurrences(of: " ", with: "-")]
        )
        transitionSheet(to: .cohortDraft(draft))
    }

    public func sendDraftToCohort(_ draft: CohortCardDraft, note: String) async -> URL? {
        guard let book = activeBook else { return nil }
        let highlight = ReadingHighlight(
            bookId: book.id,
            canonicalId: book.canonicalId,
            bookTitle: book.title,
            spine: activePDFURL != nil ? activePDFPageIndex : activeEPUBSpineIndex,
            quote: draft.quote,
            note: note,
            sentToCohort: true
        )
        try? await store.saveHighlight(highlight)
        activeHighlights = (try? await store.listHighlights(bookId: book.id)) ?? activeHighlights
        activeSheet = nil

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
            if isServerConnected {
                await syncManifoldOwnershipWithServer()
            }
        } catch {
            if !silent {
                bannerError = "Manifold sync failed: \(error.localizedDescription)"
            }
        }
    }

    public func syncManifoldOwnershipWithServer() async {
        guard isServerConnected, !serverURL.isEmpty, !manifoldWorks.isEmpty else { return }
        do {
            let queries = manifoldWorks.map { (workId: $0.workId, title: $0.title, creator: $0.creator) }
            let matched = try await HomeLibraryClient.matchWorks(baseURL: serverURL, works: queries)
            guard !matched.isEmpty else { return }
            var newMap = serverOwnedWorkIds
            var toUpsert: [BookItem] = []
            for (workId, book) in matched {
                newMap[workId] = book.id
                var enriched = book
                if enriched.canonicalId == nil {
                    enriched.canonicalId = workId
                }
                toUpsert.append(enriched)
            }
            serverOwnedWorkIds = newMap
            try await store.upsertBooks(toUpsert)
            for item in toUpsert {
                if let loc = item.locator {
                    _ = try? await store.saveLocator(bookId: item.id, locator: loc, enqueueSync: false)
                }
            }
            books = visibleLibraryBooks(from: try await store.listBooks())
            rebuildShelves()
        } catch {
            // Retain existing client-side title matching if server lacks /api/match
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
            let prevActiveLoc = activeBook?.locator
            books = visibleLibraryBooks(from: try await store.listBooks())
            if let activeId = activeBook?.id, let refreshed = books.first(where: { $0.id == activeId }) {
                activeBook = refreshed
                if let newLoc = refreshed.locator,
                   prevActiveLoc == nil || newLoc.updatedAt > prevActiveLoc!.updatedAt {
                    if let doc = activeEPUB {
                        activeEPUBSpineIndex = min(max(newLoc.spine, 0), max(0, doc.spineHrefs.count - 1))
                    } else if let meta = activePDFMetadata, meta.pageCount > 0 {
                        activePDFPageIndex = newLoc.pageIndex ?? PDFInspector.pageIndex(forFraction: newLoc.effectiveProgress, pageCount: meta.pageCount)
                    }
                }
            }
            shelves = catalog.shelves.isEmpty ? shelves : catalog.shelves
            if catalog.shelves.isEmpty { rebuildShelves() }
            isServerConnected = true
            AssetImageCache.shared.resetFailures()
            serverName = name
            serverStatusMessage = "\(name) · \(catalog.items.count) works"
            await flushProgressOutbox()
            await syncManifoldOwnershipWithServer()
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
