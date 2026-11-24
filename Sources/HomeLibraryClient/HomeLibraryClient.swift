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

private struct WireHomeResponse: Decodable {
    var serverName: String?
    var shelves: [LibraryShelf]
    var items: [WireBookItem]
}

private struct WireSearchResponse: Decodable {
    var items: [WireBookItem]
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
    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private static func makeEncoder() -> JSONEncoder {
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
        session: URLSession = .shared
    ) async throws -> HomeLibraryCatalog {
        let clean = ReaderKeychain.normalizedServer(baseURL)
        guard let url = URL(string: "\(clean)/api/home") else { throw HomeLibraryError.invalidURL }
        let (data, resp) = try await session.data(from: url)
        try checkHTTP(resp)
        let decoded = try makeDecoder().decode(WireHomeResponse.self, from: data)
        return HomeLibraryCatalog(
            serverName: decoded.serverName ?? "Home Library",
            shelves: decoded.shelves,
            items: decoded.items.map { $0.toBookItem() }
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
