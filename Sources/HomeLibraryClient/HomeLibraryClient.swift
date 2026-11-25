import Foundation
import ReaderModel
import Security

public enum ReaderKeychain {
    private static let service = "md.cohort.reader.homeserver"

    public static func savePassword(_ password: String, server: String) {
        let acct = normalizedServer(server)
        guard !acct.isEmpty, let data = password.data(using: .utf8) else { return }
        deletePassword(server: acct)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func loadPassword(server: String) -> String? {
        let acct = normalizedServer(server)
        guard !acct.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(server: String) {
        let acct = normalizedServer(server)
        guard !acct.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func normalizedServer(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty && !s.contains("://") {
            s = "https://\(s)"
        }
        return s
    }
}

public enum HomeLibraryError: LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case emptyPayload

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Home Library Server URL"
        case .unauthorized: return "Incorrect Home Library passphrase"
        case .serverError(let code): return "Home Library Server returned HTTP \(code)"
        case .emptyPayload: return "Book payload was empty"
        }
    }
}

public struct HomeLibraryCatalog: Sendable {
    public var serverName: String
    public var shelves: [LibraryShelf]
    public var items: [BookItem]
}

public struct HomeLibrarySpace: Sendable {
    public var model: String
    public var count: Int
    public var works: [ManifoldReaderWork]
    public var lenses: [ReaderLens]
    public var slugByWorkId: [String: String]

    public init(
        model: String,
        count: Int,
        works: [ManifoldReaderWork],
        lenses: [ReaderLens],
        slugByWorkId: [String: String]
    ) {
        self.model = model
        self.count = count
        self.works = works
        self.lenses = lenses
        self.slugByWorkId = slugByWorkId
    }
}

private struct WireSpaceResponse: Decodable {
    struct RawNeighbour: Decodable {
        var slug: String?
        var workId: String?
        var sim: Double
    }
    struct RawItem: Decodable {
        var slug: String
        var canonicalId: String?
        var title: String
        var creator: String?
        var year: Int?
        var kind: String?
        var format: String?
        var shelves: [String]?
        var summary: String?
        var x: Double?
        var y: Double?
        var vec32: [Int]?
        var neighbours: [RawNeighbour]?
    }
    struct RawLens: Decodable {
        var id: String
        var name: String
        var summary: String?
        var issuerHandle: String?
        var anchors: [LensAnchorItem]
        var transitions: [LensTransitionItem]?
    }
    var model: String?
    var count: Int?
    var items: [RawItem]
    var lenses: [RawLens]?
}

private struct WireHomeResponse: Decodable {
    var serverName: String?
    var shelves: [LibraryShelf]
    var items: [WireBookItem]
}

private struct WireSearchResponse: Decodable {
    var items: [WireBookItem]
}

private struct WireMatchResponse: Decodable {
    var matches: [String: WireBookItem]
}

private struct WireNotesResponse: Decodable {
    var notes: [MarginNote]
}

private struct WireProgressResponse: Decodable {
    var accepted: Int
}

private struct WireBookItem: Decodable {
    var id: String
    var canonicalId: String?
    var title: String
    var author: String
    var year: Int?
    var format: String
    var genre: String?
    var subgenre: String?
    var summary: String?
    var shelves: [String]?
    var bytes: Int64?
    var hasCover: Bool?
    var notesVersion: String?
    var locator: ReadingLocator?
    var point: MapPoint?

    func toBookItem() -> BookItem {
        BookItem(
            id: id,
            canonicalId: canonicalId,
            title: title,
            author: author,
            year: year,
            format: BookFormat(rawValue: format.lowercased()) ?? .epub,
            source: .homeServer,
            genre: genre ?? "Library",
            subgenre: subgenre ?? "",
            summary: summary ?? "",
            shelfNames: shelves ?? [],
            bytes: bytes ?? 0,
            isOfflineCached: false,
            hasServerCover: hasCover ?? false,
            notesVersion: notesVersion,
            locator: locator,
            point: point
        )
    }
}

public enum HomeLibraryClient {
    public static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let frac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            if let d = (try? frac.parse(str)) ?? (try? plain.parse(str)) {
                return d
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return dec
    }

    public static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    public static func signIn(
        baseURL: String,
        password: String,
        session: URLSession = .shared
    ) async throws -> String {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/login") else {
            throw HomeLibraryError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pass": password, "name": "Cohort Reader"])
        req.timeoutInterval = 12

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw HomeLibraryError.unauthorized
        }
        guard (200..<300).contains(status) else {
            throw HomeLibraryError.serverError(status)
        }
        struct LoginAck: Decodable { var name: String? }
        let ack = try? JSONDecoder().decode(LoginAck.self, from: data)
        return ack?.name ?? clean
    }

    public static func fetchHome(
        baseURL: String,
        limit: Int = 400,
        session: URLSession = .shared
    ) async throws -> HomeLibraryCatalog {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/home?limit=\(max(1, min(600, limit)))") else { throw HomeLibraryError.invalidURL }
        let (data, resp) = try await session.data(from: url)
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(WireHomeResponse.self, from: data)
        return HomeLibraryCatalog(
            serverName: decoded.serverName ?? "Home Library",
            shelves: decoded.shelves,
            items: decoded.items.map { $0.toBookItem() }
        )
    }

    public static func fetchSpace(
        baseURL: String,
        limit: Int = 400,
        session: URLSession = .shared
    ) async throws -> HomeLibrarySpace {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/space?limit=\(max(1, min(1000, limit)))") else {
            throw HomeLibraryError.invalidURL
        }
        let (data, resp) = try await session.data(from: url)
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(WireSpaceResponse.self, from: data)
        var works: [ManifoldReaderWork] = []
        var slugByWorkId: [String: String] = [:]
        works.reserveCapacity(decoded.items.count)
        for raw in decoded.items {
            let wid = (raw.canonicalId?.isEmpty == false) ? raw.canonicalId! : raw.slug
            slugByWorkId[wid] = raw.slug
            let nbs: [NeighbourScore] = (raw.neighbours ?? []).compactMap { nb in
                let targetId = (nb.workId?.isEmpty == false) ? nb.workId! : (nb.slug ?? "")
                guard !targetId.isEmpty else { return nil }
                return NeighbourScore(workId: targetId, sim: nb.sim)
            }
            let fmt = BookFormat(rawValue: (raw.format ?? "").lowercased()) ?? .epub
            works.append(
                ManifoldReaderWork(
                    workId: wid,
                    title: raw.title,
                    creator: raw.creator ?? "Unknown",
                    year: raw.year ?? 2026,
                    kind: raw.kind ?? "library",
                    subject: raw.shelves?.first,
                    format: fmt,
                    summary: raw.summary ?? "",
                    shard: "home",
                    x: raw.x ?? 0,
                    y: raw.y ?? 0,
                    vec32: raw.vec32 ?? [],
                    neighbours: nbs,
                    resonances: []
                )
            )
        }
        let lenses: [ReaderLens] = (decoded.lenses ?? []).map { raw in
            ReaderLens(
                id: raw.id,
                name: raw.name,
                summary: raw.summary ?? "",
                issuerHandle: raw.issuerHandle ?? "home.library",
                anchors: raw.anchors,
                transitions: raw.transitions ?? []
            )
        }
        return HomeLibrarySpace(
            model: decoded.model ?? "library",
            count: decoded.count ?? works.count,
            works: works,
            lenses: lenses,
            slugByWorkId: slugByWorkId
        )
    }

    public static func search(
        baseURL: String,
        query: String,
        limit: Int = 40,
        session: URLSession = .shared
    ) async throws -> [BookItem] {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        var comps = URLComponents(string: "\(clean)/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps?.url else { throw HomeLibraryError.invalidURL }
        let (data, resp) = try await session.data(from: url)
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(WireSearchResponse.self, from: data)
        return decoded.items.map { $0.toBookItem() }
    }

    /// Downloads a book file, optionally resuming from `existingByteOffset` using HTTP `Range: bytes=N-`.
    public static func downloadBook(
        baseURL: String,
        bookId: String,
        existingPrefix: Data = Data(),
        session: URLSession = .shared
    ) async throws -> Data {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        let encodedId = bookId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookId
        guard let url = URL(string: "\(clean)/api/book/\(encodedId)") else {
            throw HomeLibraryError.invalidURL
        }
        var req = URLRequest(url: url)
        if !existingPrefix.isEmpty {
            req.setValue("bytes=\(existingPrefix.count)-", forHTTPHeaderField: "Range")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw HomeLibraryError.unauthorized }
        if code == 206 && !existingPrefix.isEmpty {
            var merged = existingPrefix
            merged.append(data)
            return merged
        }
        guard (200..<300).contains(code) else {
            throw HomeLibraryError.serverError(code)
        }
        guard !data.isEmpty else { throw HomeLibraryError.emptyPayload }
        return data
    }

    public static func fetchMarginNotes(
        baseURL: String,
        bookId: String,
        session: URLSession = .shared
    ) async throws -> [MarginNote] {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        let encodedId = bookId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookId
        guard let url = URL(string: "\(clean)/api/notes/\(encodedId)") else {
            throw HomeLibraryError.invalidURL
        }
        let (data, resp) = try await session.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return [] }
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(WireNotesResponse.self, from: data)
        return decoded.notes
    }

    public static func coverURL(baseURL: String, bookId: String) -> URL? {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        let encodedId = bookId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookId
        return URL(string: "\(clean)/api/cover/\(encodedId)")
    }

    public static func noteAssetURL(baseURL: String, bookId: String, asset: String) -> URL? {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        let encodedId = bookId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookId
        let safeAsset = (asset as NSString).lastPathComponent
        let encodedAsset = safeAsset.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? safeAsset
        return URL(string: "\(clean)/api/notes/\(encodedId)/\(encodedAsset)")
    }

    public static func fetchBinaryAsset(
        url: URL,
        session: URLSession = .shared
    ) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        try checkHTTP(resp)
        guard !data.isEmpty else { throw HomeLibraryError.emptyPayload }
        return data
    }

    @discardableResult
    public static func pushProgress(
        baseURL: String,
        events: [PendingProgressEvent],
        session: URLSession = .shared
    ) async throws -> Int {
        guard !events.isEmpty else { return 0 }
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/progress") else { throw HomeLibraryError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Payload: Encodable { var events: [PendingProgressEvent] }
        req.httpBody = try makeEncoder().encode(Payload(events: events))
        let (data, resp) = try await session.data(for: req)
        try checkHTTP(resp)
        let ack = try? JSONDecoder().decode(WireProgressResponse.self, from: data)
        return ack?.accepted ?? events.count
    }

    public static func matchWorks(
        baseURL: String,
        works: [(workId: String, title: String, creator: String)],
        session: URLSession = .shared
    ) async throws -> [String: BookItem] {
        guard !works.isEmpty else { return [:] }
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/match") else { throw HomeLibraryError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct WireWorkQuery: Encodable {
            var workId: String
            var title: String
            var creator: String
        }
        struct Payload: Encodable { var works: [WireWorkQuery] }
        let body = Payload(works: works.map { WireWorkQuery(workId: $0.workId, title: $0.title, creator: $0.creator) })
        req.httpBody = try makeEncoder().encode(body)
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(WireMatchResponse.self, from: data)
        var out: [String: BookItem] = [:]
        out.reserveCapacity(decoded.matches.count)
        for (wid, wire) in decoded.matches {
            out[wid] = wire.toBookItem()
        }
        return out
    }

    public static func syncHighlights(
        baseURL: String,
        highlights: [ReadingHighlight],
        deletedIds: [String],
        session: URLSession = .shared
    ) async throws -> (highlights: [ReadingHighlight], deletedIds: [String]) {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/highlights") else { throw HomeLibraryError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Payload: Encodable {
            var highlights: [ReadingHighlight]
            var deletedIds: [String]
        }
        struct Response: Decodable {
            var highlights: [ReadingHighlight]
            var deletedIds: [String]
        }
        req.httpBody = try makeEncoder().encode(Payload(highlights: highlights, deletedIds: deletedIds))
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(Response.self, from: data)
        return (decoded.highlights, decoded.deletedIds)
    }

    public static func syncSignaturesJSON(
        baseURL: String,
        payload: Data,
        session: URLSession = .shared
    ) async throws -> Data {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/signatures") else { throw HomeLibraryError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        try checkHTTP(resp)
        return data
    }

    public static func uploadToInbox(
        baseURL: String,
        data fileData: Data,
        filename: String,
        title: String,
        author: String,
        canonicalId: String? = nil,
        session: URLSession = .shared
    ) async throws -> BookItem {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/inbox") else { throw HomeLibraryError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let isEPUB = filename.lowercased().hasSuffix(".epub")
        req.setValue(isEPUB ? "application/epub+zip" : "application/pdf", forHTTPHeaderField: "Content-Type")
        func encHeader(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        req.setValue(encHeader(filename), forHTTPHeaderField: "X-Filename")
        req.setValue(encHeader(title), forHTTPHeaderField: "X-Title")
        req.setValue(encHeader(author), forHTTPHeaderField: "X-Author")
        if let canonicalId, !canonicalId.isEmpty {
            req.setValue(encHeader(canonicalId), forHTTPHeaderField: "X-Canonical-Id")
        }
        req.httpBody = fileData
        req.timeoutInterval = 60
        let (respData, resp) = try await session.data(for: req)
        try checkHTTP(resp)
        struct InboxResp: Decodable { var item: WireBookItem }
        let decoded = try makeDecoder().decode(InboxResp.self, from: respData)
        return decoded.item.toBookItem()
    }

    private static func checkHTTP(_ resp: URLResponse) throws {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw HomeLibraryError.unauthorized
        }
        guard (200..<300).contains(status) else {
            throw HomeLibraryError.serverError(status)
        }
    }
}
