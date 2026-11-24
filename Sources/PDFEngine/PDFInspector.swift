import Foundation
import PDFKit
import ReaderModel
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct PDFOutlineEntry: Identifiable, Sendable, Hashable {
    public var id: String { "\(pageIndex):\(title)" }
    public var title: String
    public var pageIndex: Int

    public init(title: String, pageIndex: Int) {
        self.title = title
        self.pageIndex = pageIndex
    }
}

public struct PDFMetadataSummary: Sendable, Hashable {
    public var title: String
    public var author: String
    public var pageCount: Int
    public var canonicalId: String?
    public var outline: [PDFOutlineEntry]
    public var frontMatterText: String

    public init(
        title: String,
        author: String,
        pageCount: Int,
        canonicalId: String?,
        outline: [PDFOutlineEntry],
        frontMatterText: String
    ) {
        self.title = title
        self.author = author
        self.pageCount = pageCount
        self.canonicalId = canonicalId
        self.outline = outline
        self.frontMatterText = frontMatterText
    }
}

public enum PDFInspector {
    public static func inspect(url: URL) -> PDFMetadataSummary? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return inspect(document: doc, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    public static func inspect(data: Data, fallbackTitle: String = "Untitled PDF") -> PDFMetadataSummary? {
        guard let doc = PDFDocument(data: data) else { return nil }
        return inspect(document: doc, fallbackTitle: fallbackTitle)
    }

    public static func inspect(document doc: PDFDocument, fallbackTitle: String) -> PDFMetadataSummary {
        let attrs = doc.documentAttributes ?? [:]
        let rawTitle = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawAuthor = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let pageCount = doc.pageCount
        var frontParts: [String] = []
        for idx in 0..<min(pageCount, 3) {
            if let text = doc.page(at: idx)?.string, !text.isEmpty {
                frontParts.append(text)
            }
        }
        let frontMatter = frontParts.joined(separator: "\n")
        let canonical = CanonicalIDNormalizer.extractCanonicalId(from: frontMatter)

        var outline: [PDFOutlineEntry] = []
        if let root = doc.outlineRoot {
            collectOutline(from: root, in: doc, into: &outline, limit: 60)
        }

        let title: String
        if !rawTitle.isEmpty {
            title = rawTitle
        } else if let firstLine = frontMatter.split(separator: "\n").map(String.init).first(where: { $0.trimmingCharacters(in: .whitespaces).count >= 4 }) {
            title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(120))
        } else {
            title = fallbackTitle
        }

        return PDFMetadataSummary(
            title: title,
            author: rawAuthor.isEmpty ? "Unknown" : rawAuthor,
            pageCount: pageCount,
            canonicalId: canonical,
            outline: outline,
            frontMatterText: String(frontMatter.prefix(4000))
        )
    }

    public static func renderFirstPagePNG(url: URL, maxDimension: CGFloat = 480) -> Data? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxDimension / bounds.width, maxDimension / bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let img = page.thumbnail(of: size, for: .mediaBox)
        #if canImport(UIKit)
        return img.pngData()
        #elseif canImport(AppKit)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    public static func fraction(forPage pageIndex: Int, pageCount: Int) -> Double {
        guard pageCount > 1 else { return 0 }
        return min(max(Double(pageIndex) / Double(pageCount - 1), 0), 1)
    }

    public static func pageIndex(forFraction fraction: Double, pageCount: Int) -> Int {
        guard pageCount > 1 else { return 0 }
        return min(max(Int((fraction * Double(pageCount - 1)).rounded()), 0), pageCount - 1)
    }

    private static func collectOutline(
        from node: PDFOutline,
        in doc: PDFDocument,
        into out: inout [PDFOutlineEntry],
        limit: Int
    ) {
        if out.count >= limit { return }
        for i in 0..<node.numberOfChildren {
            guard out.count < limit, let child = node.child(at: i) else { break }
            if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty,
               let destPage = child.destination?.page {
                let idx = doc.index(for: destPage)
                if idx != NSNotFound {
                    out.append(PDFOutlineEntry(title: label, pageIndex: idx))
                }
            }
            collectOutline(from: child, in: doc, into: &out, limit: limit)
        }
    }
}
