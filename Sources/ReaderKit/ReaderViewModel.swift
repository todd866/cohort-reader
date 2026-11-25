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

public struct FootnotePreview: Identifiable, Sendable, Hashable {
    public var id: String { "\(archivePath)#\(fragment)" }
    public var title: String
    public var body: String
    public var archivePath: String
    public var fragment: String

    public init(title: String, body: String, archivePath: String, fragment: String) {
        self.title = title
        self.body = body
        self.archivePath = archivePath
        self.fragment = fragment
    }
}

public enum CommandPaletteItemKind: Sendable, Hashable {
    case book(BookItem)
    case action(String)
}

public struct CommandPaletteItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var shortcut: String?
    public var kind: CommandPaletteItemKind

    public init(
        id: String,
        title: String,
        subtitle: String,
        symbol: String,
        shortcut: String? = nil,
        kind: CommandPaletteItemKind
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.shortcut = shortcut
        self.kind = kind
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
    case footnote(FootnotePreview)

    public var id: String {
        switch self {
        case .settings: return "settings"
        case .marginNote(let note): return "note:\(note.id)"
        case .discovery(let work): return "discovery:\(work.workId)"
        case .cohortDraft(let draft): return "cohort:\(draft.sourceBookId):\(draft.quote.prefix(24))"
        case .toc: return "toc"
        case .typography: return "typography"
        case .pdfSign: return "pdf-sign"
        case .footnote(let f): return "footnote:\(f.id)"
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
    public var autoDownloadBudgetMB: Int = 2048
    public var autoDownloadActiveTitle: String?
    public var autoDownloadedCount: Int = 0

    public var hasRealLibrary: Bool {
        books.contains { $0.source == .homeServer || $0.source == .localImport }
    }

    // Active Reader Session & Multi-Document Tabs
    public var openTabs: [OpenReaderTab] = []
    public var activeBook: BookItem?
    public var activeEPUB: EPUBDocument?
    public var activeEPUBSpineIndex: Int = 0
    public var epubCurrentPage: Int = 1
    public var epubCurrentPageEnd: Int = 1
    public var epubTotalPages: Int = 1
    public var epubCurrentSpread: Int = 1
    public var epubTotalSpreads: Int = 1
    public var epubColumnsPerSpread: Int = 1
    public var scrubEPUBSpreadTarget: Int?
    public var epubGoToSpreadTarget: Int = 1
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
    public var isSendingCohortDraft: Bool = false
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
    public var pdfTwoUpMode: Bool = false
    public var pdfDisplayLayout: PDFDisplayLayout = .scroll
    public var pdfJumpToken: Int = 0
    public var pdfJumpTargetPage: Int = 0
    public var deletedSignatureIds: Set<String> = []
    public var lastSyncAt: Date?
    public var isSendingToInbox: Bool = false
    public var toastMessage: String?
    public var pdfThumbnailPageInput: String = ""
    public var tocShowsPDFThumbnails: Bool = false

    // Keyboard-First Chrome, Command Palette, & Inline Find
    public var isSidebarCollapsed: Bool = false
    public var isCommandPalettePresented: Bool = false
    public var commandPaletteQuery: String = ""
    public var commandPaletteSelectionIndex: Int = 0
    public var isShortcutsHUDPresented: Bool = false
    public var isInlineFindPresented: Bool = false
    public var inlineFindQuery: String = ""
    public var inlineFindActiveIndex: Int = 0
    public var inlineFindTotalCount: Int = 0
    public var inlineFindActionToken: Int = 0
    public var inlineFindDirection: Int = 1
    public var isGoToPagePresented: Bool = false
    public var goToPageQuery: String = ""
    public var commandPaletteFocusToken: Int = 0
    public var inlineFindFocusToken: Int = 0
    public var goToPageFocusToken: Int = 0
    public var epubCommandToken: Int = 0
    public var epubPendingCommand: String?
    public var pdfCommandToken: Int = 0
    public var pdfPendingCommand: String?
    public var focusedShelfBookId: String?
    public var selectedSearchIndex: Int?
    public var searchFocusToken: Int = 0

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
    private var prefetchScheduleTask: Task<Void, Never>?
    private var openBookTask: Task<Void, Never>?
    private var pdfSearchTask: Task<Void, Never>?
    private var pdfScrollProgressTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?
    private var openBookGeneration: Int = 0
    private var manifoldSyncedOnce: Bool = false
    private var allowBackgroundSync: Bool = true
    private var didOpenExternalFileAtLaunch: Bool = false
    private var quickOpenScopedURLs: [String: URL] = [:]
    private var localMirrorScopedURL: URL?
    private var cachedChapterKey: String = ""
    private var cachedChapterValue: EPUBChapter?
    private var cachedChapterHTMLKey: String = ""
    private var cachedChapterHTMLValue: String = ""

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
        if defaults.object(forKey: "cohortReader.autoDownloadBudgetMB") != nil {
            let savedBudget = defaults.integer(forKey: "cohortReader.autoDownloadBudgetMB")
            if !defaults.bool(forKey: "cohortReader.budgetMigratedV2") {
                defaults.set(true, forKey: "cohortReader.budgetMigratedV2")
                if savedBudget == 350 {
                    self.autoDownloadBudgetMB = 2048
                    defaults.set(2048, forKey: "cohortReader.autoDownloadBudgetMB")
                } else if savedBudget >= 0 {
                    self.autoDownloadBudgetMB = savedBudget
                }
            } else if savedBudget >= 0 {
                self.autoDownloadBudgetMB = savedBudget
            }
        } else {
            defaults.set(true, forKey: "cohortReader.budgetMigratedV2")
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
        let savedTwoUp = defaults.bool(forKey: "cohortReader.pdfTwoUpMode")
        self.pdfTwoUpMode = savedTwoUp
        if let rawLayout = defaults.string(forKey: "cohortReader.pdfDisplayLayout"),
           let parsedLayout = PDFDisplayLayout(rawValue: rawLayout) {
            self.pdfDisplayLayout = parsedLayout
            self.pdfTwoUpMode = (parsedLayout == .spread)
        } else if savedTwoUp {
            self.pdfDisplayLayout = .spread
        }
        self.isSidebarCollapsed = defaults.bool(forKey: "cohortReader.sidebarCollapsed")
        if let savedDeletedSigs = defaults.stringArray(forKey: "cohortReader.deletedSignatureIds") {
            self.deletedSignatureIds = Set(savedDeletedSigs)
        }
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
        defaults.set(pdfTwoUpMode, forKey: "cohortReader.pdfTwoUpMode")
        defaults.set(pdfDisplayLayout.rawValue, forKey: "cohortReader.pdfDisplayLayout")
        defaults.set(isSidebarCollapsed, forKey: "cohortReader.sidebarCollapsed")
        defaults.set(Array(deletedSignatureIds), forKey: "cohortReader.deletedSignatureIds")
    }

    public func bootstrap(loadSampleBook: Bool = true, runNetworkSync: Bool = true) async {
        self.allowBackgroundSync = runNetworkSync
        do {
            wishlistIds = (try? await store.listWishlistIds()) ?? []
            _ = try? await store.reconcileOfflineCache()
            var current = try await store.listBooks()
            if current.contains(where: { $0.source == .homeServer || $0.source == .localImport }),
               current.contains(where: { $0.source == .showcase }) {
                try? await store.pruneShowcaseBooks()
                current = try await store.listBooks()
            }
            if current.isEmpty {
                let openSeedItems = ShowcaseCatalog.works
                    .filter(\.isDirectlyDownloadable)
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

            books = Self.visibleLibraryBooks(from: current)
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            pendingOutboxCount = (try? await store.pendingSyncEvents().count) ?? 0

            if !didOpenExternalFileAtLaunch && activeBook == nil && openTabs.isEmpty {
                let lastId = defaults.string(forKey: "cohortReader.lastBookId")
                let initial = (lastId.flatMap { id in books.first(where: { $0.id == id && ($0.isOfflineCached || $0.canonicalId == "gutenberg:84") }) })
                    ?? books.first(where: { $0.isOfflineCached })
                if let initial {
                    await openBook(initial, switchTab: false)
                }
            }

            if runNetworkSync && !serverURL.isEmpty && !isServerConnected {
                await syncServerCatalog(silent: true)
            } else if runNetworkSync {
                Task { await self.ensureLocalCoversForCachedBooks() }
            }
        } catch {
            bannerError = error.localizedDescription
        }
    }

    public static func visibleLibraryBooks(from raw: [BookItem]) -> [BookItem] {
        let hasReal = raw.contains { $0.source == .homeServer || $0.source == .localImport }
        if hasReal {
            return raw.filter { $0.source != .showcase }
        }
        return raw.filter { book in
            if book.source == .showcase && !book.isOfflineCached && book.epubURL == nil && !(book.canonicalId?.hasPrefix("arxiv:") ?? false) {
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
        guard let dlURL = work.directDownloadURL else {
            bannerError = "This title has no direct offline download — open the web edition or import your own copy."
            return
        }
        var book = work.toBookItem()
        if book.format == .epub {
            book.epubURL = dlURL.absoluteString
        } else {
            book.openAccessURL = dlURL.absoluteString
        }
        try? await store.upsertBooks([book])
        books = Self.visibleLibraryBooks(from: (try? await store.listBooks()) ?? books)
        await downloadForOffline(book, forceImmediate: true)
        if let updated = books.first(where: { $0.id == book.id }), updated.isOfflineCached {
            activeSheet = nil
            await openBook(updated, switchTab: true)
        }
    }

    public nonisolated static func isValidPayload(_ data: Data, format: BookFormat) -> Bool {
        guard !data.isEmpty else { return false }
        if format == .epub {
            return data.starts(with: [0x50, 0x4B])
        } else {
            return data.starts(with: [0x25, 0x50, 0x44, 0x46])
        }
    }

    public static func prioritizedAutoDownloadCandidates(
        from items: [BookItem],
        maxSingleBytes: Int64 = 60 * 1024 * 1024
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
            if book.shelfNames.contains(where: { $0.caseInsensitiveCompare("Reading Now") == .orderedSame }) { pts += 300 }
            pts += (book.format == .epub ? 150 : 60)
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

    public func scheduleBackgroundPrefetch(delaySeconds: Double = 1.5) {
        guard allowBackgroundSync, autoDownloadEnabled, isServerConnected, !serverURL.isEmpty else { return }
        prefetchScheduleTask?.cancel()
        prefetchScheduleTask = Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            guard !Task.isCancelled, let self, self.autoDownloadEnabled, self.isServerConnected else { return }
            self.autoDownloadTask?.cancel()
            self.autoDownloadTask = Task { await self.prefetchLikelyReads() }
        }
    }

    public func ensureLocalCoversForCachedBooks() async {
        let cached = books.filter { $0.isOfflineCached }
        for book in cached {
            if Task.isCancelled { break }
            guard !AssetImageCache.shared.hasDiskCover(forBookId: book.id),
                  let path = book.localFilePath,
                  FileManager.default.isReadableFile(atPath: path) else { continue }
            await AssetImageCache.shared.extractLocalCoverIfMissing(
                bookId: book.id,
                fileURL: URL(fileURLWithPath: path),
                format: book.format
            )
        }
    }

    private func cacheMarginNotesAndAssets(for book: BookItem) async {
        guard isServerConnected, !serverURL.isEmpty, book.source == .homeServer, book.notesVersion != nil else { return }
        var notes = (try? await store.loadMarginNotes(bookId: book.id)) ?? []
        if notes.isEmpty {
            notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: serverURL, bookId: book.id)) ?? []
            if !notes.isEmpty {
                try? await store.saveMarginNotes(bookId: book.id, notes: notes)
                if activeBook?.id == book.id {
                    activeNotes = notes
                }
            }
        }
        for note in notes {
            guard let asset = note.image, !asset.isEmpty,
                  let assetURL = HomeLibraryClient.noteAssetURL(baseURL: serverURL, bookId: book.id, asset: asset) else { continue }
            await AssetImageCache.shared.prefetchNoteAsset(url: assetURL, bookId: book.id, asset: asset)
        }
    }

    public func prefetchLikelyReads() async {
        guard allowBackgroundSync, isServerConnected, !serverURL.isEmpty else { return }
        let baseURL = serverURL

        // Phase A: Ensure every catalog cover is persistently cached on disk (max 4 concurrent).
        let coverJobs: [(book: BookItem, url: URL)] = books.compactMap { book in
            guard book.hasServerCover,
                  !AssetImageCache.shared.hasDiskCover(forBookId: book.id),
                  let url = HomeLibraryClient.coverURL(baseURL: baseURL, bookId: book.id) else {
                return nil
            }
            return (book, url)
        }
        if !coverJobs.isEmpty {
            var idx = 0
            await withTaskGroup(of: Void.self) { group in
                let width = min(4, coverJobs.count)
                for _ in 0..<width {
                    if idx < coverJobs.count {
                        let job = coverJobs[idx]
                        idx += 1
                        group.addTask {
                            _ = await AssetImageCache.shared.prefetchCover(url: job.url, bookId: job.book.id)
                        }
                    }
                }
                while await group.next() != nil {
                    if Task.isCancelled || !isServerConnected { break }
                    if idx < coverJobs.count {
                        let job = coverJobs[idx]
                        idx += 1
                        group.addTask {
                            _ = await AssetImageCache.shared.prefetchCover(url: job.url, bookId: job.book.id)
                        }
                    }
                }
            }
        }
        await ensureLocalCoversForCachedBooks()

        // Phase B: Ensure margin notes + note images are cached for already-offline books.
        for book in books where book.isOfflineCached && book.notesVersion != nil {
            if Task.isCancelled || !isServerConnected { break }
            await cacheMarginNotesAndAssets(for: book)
        }

        // Phase C: Download all eligible books/papers within budget (0 == Unlimited).
        guard autoDownloadEnabled else { return }
        let budgetBytes: Int64 = (autoDownloadBudgetMB <= 0)
            ? Int64.max
            : Int64(max(50, autoDownloadBudgetMB)) * 1024 * 1024
        var currentBytes = await store.cachedBookBytes()
        guard currentBytes < budgetBytes else { return }

        let allCandidates = Self.prioritizedAutoDownloadCandidates(from: books)
        var queue: [BookItem] = []
        var projectedBytes = currentBytes
        for book in allCandidates {
            if budgetBytes != Int64.max && projectedBytes + book.bytes > budgetBytes {
                if autoDownloadedCount >= 3 || !queue.isEmpty { continue }
            }
            queue.append(book)
            if budgetBytes != Int64.max {
                projectedBytes += book.bytes
            }
        }
        guard !queue.isEmpty else { return }

        var nextIdx = 0
        var dirtySinceRefresh = 0
        await withTaskGroup(of: (BookItem, Data, [MarginNote])?.self) { group in
            let maxConcurrent = 2
            autoDownloadActiveTitle = queue.first?.title
            for _ in 0..<min(maxConcurrent, queue.count) {
                guard nextIdx < queue.count, !Task.isCancelled, autoDownloadEnabled, isServerConnected else { break }
                let book = queue[nextIdx]
                nextIdx += 1
                group.addTask {
                    do {
                        let data = try await HomeLibraryClient.downloadBook(baseURL: baseURL, bookId: book.id)
                        guard Self.isValidPayload(data, format: book.format == .article ? .pdf : book.format) else {
                            return nil
                        }
                        let notes: [MarginNote]
                        if book.notesVersion != nil {
                            notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: baseURL, bookId: book.id)) ?? []
                        } else {
                            notes = []
                        }
                        return (book, data, notes)
                    } catch {
                        return nil
                    }
                }
            }

            while let result = await group.next() {
                if Task.isCancelled || !autoDownloadEnabled || !isServerConnected { break }
                if let (book, data, notes) = result {
                    autoDownloadActiveTitle = book.title
                    let storeFormat: BookFormat = (book.format == .article) ? .pdf : book.format
                    if let url = try? await store.storeOfflineBookData(data, bookId: book.id, format: storeFormat) {
                        var updated = book
                        updated.isOfflineCached = true
                        updated.localFilePath = url.path
                        updated.bytes = Int64(data.count)
                        try? await store.upsertBooks([updated])
                        if !notes.isEmpty {
                            try? await store.saveMarginNotes(bookId: book.id, notes: notes)
                            for note in notes {
                                if let asset = note.image, !asset.isEmpty,
                                   let assetURL = HomeLibraryClient.noteAssetURL(baseURL: baseURL, bookId: book.id, asset: asset) {
                                    await AssetImageCache.shared.prefetchNoteAsset(url: assetURL, bookId: book.id, asset: asset)
                                }
                            }
                        }
                        if !AssetImageCache.shared.hasDiskCover(forBookId: book.id) {
                            await AssetImageCache.shared.extractLocalCoverIfMissing(bookId: book.id, fileURL: url, format: storeFormat)
                        }
                        autoDownloadedCount += 1
                        dirtySinceRefresh += 1
                    }
                }
                if dirtySinceRefresh >= 3 {
                    dirtySinceRefresh = 0
                    books = Self.visibleLibraryBooks(from: (try? await store.listBooks()) ?? books)
                    rebuildShelves()
                    currentBytes = await store.cachedBookBytes()
                    offlineBytes = currentBytes
                }
                if nextIdx < queue.count && !Task.isCancelled && autoDownloadEnabled && isServerConnected {
                    let book = queue[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        do {
                            let data = try await HomeLibraryClient.downloadBook(baseURL: baseURL, bookId: book.id)
                            guard Self.isValidPayload(data, format: book.format == .article ? .pdf : book.format) else {
                                return nil
                            }
                            let notes: [MarginNote]
                            if book.notesVersion != nil {
                                notes = (try? await HomeLibraryClient.fetchMarginNotes(baseURL: baseURL, bookId: book.id)) ?? []
                            } else {
                                notes = []
                            }
                            return (book, data, notes)
                        } catch {
                            return nil
                        }
                    }
                }
            }
        }
        autoDownloadActiveTitle = nil
        if dirtySinceRefresh > 0 {
            books = Self.visibleLibraryBooks(from: (try? await store.listBooks()) ?? books)
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
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

    public func noteExternalFileLaunch() {
        didOpenExternalFileAtLaunch = true
    }

    public func quickOpenExternalFile(from url: URL) async {
        didOpenExternalFileAtLaunch = true
        if activeBook?.localFilePath == url.path && selectedTab == .read {
            return
        }
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

    public func selectAdjacentTab(delta: Int) async {
        guard openTabs.count > 1,
              let activeId = activeBook?.id,
              let idx = openTabs.firstIndex(where: { $0.id == activeId }) else { return }
        let count = openTabs.count
        let nextIdx = ((idx + delta) % count + count) % count
        await openBook(openTabs[nextIdx].book, switchTab: true)
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
        cachedChapterKey = ""
        cachedChapterValue = nil
        cachedChapterHTMLKey = ""
        cachedChapterHTMLValue = ""
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
        prefetchScheduleTask?.cancel()
        autoDownloadTask?.cancel()
        autoDownloadActiveTitle = nil
        openBookTask?.cancel()
        pdfSearchTask?.cancel()
        pdfScrollProgressTask?.cancel()
        openBookGeneration += 1
        let generation = openBookGeneration

        bannerError = nil
        readingStartAt = Date()
        isReaderChromeHidden = false
        activeSelectionText = ""
        activeBook = book
        cachedChapterKey = ""
        cachedChapterValue = nil
        cachedChapterHTMLKey = ""
        cachedChapterHTMLValue = ""
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
        pdfJumpTargetPage = 0
        pdfJumpToken += 1
        epubCurrentPage = 1
        epubCurrentPageEnd = 1
        epubTotalPages = 1
        epubCurrentSpread = 1
        epubTotalSpreads = 1
        scrubEPUBSpreadTarget = nil
        tocShowsPDFThumbnails = false
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
                    if self.autoDownloadEnabled && self.isServerConnected && !Task.isCancelled {
                        self.scheduleBackgroundPrefetch(delaySeconds: 1.5)
                    }
                }
            }
            guard !Task.isCancelled, self.openBookGeneration == generation else { return }

            let resolvedOffline = self.store.resolveOfflineFileURL(bookId: book.id, format: book.format, storedPath: book.localFilePath)
            if let url = resolvedOffline {
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
                await self.cacheMarginNotesAndAssets(for: book)
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
        showToast("Highlighted in \(book.title)")
        if isServerConnected {
            Task { await self.syncHighlightsWithServer() }
        }
    }

    public func deleteHighlight(_ highlight: ReadingHighlight) async {
        try? await store.deleteHighlight(id: highlight.id)
        activeHighlights.removeAll { $0.id == highlight.id }
        if isServerConnected {
            Task { await self.syncHighlightsWithServer() }
        }
    }

    public func previewEPUBFootnote(archivePath: String, fragment: String) {
        let cleanFrag = fragment.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !cleanFrag.isEmpty, let doc = activeEPUB else { return }
        if let text = doc.extractFootnotePreview(archivePath: archivePath, fragmentId: cleanFrag) {
            let label = cleanFrag
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            transitionSheet(to: .footnote(FootnotePreview(
                title: "Note (\(label))",
                body: text,
                archivePath: archivePath,
                fragment: cleanFrag
            )))
            return
        }
        let baseHref = archivePath.components(separatedBy: "#").first ?? archivePath
        let baseName = (baseHref as NSString).lastPathComponent
        if let idx = doc.spineHrefs.firstIndex(where: { $0 == baseHref || ($0 as NSString).lastPathComponent == baseName }),
           idx != activeEPUBSpineIndex {
            Task { await self.selectEPUBSpine(idx) }
        }
    }

    public func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        lastHandoffMessage = message
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5.0))
            guard !Task.isCancelled, self?.toastMessage == message else { return }
            self?.toastMessage = nil
        }
    }

    public func dismissToast() {
        toastDismissTask?.cancel()
        toastMessage = nil
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
            pdfJumpTargetPage = activePDFPageIndex
            pdfJumpToken += 1
            tocShowsPDFThumbnails = meta?.outline.isEmpty ?? false
            pdfThumbnailPageInput = "\(activePDFPageIndex + 1)"
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
        guard let epub = activeEPUB else {
            cachedChapterKey = ""
            cachedChapterValue = nil
            return nil
        }
        let key = "\(activeBook?.id ?? ""):\(activeEPUBSpineIndex):\(epub.spineHrefs.count)"
        if cachedChapterKey == key, let cached = cachedChapterValue {
            return cached
        }
        let ch = epub.chapter(at: activeEPUBSpineIndex)
        cachedChapterKey = key
        cachedChapterValue = ch
        return ch
    }

    public func currentChapterHTML(resolvedTheme: ReaderTheme? = nil) -> String {
        guard let chapter = currentChapter() else { return "" }
        let themeKey = resolvedTheme?.rawValue ?? typography.theme.rawValue
        let key = "\(activeBook?.id ?? ""):\(chapter.index):\(themeKey):\(typography.readingFlow.rawValue):\(typography.fontFamily.rawValue):\(Int(typography.fontSize)):\(String(format: "%.2f", typography.lineHeight)):\(typography.marginWidth.rawValue):\(typography.textAlignment.rawValue):\(activeNotes.count):\(activeHighlights.count)"
        if cachedChapterHTMLKey == key, !cachedChapterHTMLValue.isEmpty {
            return cachedChapterHTMLValue
        }
        guard let raw = String(data: chapter.xhtmlData, encoding: .utf8) ?? String(data: chapter.xhtmlData, encoding: .isoLatin1) else {
            return ""
        }
        let chapterNotes = activeNotes.filter { $0.spine == chapter.index }
        let chapterHighlights = activeHighlights.filter { $0.spine == chapter.index }
        let loc = activeBook?.locator
        let frac = (loc?.spine == chapter.index) ? (loc?.fraction ?? 0) : 0
        let word = (loc?.spine == chapter.index) ? loc?.wordOffset : nil
        let html = EPUBHTMLComposer.composeChapterHTML(
            rawXHTML: raw,
            typography: typography,
            notes: chapterNotes,
            initialFraction: frac,
            initialWordOffset: word,
            resolvedTheme: resolvedTheme,
            highlights: chapterHighlights
        )
        cachedChapterHTMLKey = key
        cachedChapterHTMLValue = html
        return html
    }

    public func selectEPUBSpine(_ index: Int, startAtEnd: Bool = false) async {
        guard let doc = activeEPUB, index >= 0, index < doc.spineHrefs.count else { return }
        let targetFrac = startAtEnd ? 1.0 : 0.0
        let targetWordOffset: Int? = startAtEnd ? nil : 0
        if var curBook = activeBook {
            let count = doc.spineHrefs.count
            curBook.locator = ReadingLocator(
                spine: index,
                fraction: targetFrac,
                wordOffset: targetWordOffset,
                pageIndex: nil,
                spineCount: count,
                overallProgress: count > 0 ? min(max((Double(index) + targetFrac) / Double(count), 0), 1) : targetFrac,
                updatedAt: Date()
            )
            activeBook = curBook
        }
        epubCurrentPage = 1
        epubCurrentPageEnd = 1
        epubTotalPages = 1
        epubCurrentSpread = 1
        epubTotalSpreads = 1
        scrubEPUBSpreadTarget = nil
        activeEPUBSpineIndex = index
        await recordProgress(spine: index, fraction: targetFrac, wordOffset: targetWordOffset, pageIndex: nil)
    }

    public func selectPDFPage(_ pageIndex: Int, recordJump: Bool = false) async {
        guard let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        pdfScrollProgressTask?.cancel()
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
        pdfJumpTargetPage = clamped
        pdfJumpToken += 1
        pdfTwoColumnStep = 0
        let frac = PDFInspector.fraction(forPage: clamped, pageCount: meta.pageCount)
        await recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
    }

    public func notePDFPageScrolled(_ pageIndex: Int) {
        guard let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        let clamped = min(max(pageIndex, 0), meta.pageCount - 1)
        activePDFPageIndex = clamped
        pdfTwoColumnStep = 0
        pdfScrollProgressTask?.cancel()
        pdfScrollProgressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled,
                  let self,
                  let currentMeta = self.activePDFMetadata,
                  currentMeta.pageCount > 0 else { return }
            let frac = PDFInspector.fraction(forPage: clamped, pageCount: currentMeta.pageCount)
            await self.recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
        }
    }

    public func jumpBackInPDF() async {
        guard let prev = pdfJumpBackStack.popLast(),
              let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        pdfScrollProgressTask?.cancel()
        pdfJumpForwardStack.append(activePDFPageIndex)
        let clamped = min(max(prev, 0), meta.pageCount - 1)
        activePDFPageIndex = clamped
        pdfJumpTargetPage = clamped
        pdfJumpToken += 1
        pdfTwoColumnStep = 0
        let frac = PDFInspector.fraction(forPage: clamped, pageCount: meta.pageCount)
        await recordProgress(spine: clamped, fraction: frac, wordOffset: nil, pageIndex: clamped)
    }

    public func jumpForwardInPDF() async {
        guard let next = pdfJumpForwardStack.popLast(),
              let meta = activePDFMetadata, meta.pageCount > 0 else { return }
        pdfScrollProgressTask?.cancel()
        pdfJumpBackStack.append(activePDFPageIndex)
        let clamped = min(max(next, 0), meta.pageCount - 1)
        activePDFPageIndex = clamped
        pdfJumpTargetPage = clamped
        pdfJumpToken += 1
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

    public func setPDFDisplayLayout(_ layout: PDFDisplayLayout) {
        pdfDisplayLayout = layout
        pdfTwoUpMode = (layout == .spread)
        pdfZoomScale = 1.0
        savePreferences()
        showToast("PDF: \(layout.rawValue)")
    }

    public func togglePDFTwoUpMode() {
        let next: PDFDisplayLayout = (pdfDisplayLayout == .spread) ? .scroll : .spread
        setPDFDisplayLayout(next)
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
        if isServerConnected {
            Task { await self.syncSignaturesWithServer() }
        }
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
        deletedSignatureIds.insert(id)
        savePreferences()
        try? SignatureStore.save(savedSignatures, to: signatureStoreURL)
        if isServerConnected {
            Task { await self.syncSignaturesWithServer() }
        }
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
                showToast("Saved signed PDF: \(dest.lastPathComponent)")
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
        if let prev = book.locator,
           prev.spine == spine,
           prev.pageIndex == pageIndex,
           prev.wordOffset == wordOffset,
           abs(prev.fraction - fraction) < 0.004,
           elapsed < 5 {
            return
        }
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
            books = Self.visibleLibraryBooks(from: try await store.listBooks())
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
            let storeFormat: BookFormat = (book.format == .article) ? .pdf : book.format
            if book.source == .homeServer && !serverURL.isEmpty {
                data = try await HomeLibraryClient.downloadBook(baseURL: serverURL, bookId: book.id)
                guard Self.isValidPayload(data, format: storeFormat) else {
                    throw HomeLibraryError.emptyPayload
                }
                if book.notesVersion != nil {
                    await cacheMarginNotesAndAssets(for: book)
                }
            } else if let cid = book.canonicalId,
                      let dlURL = URL(string: book.epubURL ?? "") ?? URL(string: book.openAccessURL ?? "") ?? OpenAccessResolver.directDownloadURL(for: cid) {
                let (oaData, _) = try await URLSession.shared.data(from: dlURL)
                guard Self.isValidPayload(oaData, format: storeFormat) else {
                    throw HomeLibraryError.emptyPayload
                }
                data = oaData
            } else if book.canonicalId == "gutenberg:84" {
                data = try SampleShowcaseEPUB.buildFrankensteinSampleData()
            } else {
                throw HomeLibraryError.emptyPayload
            }

            try Task.checkCancellation()
            let url = try await store.storeOfflineBookData(data, bookId: book.id, format: storeFormat)
            var updated = book
            updated.isOfflineCached = true
            updated.localFilePath = url.path
            updated.bytes = Int64(data.count)
            try await store.upsertBooks([updated])
            books = Self.visibleLibraryBooks(from: try await store.listBooks())
            rebuildShelves()
            offlineBytes = await store.cachedBookBytes()
            if activeBook?.id == book.id {
                activeBook = books.first(where: { $0.id == book.id }) ?? updated
            }
            if !AssetImageCache.shared.hasDiskCover(forBookId: book.id) {
                await AssetImageCache.shared.extractLocalCoverIfMissing(bookId: book.id, fileURL: url, format: storeFormat)
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
            books = Self.visibleLibraryBooks(from: try await store.listBooks())
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
        prefetchScheduleTask?.cancel()
        autoDownloadTask?.cancel()
        autoDownloadActiveTitle = nil
        do {
            try await store.evictAllCachedRemoteBooks()
            books = Self.visibleLibraryBooks(from: try await store.listBooks())
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
        prefetchScheduleTask?.cancel()
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

    public func sendDraftToCohort(
        _ draft: CohortCardDraft,
        note: String,
        dropDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CohortReader/cohort-handoff", isDirectory: true),
        open: @MainActor (URL) async -> Bool
    ) async {
        guard let book = activeBook, book.id == draft.sourceBookId else { return }
        var seed = draft
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { seed.promptHint = note }
        var highlight = ReadingHighlight(
            bookId: book.id,
            canonicalId: book.canonicalId,
            bookTitle: book.title,
            spine: activePDFURL != nil ? activePDFPageIndex : activeEPUBSpineIndex,
            quote: draft.quote,
            note: note
        )
        do {
            try await store.saveHighlight(highlight)
            if let dropDirectory {
                _ = try? CohortHandoff.writeDropFile(for: seed, in: dropDirectory)
            }
            if let url = CohortHandoff.makeDraftURL(for: seed), await open(url) {
                highlight.sentToCohort = true
                try await store.saveHighlight(highlight)
                showToast("Opened draft in Cohort")
            } else {
                showToast("Highlight saved. Cohort could not open the draft.")
            }
            if activeBook?.id == book.id {
                activeHighlights = try await store.listHighlights(bookId: book.id)
            }
            if case .cohortDraft(let presented) = activeSheet, presented == draft {
                activeSheet = nil
            }
        } catch {
            bannerError = error.localizedDescription
        }
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
            books = Self.visibleLibraryBooks(from: try await store.listBooks())
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
            if !catalog.items.isEmpty {
                try? await store.pruneShowcaseBooks()
            }
            for item in catalog.items {
                if let loc = item.locator {
                    _ = try? await store.saveLocator(bookId: item.id, locator: loc, enqueueSync: false)
                }
            }
            let prevActiveLoc = activeBook?.locator
            books = Self.visibleLibraryBooks(from: try await store.listBooks())
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
            lastSyncAt = Date()
            await flushProgressOutbox()
            await syncHighlightsWithServer()
            await syncSignaturesWithServer()

            if let space = try? await HomeLibraryClient.fetchSpace(baseURL: clean, limit: 400),
               !space.works.isEmpty {
                manifoldWorks = space.works
                serverOwnedWorkIds = space.slugByWorkId
                if !space.lenses.isEmpty {
                    lenses = space.lenses
                    if !lenses.contains(where: { $0.id == selectedLensId }), let first = lenses.first {
                        selectedLensId = first.id
                    }
                }
                if let active = activeBook, let match = manifoldWork(for: active) {
                    selectedMapWorkId = match.workId
                } else if !manifoldWorks.contains(where: { $0.workId == selectedMapWorkId }),
                          let firstWork = manifoldWorks.first {
                    selectedMapWorkId = firstWork.workId
                }
                manifoldSyncedOnce = true
            } else {
                await syncManifoldOwnershipWithServer()
                if !manifoldSyncedOnce {
                    manifoldSyncedOnce = true
                    Task { await self.refreshManifold(silent: true) }
                }
            }

            prefetchScheduleTask?.cancel()
            autoDownloadTask?.cancel()
            autoDownloadTask = Task { await self.prefetchLikelyReads() }
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

    public func syncHighlightsWithServer() async {
        guard isServerConnected, !serverURL.isEmpty else { return }
        do {
            let allLocal = try await store.listAllHighlights()
            let deletedIds = try await store.listDeletedHighlightIds()
            let merged = try await HomeLibraryClient.syncHighlights(
                baseURL: serverURL,
                highlights: allLocal,
                deletedIds: deletedIds
            )
            try await store.mergeRemoteHighlights(merged.highlights, deletedIds: merged.deletedIds)
            if let activeId = activeBook?.id {
                activeHighlights = (try? await store.listHighlights(bookId: activeId)) ?? []
            }
        } catch {
            // Retain local SQLite highlights & deleted tombstones until reachable
        }
    }

    public func syncSignaturesWithServer() async {
        guard isServerConnected, !serverURL.isEmpty else { return }
        struct SigPayload: Codable {
            var signatures: [SavedSignature]
            var deletedIds: [String]
        }
        do {
            let reqData = try HomeLibraryClient.makeEncoder().encode(
                SigPayload(signatures: savedSignatures, deletedIds: Array(deletedSignatureIds))
            )
            let respData = try await HomeLibraryClient.syncSignaturesJSON(baseURL: serverURL, payload: reqData)
            let decoded = try HomeLibraryClient.makeDecoder().decode(SigPayload.self, from: respData)
            deletedSignatureIds.formUnion(decoded.deletedIds)
            savedSignatures = decoded.signatures
                .filter { !deletedSignatureIds.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
            savePreferences()
            try? SignatureStore.save(savedSignatures, to: signatureStoreURL)
        } catch {
            // Retain local signatures until reachable
        }
    }

    public func syncOnForegroundIfStale(minIntervalSeconds: TimeInterval = 15) async {
        guard allowBackgroundSync, !serverURL.isEmpty else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < minIntervalSeconds {
            await flushProgressOutbox()
            return
        }
        await syncServerCatalog(silent: true)
    }

    public func sendActiveDocumentToHomeInbox(overrideData: Data? = nil, overrideFilename: String? = nil) async {
        guard isServerConnected, !serverURL.isEmpty else {
            bannerError = "Connect to Home Library Server in Settings to send files between Mac and iPhone."
            return
        }
        let book = activeBook
        isSendingToInbox = true
        defer { isSendingToInbox = false }

        do {
            let payload: Data
            let filename: String
            let title: String

            if let overrideData {
                payload = overrideData
                filename = overrideFilename ?? Self.suggestedSignedFilename(
                    for: book,
                    url: activePDFURL ?? URL(fileURLWithPath: "document.pdf")
                )
                title = (book?.title.isEmpty == false)
                    ? "\(book!.title) (Signed)"
                    : (filename as NSString).deletingPathExtension
            } else if let sourceURL = activePDFURL ?? book?.localFilePath.map({ URL(fileURLWithPath: $0) }) {
                payload = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: sourceURL)
                }.value
                filename = sourceURL.lastPathComponent
                title = book?.title ?? sourceURL.deletingPathExtension().lastPathComponent
            } else {
                bannerError = "Open or download a local PDF or EPUB before sending to Home Inbox."
                return
            }

            guard payload.count <= 50 * 1024 * 1024 else {
                bannerError = "Document exceeds the 50 MB Home Inbox sync limit."
                return
            }

            let uploaded = try await HomeLibraryClient.uploadToInbox(
                baseURL: serverURL,
                data: payload,
                filename: filename,
                title: title,
                author: book?.author ?? "Cohort Reader",
                canonicalId: book?.canonicalId
            )
            if let localCopy = try? await store.storeOfflineBookData(payload, bookId: uploaded.id, format: uploaded.format) {
                var enriched = uploaded
                enriched.isOfflineCached = true
                enriched.localFilePath = localCopy.path
                enriched.bytes = Int64(payload.count)
                try? await store.upsertBooks([enriched])
            }
            await syncServerCatalog(silent: true)
            showToast("Sent '\(title)' to Home Inbox")
        } catch {
            bannerError = "Failed to send to Home Inbox: \(error.localizedDescription)"
        }
    }

    public func currentHandoffUserInfo() -> [String: Any]? {
        guard let book = activeBook else { return nil }
        var info: [String: Any] = [
            "bookId": book.id,
            "title": book.title,
            "author": book.author,
            "format": book.format.rawValue,
        ]
        if let cid = book.canonicalId, !cid.isEmpty {
            info["canonicalId"] = cid
        }
        if activePDFURL != nil {
            info["spine"] = activePDFPageIndex
            if let meta = activePDFMetadata, meta.pageCount > 0 {
                info["fraction"] = PDFInspector.fraction(forPage: activePDFPageIndex, pageCount: meta.pageCount)
            } else if let frac = book.locator?.fraction {
                info["fraction"] = frac
            }
        } else {
            info["spine"] = activeEPUBSpineIndex
            if let frac = book.locator?.fraction {
                info["fraction"] = frac
            }
        }
        return info
    }

    public func handleHandoffActivity(_ userInfo: [AnyHashable: Any]) async {
        let targetBookId = userInfo["bookId"] as? String
        let targetCanonicalId = userInfo["canonicalId"] as? String
        let targetTitle = userInfo["title"] as? String
        let targetSpine = userInfo["spine"] as? Int
        let targetFraction = userInfo["fraction"] as? Double

        func findBook() -> BookItem? {
            if let bid = targetBookId, let exact = books.first(where: { $0.id == bid }) {
                return exact
            }
            if let cid = targetCanonicalId, !cid.isEmpty,
               let match = books.first(where: { $0.canonicalId == cid }) {
                return match
            }
            if let title = targetTitle, !title.isEmpty {
                let key = Self.normalizedTitleKey(title)
                if !key.isEmpty, let match = books.first(where: { Self.normalizedTitleKey($0.title) == key }) {
                    return match
                }
            }
            return nil
        }

        var match = findBook()
        if match == nil, !serverURL.isEmpty {
            await syncServerCatalog(silent: true)
            match = findBook()
        }
        guard var target = match else {
            let label = targetTitle ?? targetBookId ?? "document"
            showToast("Could not find '\(label)' locally — use Send to Phone/Mac to share it.")
            return
        }
        if let targetSpine {
            let newLoc = ReadingLocator(
                spine: max(0, targetSpine),
                fraction: min(max(targetFraction ?? 0, 0), 1),
                wordOffset: nil,
                pageIndex: target.format == .pdf ? max(0, targetSpine) : nil,
                updatedAt: Date()
            )
            target.locator = newLoc
            _ = try? await store.saveLocator(bookId: target.id, locator: newLoc, enqueueSync: false)
        }
        await openBook(target, switchTab: true)
        showToast("Continued from Handoff: \(target.title)")
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

    // MARK: - Keyboard-First Navigation, Command Palette, Inline Find, & Unified Scale

    public func toggleSidebar() {
        isSidebarCollapsed.toggle()
        savePreferences()
    }

    public func openCommandPalette() {
        isShortcutsHUDPresented = false
        isGoToPagePresented = false
        commandPaletteQuery = ""
        commandPaletteSelectionIndex = 0
        isCommandPalettePresented = true
        commandPaletteFocusToken += 1
    }

    public func closeCommandPalette() {
        isCommandPalettePresented = false
        commandPaletteQuery = ""
        commandPaletteSelectionIndex = 0
    }

    public func toggleShortcutsHUD() {
        if isShortcutsHUDPresented {
            isShortcutsHUDPresented = false
        } else {
            isCommandPalettePresented = false
            isGoToPagePresented = false
            isShortcutsHUDPresented = true
        }
    }

    public func openInlineFind() {
        isCommandPalettePresented = false
        isShortcutsHUDPresented = false
        isGoToPagePresented = false
        guard selectedTab == .read, activeBook != nil else {
            selectedTab = .search
            searchFocusToken += 1
            return
        }
        isReaderChromeHidden = false
        isInlineFindPresented = true
        inlineFindFocusToken += 1
        let trimmed = inlineFindQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if activePDFURL != nil {
                activePDFSearchHighlight = trimmed
            }
            inlineFindDirection = 1
            inlineFindActionToken += 1
        }
    }

    public func closeInlineFind() {
        isInlineFindPresented = false
        inlineFindActiveIndex = 0
        inlineFindTotalCount = 0
        activePDFSearchHighlight = nil
        inlineFindActionToken += 1
    }

    public func updateInlineFindQuery(_ query: String) {
        inlineFindQuery = query
        inlineFindDirection = 1
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activePDFSearchHighlight = (activePDFURL != nil && !trimmed.isEmpty) ? trimmed : nil
        inlineFindActionToken += 1
    }

    public func stepInlineFind(delta: Int) {
        let trimmed = inlineFindQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !isInlineFindPresented {
            isInlineFindPresented = true
        }
        if activePDFURL != nil {
            activePDFSearchHighlight = trimmed
        }
        inlineFindDirection = delta < 0 ? -1 : 1
        inlineFindActionToken += 1
    }

    public func openGoToPage() {
        guard activeBook != nil else { return }
        isCommandPalettePresented = false
        isShortcutsHUDPresented = false
        isInlineFindPresented = false
        selectedTab = .read
        isReaderChromeHidden = false
        if activePDFURL != nil {
            goToPageQuery = "\(activePDFPageIndex + 1)"
        } else if activeEPUB != nil {
            goToPageQuery = "\(activeEPUBSpineIndex + 1)"
        } else {
            goToPageQuery = ""
        }
        isGoToPagePresented = true
        goToPageFocusToken += 1
    }

    public func closeGoToPage() {
        isGoToPagePresented = false
    }

    public func submitGoToPage() async {
        let raw = goToPageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isGoToPagePresented = false
        guard !raw.isEmpty else { return }
        if let meta = activePDFMetadata, activePDFURL != nil {
            if let pageNum = Int(raw), pageNum >= 1, pageNum <= meta.pageCount {
                await selectPDFPage(pageNum - 1, recordJump: true)
            } else {
                showToast("Enter page 1–\(max(1, meta.pageCount))")
            }
        } else if let doc = activeEPUB {
            if let chNum = Int(raw), chNum >= 1, chNum <= doc.spineHrefs.count {
                await selectEPUBSpine(chNum - 1)
            } else if let hit = doc.toc.first(where: { $0.title.localizedCaseInsensitiveContains(raw) }) {
                await selectEPUBSpine(hit.spineIndex)
            } else {
                showToast("No chapter matched '\(raw)'")
            }
        }
    }

    public func increaseReadingScale() {
        if activePDFURL != nil {
            zoomInPDF()
            showToast("Zoom \(Int((pdfZoomScale * 100).rounded()))%")
        } else if activeEPUB != nil {
            typography.fontSize = min(28, typography.fontSize + 1)
            saveTypography()
            showToast("Text size \(Int(typography.fontSize)) pt")
        }
    }

    public func decreaseReadingScale() {
        if activePDFURL != nil {
            zoomOutPDF()
            showToast("Zoom \(Int((pdfZoomScale * 100).rounded()))%")
        } else if activeEPUB != nil {
            typography.fontSize = max(14, typography.fontSize - 1)
            saveTypography()
            showToast("Text size \(Int(typography.fontSize)) pt")
        }
    }

    public func resetReadingScale() {
        if activePDFURL != nil {
            resetPDFZoom()
            showToast("Fit page width")
        } else if activeEPUB != nil {
            typography.fontSize = 18
            saveTypography()
            showToast("Text size 18 pt")
        }
    }

    public func cycleActiveReadingTheme() {
        if activePDFURL != nil {
            cyclePDFAppearance()
            showToast("PDF paper: \(pdfAppearance.label)")
        } else {
            let all = ReaderTheme.allCases
            if let idx = all.firstIndex(of: typography.theme) {
                typography.theme = all[(idx + 1) % all.count]
            } else {
                typography.theme = .auto
            }
            saveTypography()
            showToast("Theme: \(typography.theme.rawValue)")
        }
    }

    public func toggleEPUBReadingFlow() {
        typography.readingFlow = (typography.readingFlow == .paginated) ? .scroll : .paginated
        saveTypography()
        showToast("EPUB flow: \(typography.readingFlow.rawValue)")
    }

    public func updateEPUBPagination(
        spread: Int,
        totalSpreads: Int,
        page: Int,
        pageEnd: Int,
        totalPages: Int,
        colsPerView: Int
    ) {
        let clampedTotalSpreads = max(1, totalSpreads)
        let clampedSpread = min(max(1, spread), clampedTotalSpreads)
        let clampedTotalPages = max(1, totalPages)
        let clampedPage = min(max(1, page), clampedTotalPages)
        let clampedPageEnd = min(max(clampedPage, pageEnd), clampedTotalPages)
        let clampedCols = max(1, colsPerView)
        if epubTotalSpreads == clampedTotalSpreads
            && epubCurrentSpread == clampedSpread
            && epubTotalPages == clampedTotalPages
            && epubCurrentPage == clampedPage
            && epubCurrentPageEnd == clampedPageEnd
            && epubColumnsPerSpread == clampedCols {
            return
        }
        epubTotalSpreads = clampedTotalSpreads
        epubCurrentSpread = clampedSpread
        epubTotalPages = clampedTotalPages
        epubCurrentPage = clampedPage
        epubCurrentPageEnd = clampedPageEnd
        epubColumnsPerSpread = clampedCols
    }

    public func stepEPUBPage(delta: Int) {
        epubPendingCommand = delta < 0 ? "pagePrev" : "pageNext"
        epubCommandToken += 1
    }

    public func jumpToEPUBSpread(_ oneBasedSpread: Int) {
        epubGoToSpreadTarget = min(max(1, oneBasedSpread), max(1, epubTotalSpreads))
        epubPendingCommand = "goToSpread"
        epubCommandToken += 1
    }

    public func selectTabByNumber(_ oneBasedIndex: Int) async {
        let idx = oneBasedIndex - 1
        guard idx >= 0, idx < openTabs.count else { return }
        await selectTab(id: openTabs[idx].id)
    }

    public func navigateBackOrPrevious() async {
        if activeEPUB != nil {
            await selectEPUBSpine(activeEPUBSpineIndex - 1)
        } else if activePDFURL != nil {
            if !pdfJumpBackStack.isEmpty {
                await jumpBackInPDF()
            } else {
                await selectPDFPage(activePDFPageIndex - 1)
            }
        }
    }

    public func navigateForwardOrNext() async {
        if activeEPUB != nil {
            await selectEPUBSpine(activeEPUBSpineIndex + 1)
        } else if activePDFURL != nil {
            if !pdfJumpForwardStack.isEmpty {
                await jumpForwardInPDF()
            } else {
                await selectPDFPage(activePDFPageIndex + 1)
            }
        }
    }

    @discardableResult
    public func handleEscapeKey() -> Bool {
        if isCommandPalettePresented {
            closeCommandPalette()
            return true
        }
        if isShortcutsHUDPresented {
            isShortcutsHUDPresented = false
            return true
        }
        if isGoToPagePresented {
            closeGoToPage()
            return true
        }
        if isInlineFindPresented {
            closeInlineFind()
            return true
        }
        if activeSheet != nil {
            activeSheet = nil
            return true
        }
        if selectedStampId != nil {
            selectedStampId = nil
            return true
        }
        if isReaderChromeHidden {
            withAnimation(.easeInOut(duration: 0.18)) {
                isReaderChromeHidden = false
            }
            return true
        }
        return false
    }

    public func commandPaletteItems() -> [CommandPaletteItem] {
        var actions: [CommandPaletteItem] = [
            CommandPaletteItem(id: "act:open-file", title: "Open PDF or EPUB…", subtitle: "File", symbol: "doc.badge.plus", shortcut: "⌘O", kind: .action("open-file")),
            CommandPaletteItem(id: "act:tab-shelf", title: "Library", subtitle: "View", symbol: "books.vertical", shortcut: "⌘1", kind: .action("tab-shelf")),
            CommandPaletteItem(id: "act:tab-read", title: "Read", subtitle: "View", symbol: "book.pages", shortcut: "⌘2", kind: .action("tab-read")),
            CommandPaletteItem(id: "act:tab-map", title: "Atlas", subtitle: "View", symbol: "sparkles", shortcut: "⌘3", kind: .action("tab-map")),
            CommandPaletteItem(id: "act:tab-search", title: "Search", subtitle: "View", symbol: "magnifyingglass", shortcut: "⌘4", kind: .action("tab-search")),
            CommandPaletteItem(id: "act:toggle-sidebar", title: isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", subtitle: "View", symbol: "sidebar.left", shortcut: "⌘\\", kind: .action("toggle-sidebar")),
            CommandPaletteItem(id: "act:shortcuts", title: "Keyboard Shortcuts", subtitle: "Help", symbol: "keyboard", shortcut: "?", kind: .action("shortcuts")),
            CommandPaletteItem(id: "act:settings", title: "Settings", subtitle: "App", symbol: "gearshape", shortcut: "⌘,", kind: .action("settings")),
        ]
        if activeBook != nil {
            actions.append(contentsOf: [
                CommandPaletteItem(id: "act:find", title: "Find in Document", subtitle: "Reader", symbol: "magnifyingglass", shortcut: "⌘F", kind: .action("find")),
                CommandPaletteItem(id: "act:goto-page", title: activePDFURL != nil ? "Go to Page…" : "Go to Chapter…", subtitle: "Reader", symbol: "arrow.right.to.line", shortcut: "⌥⌘G", kind: .action("goto-page")),
                CommandPaletteItem(id: "act:toc", title: "Contents & Thumbnails", subtitle: "Reader", symbol: "list.bullet", shortcut: "⌘T", kind: .action("toc")),
                CommandPaletteItem(id: "act:toggle-focus", title: "Toggle Focus Mode", subtitle: "Reader", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⌘.", kind: .action("toggle-focus")),
                CommandPaletteItem(id: "act:cycle-theme", title: "Cycle Reading Theme", subtitle: "Reader", symbol: "circle.lefthalf.filled", shortcut: "⌥⌘T", kind: .action("cycle-theme")),
                CommandPaletteItem(id: "act:zoom-in", title: activePDFURL != nil ? "Zoom In" : "Larger Text", subtitle: "Scale", symbol: "plus.magnifyingglass", shortcut: "⌘+", kind: .action("zoom-in")),
                CommandPaletteItem(id: "act:zoom-out", title: activePDFURL != nil ? "Zoom Out" : "Smaller Text", subtitle: "Scale", symbol: "minus.magnifyingglass", shortcut: "⌘-", kind: .action("zoom-out")),
                CommandPaletteItem(id: "act:zoom-reset", title: activePDFURL != nil ? "Fit Page Width" : "Reset Text Size", subtitle: "Scale", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⌘0", kind: .action("zoom-reset")),
            ])
        }
        if activeEPUB != nil {
            actions.append(contentsOf: [
                CommandPaletteItem(id: "act:typography", title: "Typography & Reading Flow", subtitle: "EPUB", symbol: "textformat.size", shortcut: "⇧⌘T", kind: .action("typography")),
                CommandPaletteItem(id: "act:toggle-flow", title: typography.readingFlow == .paginated ? "Switch EPUB to Scroll" : "Switch EPUB to Pages", subtitle: "EPUB", symbol: "book.pages", shortcut: "⌥⌘P", kind: .action("toggle-flow")),
            ])
        }
        if activePDFURL != nil {
            actions.append(contentsOf: [
                CommandPaletteItem(id: "act:pdf-sign", title: "Sign & Stamp PDF", subtitle: "PDF", symbol: "signature", shortcut: "⌥⌘S", kind: .action("pdf-sign")),
                CommandPaletteItem(id: "act:pdf-crop", title: "Toggle Margin Crop", subtitle: "PDF", symbol: "crop", shortcut: "⌥⌘C", kind: .action("pdf-crop")),
                CommandPaletteItem(id: "act:pdf-twoup", title: "Toggle Two-Page Spread", subtitle: "PDF", symbol: "rectangle.split.2x1", shortcut: "⌥⌘2", kind: .action("pdf-twoup")),
            ])
        }
        if isServerConnected {
            actions.append(CommandPaletteItem(id: "act:sync-server", title: "Sync Home Library", subtitle: "Server", symbol: "arrow.triangle.2.circlepath", shortcut: "⌘R", kind: .action("sync-server")))
            if activeBook != nil {
                actions.append(CommandPaletteItem(id: "act:send-inbox", title: "Send Active Document to Home Inbox", subtitle: "Sync", symbol: "paperplane", shortcut: "⇧⌘U", kind: .action("send-inbox")))
            }
        }

        let openTabIds = Set(openTabs.map(\.id))
        var seenBookIds: Set<String> = []
        var bookItems: [CommandPaletteItem] = []
        for tab in openTabs {
            seenBookIds.insert(tab.book.id)
            bookItems.append(
                CommandPaletteItem(
                    id: "book:\(tab.book.id)",
                    title: tab.book.title,
                    subtitle: "Open Tab · \(tab.book.format.label)",
                    symbol: tab.book.format == .epub ? "book.closed.fill" : "doc.text.fill",
                    kind: .book(tab.book)
                )
            )
        }
        for book in books where !seenBookIds.contains(book.id) {
            seenBookIds.insert(book.id)
            bookItems.append(
                CommandPaletteItem(
                    id: "book:\(book.id)",
                    title: book.title,
                    subtitle: openTabIds.contains(book.id) ? "Open Tab" : book.shortCitation,
                    symbol: book.format == .epub ? "book.closed" : "doc.text",
                    kind: .book(book)
                )
            )
        }

        let q = commandPaletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            return Array((actions.prefix(6) + bookItems.prefix(8)).prefix(14))
        }

        func score(_ item: CommandPaletteItem) -> Int? {
            let t = item.title.lowercased()
            let s = item.subtitle.lowercased()
            if t.hasPrefix(q) { return 3 }
            if t.contains(q) { return 2 }
            if s.contains(q) { return 1 }
            if case .book(let b) = item.kind, (b.canonicalId?.lowercased().contains(q) ?? false) {
                return 1
            }
            return nil
        }

        let combined = (actions + bookItems).compactMap { item -> (Int, CommandPaletteItem)? in
            guard let sc = score(item) else { return nil }
            return (sc, item)
        }
        return combined
            .sorted { a, b in
                if a.0 != b.0 { return a.0 > b.0 }
                return a.1.title.localizedCaseInsensitiveCompare(b.1.title) == .orderedAscending
            }
            .map(\.1)
            .prefix(16)
            .map { $0 }
    }

    public func moveCommandPaletteSelection(delta: Int) {
        let items = commandPaletteItems()
        guard !items.isEmpty else {
            commandPaletteSelectionIndex = 0
            return
        }
        let next = ((commandPaletteSelectionIndex + delta) % items.count + items.count) % items.count
        commandPaletteSelectionIndex = next
    }

    public func executeSelectedCommandPaletteItem() async {
        let items = commandPaletteItems()
        guard !items.isEmpty else { return }
        let idx = min(max(0, commandPaletteSelectionIndex), items.count - 1)
        await executeCommandPaletteItem(items[idx])
    }

    public func executeCommandPaletteItem(_ item: CommandPaletteItem) async {
        closeCommandPalette()
        switch item.kind {
        case .book(let book):
            await openBook(book, switchTab: true)
        case .action(let actionId):
            switch actionId {
            case "open-file":
                #if os(macOS)
                openExternalFileWithPanel()
                #else
                requestFileImport()
                #endif
            case "tab-shelf": selectedTab = .shelf
            case "tab-read": selectedTab = .read
            case "tab-map": selectedTab = .map
            case "tab-search":
                selectedTab = .search
                searchFocusToken += 1
            case "toggle-sidebar": toggleSidebar()
            case "shortcuts": isShortcutsHUDPresented = true
            case "settings": transitionSheet(to: .settings)
            case "find": openInlineFind()
            case "goto-page": openGoToPage()
            case "toc": transitionSheet(to: .toc)
            case "toggle-focus":
                withAnimation(.easeInOut(duration: 0.18)) {
                    isReaderChromeHidden.toggle()
                }
            case "cycle-theme": cycleActiveReadingTheme()
            case "zoom-in": increaseReadingScale()
            case "zoom-out": decreaseReadingScale()
            case "zoom-reset": resetReadingScale()
            case "typography": transitionSheet(to: .typography)
            case "toggle-flow": toggleEPUBReadingFlow()
            case "pdf-sign": transitionSheet(to: .pdfSign)
            case "pdf-crop": togglePDFAutoCrop()
            case "pdf-twoup": togglePDFTwoUpMode()
            case "sync-server": await syncServerCatalog(silent: false)
            case "send-inbox": await sendActiveDocumentToHomeInbox()
            default: break
            }
        }
    }

    @discardableResult
    public func handleSingleKeyCommand(_ key: String, shift: Bool = false) -> Bool {
        if key == "Escape" {
            return handleEscapeKey()
        }
        if key == "?" {
            toggleShortcutsHUD()
            return true
        }
        if isCommandPalettePresented || isShortcutsHUDPresented || isInlineFindPresented || isGoToPagePresented || activeSheet != nil {
            return false
        }
        if key == "/" {
            if selectedTab == .read && activeBook != nil {
                openInlineFind()
            } else {
                selectedTab = .search
                searchFocusToken += 1
            }
            return true
        }
        if key == ":" && selectedTab == .read && activeBook != nil {
            openGoToPage()
            return true
        }

        if selectedTab == .shelf {
            switch key {
            case "j", "ArrowDown", "l", "ArrowRight":
                moveShelfFocus(delta: 1)
                return true
            case "k", "ArrowUp", "h", "ArrowLeft":
                moveShelfFocus(delta: -1)
                return true
            case "Return", "Enter", "\r":
                return openFocusedShelfBook()
            default:
                return false
            }
        }

        if selectedTab == .search {
            switch key {
            case "j", "ArrowDown":
                moveSearchSelection(delta: 1)
                return true
            case "k", "ArrowUp":
                moveSearchSelection(delta: -1)
                return true
            case "Return", "Enter", "\r":
                return openSelectedSearchItem()
            default:
                return false
            }
        }

        if selectedTab == .map {
            if key == "a", let activeMatch = activeBook.flatMap({ manifoldWork(for: $0) }) {
                focusWorkInAtlas(activeMatch)
                return true
            }
            return false
        }

        guard selectedTab == .read && activeBook != nil else { return false }
        if (key == "Backspace" || key == "Delete"), let sid = selectedStampId {
            removePendingStamp(id: sid)
            return true
        }
        switch key {
        case "f":
            withAnimation(.easeInOut(duration: 0.18)) { isReaderChromeHidden.toggle() }
            return true
        case "t":
            cycleActiveReadingTheme()
            return true
        case "m":
            tocSegment = 1
            activeSheet = .toc
            return true
        case "p":
            guard activeEPUB != nil else { return false }
            toggleEPUBReadingFlow()
            return true
        case "c":
            guard activePDFURL != nil else { return false }
            togglePDFAutoCrop()
            return true
        case "2":
            guard activePDFURL != nil else { return false }
            togglePDFTwoUpMode()
            return true
        case "a":
            guard let b = activeBook, manifoldWork(for: b) != nil else { return false }
            focusBookInAtlas(b)
            return true
        case "s":
            guard activePDFURL != nil else { return false }
            activeSheet = .pdfSign
            return true
        case "[":
            guard activeEPUB != nil || activePDFURL != nil else { return false }
            Task { await self.navigateBackOrPrevious() }
            return true
        case "]":
            guard activeEPUB != nil || activePDFURL != nil else { return false }
            Task { await self.navigateForwardOrNext() }
            return true
        case "n":
            guard !inlineFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            stepInlineFind(delta: shift ? -1 : 1)
            return true
        case "N":
            guard !inlineFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            stepInlineFind(delta: -1)
            return true
        case "+", "=":
            guard activePDFURL != nil || activeEPUB != nil else { return false }
            increaseReadingScale()
            return true
        case "-":
            guard activePDFURL != nil || activeEPUB != nil else { return false }
            decreaseReadingScale()
            return true
        case "0":
            guard activePDFURL != nil || activeEPUB != nil else { return false }
            resetReadingScale()
            return true
        case "H":
            let quote = activeSelectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return false }
            Task { await self.saveQuickHighlight(quote: quote) }
            return true
        case "h", "ArrowLeft":
            if activeEPUB != nil {
                epubPendingCommand = "pagePrev"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                if pdfTwoColumnMode && pdfDetectedColumnCount >= 2 {
                    Task { await self.stepPDFColumn(delta: -1) }
                } else if pdfDisplayLayout == .scroll || pdfZoomScale > 1.02 {
                    pdfPendingCommand = "pageUp"
                    pdfCommandToken += 1
                } else {
                    pdfPendingCommand = "prevPage"
                    pdfCommandToken += 1
                }
                return true
            }
            return false
        case "l", "ArrowRight":
            if activeEPUB != nil {
                epubPendingCommand = "pageNext"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                if pdfTwoColumnMode && pdfDetectedColumnCount >= 2 {
                    Task { await self.stepPDFColumn(delta: 1) }
                } else if pdfDisplayLayout == .scroll || pdfZoomScale > 1.02 {
                    pdfPendingCommand = "pageDown"
                    pdfCommandToken += 1
                } else {
                    pdfPendingCommand = "nextPage"
                    pdfCommandToken += 1
                }
                return true
            }
            return false
        case "j", "ArrowDown":
            if activeEPUB != nil {
                epubPendingCommand = "scrollDown"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "scrollDown"
                pdfCommandToken += 1
                return true
            }
            return false
        case "k", "ArrowUp":
            if activeEPUB != nil {
                epubPendingCommand = "scrollUp"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "scrollUp"
                pdfCommandToken += 1
                return true
            }
            return false
        case "d":
            if activeEPUB != nil {
                epubPendingCommand = "halfPageDown"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "halfPageDown"
                pdfCommandToken += 1
                return true
            }
            return false
        case "u":
            if activeEPUB != nil {
                epubPendingCommand = "halfPageUp"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "halfPageUp"
                pdfCommandToken += 1
                return true
            }
            return false
        case "PageDown":
            if activeEPUB != nil {
                epubPendingCommand = "pageNext"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "pageDown"
                pdfCommandToken += 1
                return true
            }
            return false
        case "PageUp", "Backspace":
            if activeEPUB != nil {
                epubPendingCommand = "pagePrev"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "pageUp"
                pdfCommandToken += 1
                return true
            }
            return false
        case " ":
            if activeEPUB != nil {
                epubPendingCommand = shift ? "pagePrev" : "pageNext"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = shift ? "pageUp" : "pageDown"
                pdfCommandToken += 1
                return true
            }
            return false
        case "g", "Home":
            if activeEPUB != nil {
                epubPendingCommand = "jumpTop"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "jumpTop"
                pdfCommandToken += 1
                return true
            }
            return false
        case "G", "End":
            if activeEPUB != nil {
                epubPendingCommand = "jumpBottom"
                epubCommandToken += 1
                return true
            } else if activePDFURL != nil {
                pdfPendingCommand = "jumpBottom"
                pdfCommandToken += 1
                return true
            }
            return false
        default:
            return false
        }
    }

    public func moveShelfFocus(delta: Int) {
        let items = filteredShelfBooks
        guard !items.isEmpty else {
            focusedShelfBookId = nil
            return
        }
        if let cur = focusedShelfBookId, let idx = items.firstIndex(where: { $0.id == cur }) {
            let next = ((idx + delta) % items.count + items.count) % items.count
            focusedShelfBookId = items[next].id
        } else {
            focusedShelfBookId = delta >= 0 ? items.first?.id : items.last?.id
        }
    }

    @discardableResult
    public func openFocusedShelfBook() -> Bool {
        let target = focusedShelfBookId.flatMap { id in filteredShelfBooks.first(where: { $0.id == id }) }
            ?? (activeShelfFilter == "All" ? continueReadingBook : nil)
            ?? filteredShelfBooks.first
        guard let target else { return false }
        Task { await self.openBook(target, switchTab: true) }
        return true
    }

    private func searchNavigationPools() -> (books: [BookItem], works: [ManifoldReaderWork]) {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [BookItem]
        if q.isEmpty {
            base = books
        } else if !serverSearchResults.isEmpty {
            base = serverSearchResults
        } else {
            base = books.filter {
                $0.title.lowercased().contains(q)
                    || $0.author.lowercased().contains(q)
                    || $0.genre.lowercased().contains(q)
                    || ($0.canonicalId?.lowercased().contains(q) ?? false)
                    || $0.summary.lowercased().contains(q)
            }
        }
        let filteredBooks: [BookItem]
        switch searchScope {
        case .all: filteredBooks = base
        case .books: filteredBooks = base.filter { $0.format == .epub || ($0.canonicalId?.hasPrefix("isbn:") ?? false) || ($0.canonicalId?.hasPrefix("gutenberg:") ?? false) }
        case .papers: filteredBooks = base.filter { $0.format == .article || ($0.canonicalId?.hasPrefix("doi:") ?? false) || ($0.canonicalId?.hasPrefix("pmid:") ?? false) || ($0.canonicalId?.hasPrefix("arxiv:") ?? false) }
        case .offline: filteredBooks = base.filter(\.isOfflineCached)
        }

        let pool = recommendedDiscoveryWorks
        let filteredWorks: [ManifoldReaderWork] = q.isEmpty ? Array(pool.prefix(12)) : pool.filter {
            $0.title.lowercased().contains(q)
                || $0.creator.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || ($0.subject?.lowercased().contains(q) ?? false)
                || $0.workId.lowercased().contains(q)
        }
        return (filteredBooks, filteredWorks)
    }

    public func moveSearchSelection(delta: Int) {
        let pools = searchNavigationPools()
        let total = pools.books.count + pools.works.count
        guard total > 0 else {
            selectedSearchIndex = nil
            return
        }
        if let cur = selectedSearchIndex {
            selectedSearchIndex = ((cur + delta) % total + total) % total
        } else {
            selectedSearchIndex = delta >= 0 ? 0 : (total - 1)
        }
    }

    @discardableResult
    public func openSelectedSearchItem() -> Bool {
        let pools = searchNavigationPools()
        let total = pools.books.count + pools.works.count
        guard total > 0 else { return false }
        let idx = min(max(0, selectedSearchIndex ?? 0), total - 1)
        if idx < pools.books.count {
            let book = pools.books[idx]
            Task { await self.openBook(book, switchTab: true) }
            return true
        }
        let work = pools.works[idx - pools.books.count]
        Task { await self.openOrInspect(work) }
        return true
    }
}
