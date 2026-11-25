import CoreGraphics
import CryptoKit
import EPUBEngine
import Foundation
import HomeLibraryClient
import ImageIO
import Observation
import PDFEngine
import ReaderModel
import SwiftUI

@Observable
@MainActor
public final class AssetImageCache {
    public static let shared = AssetImageCache()

    private var thumbnails: [String: CGImage] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: Set<String> = []
    private var failedKeys: Set<String> = []
    private let maxMemoryEntries = 260
    private let cacheDir: URL?
    private let legacyCacheDir: URL?

    public nonisolated static func defaultDurableCacheDir() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent("CohortReaderCache", isDirectory: true)
    }

    public init(cacheDir: URL? = nil) {
        if let provided = cacheDir {
            try? FileManager.default.createDirectory(at: provided, withIntermediateDirectories: true)
            self.cacheDir = provided
        } else if let durable = Self.defaultDurableCacheDir() {
            try? FileManager.default.createDirectory(at: durable, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDurable = durable
            try? mutableDurable.setResourceValues(values)
            self.cacheDir = durable
        } else if let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("CohortReaderAssets", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.cacheDir = dir
        } else {
            self.cacheDir = nil
        }
        if let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.legacyCacheDir = base.appendingPathComponent("CohortReaderAssets", isDirectory: true)
        } else {
            self.legacyCacheDir = nil
        }
    }

    public func image(forKey key: String) -> CGImage? {
        thumbnails[key]
    }

    public func hasImage(forBookId bookId: String) -> Bool {
        thumbnails["cover:\(bookId)"] != nil
    }

    public func resetFailures() {
        failedKeys.removeAll()
    }

    public nonisolated static func safeBookCoverFilename(bookId: String) -> String {
        let safeId = bookId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
        return "\(safeId).jpg"
    }

    public nonisolated func hasDiskCover(forBookId bookId: String) -> Bool {
        guard let url = fileURL(forKey: "cover:\(bookId)", maxPixelSize: 320) else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    public func registerLocalCover(data: Data, bookId: String, maxPixelSize: Int = 320) async {
        let key = "cover:\(bookId)"
        guard !data.isEmpty else { return }
        if thumbnails[key] != nil && hasDiskCover(forBookId: bookId) { return }
        let diskURL = fileURL(forKey: key, maxPixelSize: maxPixelSize)
        let result: (image: CGImage, jpeg: Data?)? = await Task.detached(priority: .userInitiated) {
            guard let downsampled = Self.downsampleCGImage(data: data, maxPixelSize: maxPixelSize) else {
                return nil
            }
            return (downsampled, Self.encodeJPEG(cgImage: downsampled))
        }.value
        guard let result else { return }
        failedKeys.remove(key)
        storeInMemory(result.image, forKey: key)
        if let diskURL {
            let toWrite = result.jpeg ?? data
            await Task.detached(priority: .utility) {
                Self.writeDurableData(toWrite, to: diskURL)
            }.value
        }
    }

    @discardableResult
    public func prefetchCover(url: URL, bookId: String, maxPixelSize: Int = 320) async -> Bool {
        let key = "cover:\(bookId)"
        if hasDiskCover(forBookId: bookId) { return true }
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        if let diskURL = fileURL(forKey: key, maxPixelSize: maxPixelSize),
           let legacyURL = legacyFileURL(forKey: key, maxPixelSize: maxPixelSize),
           FileManager.default.isReadableFile(atPath: legacyURL.path),
           let legacyData = try? Data(contentsOf: legacyURL), !legacyData.isEmpty {
            await Task.detached(priority: .utility) {
                Self.writeDurableData(legacyData, to: diskURL)
            }.value
            failedKeys.remove(key)
            return true
        }

        guard let diskURL = fileURL(forKey: key, maxPixelSize: maxPixelSize) else { return false }
        do {
            let rawData = try await HomeLibraryClient.fetchBinaryAsset(url: url)
            let jpeg: Data? = await Task.detached(priority: .utility) {
                guard let downsampled = Self.downsampleCGImage(data: rawData, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                return Self.encodeJPEG(cgImage: downsampled) ?? rawData
            }.value
            guard let jpeg else {
                failedKeys.insert(key)
                return false
            }
            await Task.detached(priority: .utility) {
                Self.writeDurableData(jpeg, to: diskURL)
            }.value
            failedKeys.remove(key)
            return true
        } catch HomeLibraryError.serverError(let code) where code == 404 {
            failedKeys.insert(key)
            return false
        } catch {
            return false
        }
    }

    public func prefetchNoteAsset(url: URL, bookId: String, asset: String, maxPixelSize: Int = 960) async {
        let key = "note:\(bookId):\(asset)"
        guard let diskURL = fileURL(forKey: key, maxPixelSize: maxPixelSize) else { return }
        if FileManager.default.isReadableFile(atPath: diskURL.path) { return }
        guard !inFlight.contains(key), !failedKeys.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let rawData = try await HomeLibraryClient.fetchBinaryAsset(url: url)
            let encoded: Data? = await Task.detached(priority: .utility) {
                guard let downsampled = Self.downsampleCGImage(data: rawData, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                return Self.encodeJPEG(cgImage: downsampled) ?? rawData
            }.value
            if let encoded {
                await Task.detached(priority: .utility) {
                    Self.writeDurableData(encoded, to: diskURL)
                }.value
            }
        } catch HomeLibraryError.serverError(let code) where code == 404 {
            failedKeys.insert(key)
        } catch {
            // Transient network error: retry on next sync
        }
    }

    public func extractLocalCoverIfMissing(bookId: String, fileURL sourceURL: URL, format: BookFormat) async {
        guard !hasDiskCover(forBookId: bookId) else { return }
        let key = "cover:\(bookId)"
        let data: Data? = await Task.detached(priority: .utility) {
            if format == .epub {
                if let doc = try? EPUBParser.parse(url: sourceURL),
                   let coverHref = doc.coverHref,
                   let found = doc.resourceData(forArchivePath: coverHref)?.data ?? doc.resources[coverHref] {
                    return found
                }
                return nil
            } else {
                return PDFInspector.renderFirstPagePNG(url: sourceURL, maxDimension: 360)
            }
        }.value
        guard let data, !data.isEmpty else { return }
        if let diskURL = self.fileURL(forKey: key, maxPixelSize: 320) {
            let result: (image: CGImage, jpeg: Data?)? = await Task.detached(priority: .utility) {
                guard let downsampled = Self.downsampleCGImage(data: data, maxPixelSize: 320) else {
                    return nil
                }
                return (downsampled, Self.encodeJPEG(cgImage: downsampled))
            }.value
            if let result {
                failedKeys.remove(key)
                if thumbnails.count < maxMemoryEntries {
                    storeInMemory(result.image, forKey: key)
                }
                let toWrite = result.jpeg ?? data
                await Task.detached(priority: .utility) {
                    Self.writeDurableData(toWrite, to: diskURL)
                }.value
            }
        }
    }

    public func loadIfNeeded(url: URL?, key: String, maxPixelSize: Int) async {
        guard thumbnails[key] == nil, !inFlight.contains(key), !failedKeys.contains(key) else { return }
        let diskURL = fileURL(forKey: key, maxPixelSize: maxPixelSize)
        let legacyURL = legacyFileURL(forKey: key, maxPixelSize: maxPixelSize)
        if diskURL == nil && legacyURL == nil && url == nil { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        for candURL in [diskURL, legacyURL].compactMap({ $0 }) {
            let diskHit: (image: CGImage, bytes: Data)? = await Task.detached(priority: .userInitiated) {
                guard let diskData = try? Data(contentsOf: candURL),
                      !diskData.isEmpty,
                      let img = Self.downsampleCGImage(data: diskData, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                return (img, diskData)
            }.value
            if let diskHit {
                storeInMemory(diskHit.image, forKey: key)
                if let diskURL, candURL != diskURL {
                    let bytes = diskHit.bytes
                    await Task.detached(priority: .utility) {
                        Self.writeDurableData(bytes, to: diskURL)
                    }.value
                }
                return
            }
        }

        guard let url else { return }
        do {
            let rawData = try await HomeLibraryClient.fetchBinaryAsset(url: url)
            let result: (image: CGImage, jpeg: Data?)? = await Task.detached(priority: .userInitiated) {
                guard let downsampled = Self.downsampleCGImage(data: rawData, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                return (downsampled, Self.encodeJPEG(cgImage: downsampled))
            }.value
            if let result {
                storeInMemory(result.image, forKey: key)
                if let diskURL {
                    let toWrite = result.jpeg ?? rawData
                    await Task.detached(priority: .utility) {
                        Self.writeDurableData(toWrite, to: diskURL)
                    }.value
                }
            } else {
                failedKeys.insert(key)
            }
        } catch HomeLibraryError.serverError(let code) where code == 404 {
            failedKeys.insert(key)
        } catch {
            // Do not permanently block offline/transient failures so covers load as soon as server is back.
        }
    }

    public nonisolated static func downsampleCGImage(data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, !data.isEmpty else { return nil }
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, sourceOpts as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }

    private nonisolated static func encodeJPEG(cgImage: CGImage, quality: Double = 0.82) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private nonisolated static func writeDurableData(_ data: Data, to dest: URL) {
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDest = dest
        try? mutableDest.setResourceValues(values)
    }

    private func storeInMemory(_ cgImage: CGImage, forKey key: String) {
        if thumbnails[key] == nil {
            insertionOrder.append(key)
            while insertionOrder.count > maxMemoryEntries {
                let oldest = insertionOrder.removeFirst()
                thumbnails.removeValue(forKey: oldest)
            }
        }
        thumbnails[key] = cgImage
    }

    private nonisolated func fileURL(forKey key: String, maxPixelSize: Int) -> URL? {
        guard let cacheDir else { return nil }
        if key.hasPrefix("cover:") {
            let bookId = String(key.dropFirst("cover:".count))
            return cacheDir
                .appendingPathComponent("covers", isDirectory: true)
                .appendingPathComponent(Self.safeBookCoverFilename(bookId: bookId))
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir
            .appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent("\(digest)-\(maxPixelSize).jpg")
    }

    private nonisolated func legacyFileURL(forKey key: String, maxPixelSize: Int) -> URL? {
        guard let legacyCacheDir else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return legacyCacheDir.appendingPathComponent("\(digest)-\(maxPixelSize).jpg")
    }
}

/// Renders AI/server cover art when authenticated & cached, cleanly falling back to `TypographicCoverView`.
public struct BookCoverView: View {
    public let book: BookItem
    public let serverURL: String
    public var width: CGFloat? = 52
    public var height: CGFloat? = 72
    public var isSnapshot: Bool = false
    public var reloadToken: Bool = true

    private var cache = AssetImageCache.shared

    public init(
        book: BookItem,
        serverURL: String,
        width: CGFloat? = 52,
        height: CGFloat? = 72,
        isSnapshot: Bool = false,
        reloadToken: Bool = true
    ) {
        self.book = book
        self.serverURL = serverURL
        self.width = width
        self.height = height
        self.isSnapshot = isSnapshot
        self.reloadToken = reloadToken
    }

    private var coverKey: String { "cover:\(book.id)" }

    private var remoteURL: URL? {
        guard !isSnapshot else { return nil }
        if book.source == .homeServer {
            if book.hasServerCover, !serverURL.isEmpty {
                return HomeLibraryClient.coverURL(baseURL: serverURL, bookId: book.id)
            }
            return nil
        }
        if book.hasServerCover, !serverURL.isEmpty {
            return HomeLibraryClient.coverURL(baseURL: serverURL, bookId: book.id)
        }
        if let cid = book.canonicalId, cid.hasPrefix("isbn:") {
            let isbn = String(cid.dropFirst(5))
            if CanonicalIDNormalizer.isValidISBN13(isbn) {
                return URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-M.jpg?default=false")
            }
        }
        return nil
    }

    public var body: some View {
        let mini = (width ?? 110) < 56
        Group {
            if !isSnapshot, let cg = cache.image(forKey: coverKey) {
                GeometryReader { geo in
                    Image(decorative: cg, scale: 1.0)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .modifier(CoverSizingModifier(width: width, height: height))
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: mini ? 3 : 5)
                        Rectangle()
                            .fill(Color.black.opacity(0.18))
                            .frame(width: 1)
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ReaderPalette.hairline, lineWidth: 0.75)
                )
            } else {
                TypographicCoverView(book: book, width: width, height: height)
            }
        }
        .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 2.5)
        .task(id: "\(remoteURL?.absoluteString ?? "")|\(reloadToken)") {
            await cache.loadIfNeeded(url: remoteURL, key: coverKey, maxPixelSize: 320)
        }
    }
}

private struct CoverSizingModifier: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let width, let height {
            content.frame(width: width, height: height)
        } else {
            content
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
    }
}

/// Loads authenticated offline Wikipedia / Natural Earth note images from the Home Library Server.
public struct NoteAssetImageView: View {
    public let serverURL: String
    public let bookId: String
    public let asset: String
    public var isSnapshot: Bool = false

    private var cache = AssetImageCache.shared

    public init(serverURL: String, bookId: String, asset: String, isSnapshot: Bool = false) {
        self.serverURL = serverURL
        self.bookId = bookId
        self.asset = asset
        self.isSnapshot = isSnapshot
    }

    private var assetKey: String { "note:\(bookId):\(asset)" }

    private var remoteURL: URL? {
        guard !serverURL.isEmpty, !asset.isEmpty, !isSnapshot else { return nil }
        return HomeLibraryClient.noteAssetURL(baseURL: serverURL, bookId: bookId, asset: asset)
    }

    public var body: some View {
        Group {
            if !isSnapshot, let cg = cache.image(forKey: assetKey) {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(ReaderPalette.hairline, lineWidth: 1)
                    )
            }
        }
        .task(id: remoteURL?.absoluteString ?? "") {
            await cache.loadIfNeeded(url: remoteURL, key: assetKey, maxPixelSize: 960)
        }
    }
}
