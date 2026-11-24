import Foundation

public enum BookFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case epub
    case pdf
    case article

    public var label: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .article: return "ARTICLE"
        }
    }
}

public enum BookSource: String, Codable, Sendable, Hashable {
    case showcase
    case localImport
    case homeServer
    case openAccess
}

public struct ReadingLocator: Codable, Sendable, Hashable {
    public var spine: Int
    public var fraction: Double
    public var wordOffset: Int?
    public var pageIndex: Int?
    public var spineCount: Int?
    public var overallProgress: Double?
    public var updatedAt: Date

    public init(
        spine: Int = 0,
        fraction: Double = 0,
        wordOffset: Int? = nil,
        pageIndex: Int? = nil,
        spineCount: Int? = nil,
        overallProgress: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.spine = max(0, spine)
        self.fraction = min(max(fraction, 0), 1)
        self.wordOffset = wordOffset
        self.pageIndex = pageIndex
        self.spineCount = spineCount
        self.overallProgress = overallProgress.map { min(max($0, 0), 1) }
        self.updatedAt = updatedAt
    }

    public var effectiveProgress: Double {
        if let overallProgress {
            return min(max(overallProgress, 0), 1)
        }
        if let spineCount, spineCount > 0 {
            return min(max((Double(spine) + fraction) / Double(spineCount), 0), 1)
        }
        return fraction
    }

    /// Monotonic Last-Write-Wins merge matching paperlibrary-away's locator contract.
    public static func adoptIfNewer(local: ReadingLocator?, remote: ReadingLocator?) -> ReadingLocator? {
        guard let remote else { return local }
        guard let local else { return remote }
        if remote.updatedAt > local.updatedAt {
            return remote
        }
        if remote.updatedAt == local.updatedAt {
            if remote.effectiveProgress > local.effectiveProgress { return remote }
            if remote.spine > local.spine { return remote }
            if remote.spine == local.spine && remote.fraction > local.fraction { return remote }
        }
        return local
    }
}

public struct MapPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BookItem: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var canonicalId: String?
    public var title: String
    public var author: String
    public var year: Int?
    public var format: BookFormat
    public var source: BookSource
    public var genre: String
    public var subgenre: String
    public var summary: String
    public var shelfNames: [String]
    public var bytes: Int64
    public var isOfflineCached: Bool
    public var localFilePath: String?
    public var openAccessURL: String?
    public var epubURL: String?
    public var hasServerCover: Bool
    public var notesVersion: String?
    public var locator: ReadingLocator?
    public var point: MapPoint?
    public var lastOpenedAt: Date?

    public init(
        id: String,
        canonicalId: String? = nil,
        title: String,
        author: String,
        year: Int? = nil,
        format: BookFormat,
        source: BookSource,
        genre: String = "General",
        subgenre: String = "",
        summary: String = "",
        shelfNames: [String] = [],
        bytes: Int64 = 0,
        isOfflineCached: Bool = false,
        localFilePath: String? = nil,
        openAccessURL: String? = nil,
        epubURL: String? = nil,
        hasServerCover: Bool = false,
        notesVersion: String? = nil,
        locator: ReadingLocator? = nil,
        point: MapPoint? = nil,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.canonicalId = canonicalId
        self.title = title
        self.author = author
        self.year = year
        self.format = format
        self.source = source
        self.genre = genre
        self.subgenre = subgenre
        self.summary = summary
        self.shelfNames = shelfNames
        self.bytes = bytes
        self.isOfflineCached = isOfflineCached
        self.localFilePath = localFilePath
        self.openAccessURL = openAccessURL
        self.epubURL = epubURL
        self.hasServerCover = hasServerCover
        self.notesVersion = notesVersion
        self.locator = locator
        self.point = point
        self.lastOpenedAt = lastOpenedAt
    }

    public var effectiveProgress: Double {
        locator?.effectiveProgress ?? 0
    }

    public var isInProgress: Bool {
        guard let loc = locator else { return false }
        let hasActivity = loc.spine > 0 || loc.fraction > 0 || (loc.overallProgress ?? 0) > 0
        return hasActivity && effectiveProgress < 0.98
    }

    public var progressPercent: Int {
        guard locator != nil else { return 0 }
        return Int((effectiveProgress * 100).rounded())
    }

    public var shortCitation: String {
        if let year, year > 0 {
            return "\(author) · \(year)"
        }
        return author
    }
}

public struct ReadingSession: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var bookId: String
    public var startedAt: Date
    public var durationSeconds: Int
    public var startFraction: Double
    public var endFraction: Double

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        startedAt: Date = Date(),
        durationSeconds: Int,
        startFraction: Double,
        endFraction: Double
    ) {
        self.id = id
        self.bookId = bookId
        self.startedAt = startedAt
        self.durationSeconds = max(0, durationSeconds)
        self.startFraction = min(max(startFraction, 0), 1)
        self.endFraction = min(max(endFraction, 0), 1)
    }
}

/// Offline margin note matching paperlibrary-away's schema.
public struct MarginNote: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var spine: Int
    public var anchor: String
    public var kind: String
    public var label: String
    public var note: String
    public var source: String
    public var credit: String?
    public var image: String?
    public var map: String?

    public init(
        id: String,
        spine: Int,
        anchor: String,
        kind: String,
        label: String,
        note: String,
        source: String,
        credit: String? = nil,
        image: String? = nil,
        map: String? = nil
    ) {
        self.id = id
        self.spine = spine
        self.anchor = anchor
        self.kind = kind
        self.label = label
        self.note = note
        self.source = source
        self.credit = credit
        self.image = image
        self.map = map
    }
}

public struct ReadingHighlight: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var bookId: String
    public var canonicalId: String?
    public var bookTitle: String
    public var spine: Int
    public var quote: String
    public var note: String
    public var sentToCohort: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        canonicalId: String? = nil,
        bookTitle: String,
        spine: Int,
        quote: String,
        note: String = "",
        sentToCohort: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.canonicalId = canonicalId
        self.bookTitle = bookTitle
        self.spine = spine
        self.quote = quote
        self.note = note
        self.sentToCohort = sentToCohort
        self.createdAt = createdAt
    }
}

public struct CohortCardDraft: Codable, Sendable, Hashable {
    public var sourceBookId: String
    public var canonicalId: String?
    public var sourceTitle: String
    public var quote: String
    public var promptHint: String
    public var tags: [String]
    public var createdAt: Date

    public init(
        sourceBookId: String,
        canonicalId: String?,
        sourceTitle: String,
        quote: String,
        promptHint: String,
        tags: [String],
        createdAt: Date = Date()
    ) {
        self.sourceBookId = sourceBookId
        self.canonicalId = canonicalId
        self.sourceTitle = sourceTitle
        self.quote = quote
        self.promptHint = promptHint
        self.tags = tags
        self.createdAt = createdAt
    }
}

public struct NeighbourScore: Codable, Sendable, Hashable {
    public var workId: String
    public var sim: Double

    public init(workId: String, sim: Double) {
        self.workId = workId
        self.sim = sim
    }
}

public struct ResonanceLink: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(domain):\(workId)" }
    public var workId: String
    public var domain: String
    public var title: String
    public var sim: Double

    public init(workId: String, domain: String, title: String, sim: Double) {
        self.workId = workId
        self.domain = domain
        self.title = title
        self.sim = sim
    }
}

public struct ManifoldReaderWork: Identifiable, Codable, Sendable, Hashable {
    public var id: String { workId }
    public var workId: String
    public var title: String
    public var creator: String
    public var year: Int
    public var kind: String
    public var subject: String?
    public var format: BookFormat
    public var summary: String
    public var shard: String
    public var x: Double
    public var y: Double
    public var vec32: [Int]
    public var neighbours: [NeighbourScore]
    public var resonances: [ResonanceLink]
    public var epubURL: String?
    public var openAccessURL: String?

    public init(
        workId: String,
        title: String,
        creator: String,
        year: Int,
        kind: String,
        subject: String? = nil,
        format: BookFormat,
        summary: String,
        shard: String,
        x: Double,
        y: Double,
        vec32: [Int],
        neighbours: [NeighbourScore] = [],
        resonances: [ResonanceLink] = [],
        epubURL: String? = nil,
        openAccessURL: String? = nil
    ) {
        self.workId = workId
        self.title = title
        self.creator = creator
        self.year = year
        self.kind = kind
        self.subject = subject
        self.format = format
        self.summary = summary
        self.shard = shard
        self.x = x
        self.y = y
        self.vec32 = vec32
        self.neighbours = neighbours
        self.resonances = resonances
        self.epubURL = epubURL
        self.openAccessURL = openAccessURL
    }

    public func toBookItem() -> BookItem {
        BookItem(
            id: workId.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-"),
            canonicalId: workId,
            title: title,
            author: creator,
            year: year,
            format: format,
            source: .showcase,
            genre: subject ?? "Showcase",
            subgenre: kind,
            summary: summary,
            shelfNames: ["Open Showcase"],
            bytes: 0,
            isOfflineCached: false,
            openAccessURL: openAccessURL,
            epubURL: epubURL,
            point: MapPoint(x: x, y: y)
        )
    }
}

public struct LensAnchorItem: Codable, Sendable, Hashable {
    public var workId: String
    public var weight: Double

    public init(workId: String, weight: Double) {
        self.workId = workId
        self.weight = weight
    }
}

public struct LensTransitionItem: Codable, Sendable, Hashable {
    public var from: String
    public var to: String
    public var weight: Double

    public init(from: String, to: String, weight: Double) {
        self.from = from
        self.to = to
        self.weight = weight
    }
}

public struct ReaderLens: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var summary: String
    public var issuerHandle: String
    public var anchors: [LensAnchorItem]
    public var transitions: [LensTransitionItem]

    public init(
        id: String,
        name: String,
        summary: String,
        issuerHandle: String,
        anchors: [LensAnchorItem],
        transitions: [LensTransitionItem] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.issuerHandle = issuerHandle
        self.anchors = anchors
        self.transitions = transitions
    }
}

public struct LibraryShelf: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var itemIds: [String]

    public init(id: String, title: String, itemIds: [String]) {
        self.id = id
        self.title = title
        self.itemIds = itemIds
    }
}

public enum ReaderTheme: String, Codable, Sendable, CaseIterable {
    case auto = "Auto"
    case paper = "Paper"
    case sepia = "Sepia"
    case ink = "Ink"
}

public enum ReaderFontFamily: String, Codable, Sendable, CaseIterable {
    case serif = "Serif"
    case sans = "Sans"
    case mono = "Mono"
}

public enum ReaderMarginWidth: String, Codable, Sendable, CaseIterable {
    case compact = "Compact"
    case standard = "Standard"
    case wide = "Wide"

    public var horizontalPaddingPx: Int {
        switch self {
        case .compact: return 14
        case .standard: return 22
        case .wide: return 34
        }
    }
}

public enum ReaderTextAlignment: String, Codable, Sendable, CaseIterable {
    case left = "Left"
    case justified = "Justified"

    public var cssTextAlign: String {
        switch self {
        case .left: return "left"
        case .justified: return "justify"
        }
    }
}

public enum ShelfSortOrder: String, Codable, Sendable, CaseIterable {
    case recent = "Recent"
    case title = "Title"
    case author = "Author"
    case progress = "Progress"
}

public struct ReaderTypography: Codable, Sendable, Hashable {
    public var theme: ReaderTheme
    public var fontFamily: ReaderFontFamily
    public var fontSize: Double
    public var lineHeight: Double
    public var marginWidth: ReaderMarginWidth
    public var textAlignment: ReaderTextAlignment

    public static let `default` = ReaderTypography(
        theme: .auto,
        fontFamily: .serif,
        fontSize: 18,
        lineHeight: 1.58,
        marginWidth: .standard,
        textAlignment: .left
    )

    public init(
        theme: ReaderTheme,
        fontFamily: ReaderFontFamily,
        fontSize: Double,
        lineHeight: Double,
        marginWidth: ReaderMarginWidth = .standard,
        textAlignment: ReaderTextAlignment = .left
    ) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = min(max(fontSize, 13), 30)
        self.lineHeight = min(max(lineHeight, 1.2), 2.1)
        self.marginWidth = marginWidth
        self.textAlignment = textAlignment
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case fontFamily
        case fontSize
        case lineHeight
        case marginWidth
        case textAlignment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let theme = try c.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .auto
        let fontFamily = try c.decodeIfPresent(ReaderFontFamily.self, forKey: .fontFamily) ?? .serif
        let fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18
        let lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.58
        let marginWidth = try c.decodeIfPresent(ReaderMarginWidth.self, forKey: .marginWidth) ?? .standard
        let textAlignment = try c.decodeIfPresent(ReaderTextAlignment.self, forKey: .textAlignment) ?? .left
        self.init(
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            lineHeight: lineHeight,
            marginWidth: marginWidth,
            textAlignment: textAlignment
        )
    }
}

public struct PendingProgressEvent: Codable, Sendable, Hashable {
    public var id: String
    public var bookId: String
    public var canonicalId: String?
    public var spine: Int
    public var fraction: Double
    public var wordOffset: Int?
    public var pageIndex: Int?
    public var spineCount: Int?
    public var overallProgress: Double?
    public var updatedAt: Date
    public var readingSeconds: Int

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        canonicalId: String? = nil,
        spine: Int,
        fraction: Double,
        wordOffset: Int? = nil,
        pageIndex: Int? = nil,
        spineCount: Int? = nil,
        overallProgress: Double? = nil,
        updatedAt: Date = Date(),
        readingSeconds: Int = 0
    ) {
        self.id = id
        self.bookId = bookId
        self.canonicalId = canonicalId
        self.spine = spine
        self.fraction = fraction
        self.wordOffset = wordOffset
        self.pageIndex = pageIndex
        self.spineCount = spineCount
        self.overallProgress = overallProgress
        self.updatedAt = updatedAt
        self.readingSeconds = readingSeconds
    }
}

public enum CanonicalIDNormalizer {
    private static let isbnRegex = try! NSRegularExpression(pattern: #"97[89][0-9]{10}"#)
    private static let doiRegex = try! NSRegularExpression(pattern: #"10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+"#)
    private static let arxivRegex = try! NSRegularExpression(pattern: #"(?:arxiv:)?([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?)"#, options: [.caseInsensitive])
    private static let gutenbergRegex = try! NSRegularExpression(pattern: #"(?:urn:)?gutenberg:([1-9][0-9]{0,7})"#, options: [.caseInsensitive])
    private static let pmidRegex = try! NSRegularExpression(pattern: #"pmid:([1-9][0-9]{0,10})"#, options: [.caseInsensitive])
    private static let olRegex = try! NSRegularExpression(pattern: #"(?:ol:)?(OL[1-9][0-9]{0,10}[WM])"#)
    private static let wikidataRegex = try! NSRegularExpression(pattern: #"(?:wikidata:)?(Q[1-9][0-9]{0,12})"#)

    public static func isValidISBN13(_ digits: String) -> Bool {
        let chars = digits.filter(\.isNumber)
        guard chars.count == 13, chars.hasPrefix("978") || chars.hasPrefix("979") else { return false }
        let nums = chars.compactMap { Int(String($0)) }
        guard nums.count == 13 else { return false }
        var sum = 0
        for idx in 0..<12 {
            sum += nums[idx] * (idx.isMultiple(of: 2) ? 1 : 3)
        }
        let check = (10 - (sum % 10)) % 10
        return check == nums[12]
    }

    public static func extractCanonicalId(from text: String) -> String? {
        let nsText = text as NSString
        if let match = gutenbergRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
            return "gutenberg:\(nsText.substring(with: match.range(at: 1)))"
        }
        if let match = pmidRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
            return "pmid:\(nsText.substring(with: match.range(at: 1)))"
        }
        if let match = olRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
            return "ol:\(nsText.substring(with: match.range(at: 1)))"
        }
        if let match = wikidataRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
           text.range(of: "wikidata", options: .caseInsensitive) != nil {
            return "wikidata:\(nsText.substring(with: match.range(at: 1)))"
        }
        let compact = text.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        let nsCompact = compact as NSString
        if let match = isbnRegex.firstMatch(in: compact, range: NSRange(location: 0, length: nsCompact.length)) {
            let candidate = nsCompact.substring(with: match.range)
            if isValidISBN13(candidate) {
                return "isbn:\(candidate)"
            }
        }
        if let match = arxivRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
           text.range(of: "arxiv", options: .caseInsensitive) != nil {
            return "arxiv:\(nsText.substring(with: match.range(at: 1)))"
        }
        if let match = doiRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
            var doi = nsText.substring(with: match.range)
            while let last = doi.last, ".,;)>]".contains(last) {
                doi.removeLast()
            }
            return "doi:\(doi)"
        }
        return nil
    }
}
