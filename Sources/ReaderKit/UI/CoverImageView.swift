import CoreGraphics
import CryptoKit
import Foundation
import HomeLibraryClient
import ImageIO
import Observation
import ReaderModel
import SwiftUI

@Observable
@MainActor
public final class AssetImageCache {
    public static let shared = AssetImageCache()

    private var thumbnails: [String: CGImage] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: Set<String> = []
    private let maxMemoryEntries = 180
    private let cacheDir: URL?

    public init() {
        if let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("CohortReaderAssets", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.cacheDir = dir
        } else {
            self.cacheDir = nil
        }
    }

    public func image(forKey key: String) -> CGImage? {
        thumbnails[key]
    }

    public func loadIfNeeded(url: URL?, key: String, maxPixelSize: Int) async {
        guard thumbnails[key] == nil, !inFlight.contains(key) else { return }
        let diskURL = fileURL(forKey: key, maxPixelSize: maxPixelSize)
        if diskURL == nil && url == nil { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        if let diskURL {
            let diskHit: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let diskData = try? Data(contentsOf: diskURL), !diskData.isEmpty else {
                    return nil
                }
                return Self.downsampleCGImage(data: diskData, maxPixelSize: maxPixelSize)
            }.value
            if let diskHit {
                storeInMemory(diskHit, forKey: key)
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
                        try? toWrite.write(to: diskURL, options: .atomic)
                    }.value
                }
            }
        } catch {
            // Leave fallback cover cleanly in place when offline or unauthenticated.
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

    private func fileURL(forKey key: String, maxPixelSize: Int) -> URL? {
        guard let cacheDir else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(digest)-\(maxPixelSize).jpg")
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
        guard book.hasServerCover, !serverURL.isEmpty, !isSnapshot else { return nil }
        return HomeLibraryClient.coverURL(baseURL: serverURL, bookId: book.id)
    }

    public var body: some View {
        Group {
            if !isSnapshot, let cg = cache.image(forKey: coverKey) {
                GeometryReader { geo in
                    Image(decorative: cg, scale: 1.0)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .modifier(CoverSizingModifier(width: width, height: height))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ReaderPalette.hairline, lineWidth: 0.75)
                )
            } else {
                TypographicCoverView(book: book, width: width, height: height)
            }
        }
        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
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
