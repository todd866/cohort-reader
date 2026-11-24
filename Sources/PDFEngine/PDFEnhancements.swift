import CoreGraphics
import Foundation
import PDFKit
import ReaderModel
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum PDFPaperAppearance: String, CaseIterable, Codable, Sendable {
    case auto = "Auto"
    case original = "Original"
    case sepia = "Sepia"
    case night = "Night"

    public var label: String { rawValue }

    public var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .original: return "doc.plaintext"
        case .sepia: return "doc.richtext"
        case .night: return "moon.stars"
        }
    }
}

public struct PDFCropInsets: Sendable, Hashable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

public enum PDFCropAnalyzer {
    /// Computes a tight bounding box around non-white ink on `page`, returning `nil` if the page
    /// appears blank or already uses nearly the full page width/height.
    public static func computeInkCropRect(
        for page: PDFPage,
        paddingPoints: CGFloat = 12,
        sampleDPI: CGFloat = 72
    ) -> CGRect? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 12, media.height > 12 else { return nil }

        let scale = min(sampleDPI / 72.0, 560.0 / max(media.width, media.height))
        guard scale > 0 else { return nil }
        let pxW = max(16, Int((media.width * scale).rounded()))
        let pxH = max(16, Int((media.height * scale).rounded()))

        var pixels = [UInt8](repeating: 255, count: pxW * pxH)
        let ok: Bool = pixels.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: pxW,
                      height: pxH,
                      bitsPerComponent: 8,
                      bytesPerRow: pxW,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            ctx.setFillColor(gray: 1.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -media.minX, y: -media.minY)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            return true
        }
        guard ok else { return nil }

        var minCol = pxW
        var maxCol = -1
        var minRow = pxH
        var maxRow = -1

        for row in 0..<pxH {
            let rowStart = row * pxW
            for col in 0..<pxW where pixels[rowStart + col] < 242 {
                if col < minCol { minCol = col }
                if col > maxCol { maxCol = col }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }

        guard maxCol >= minCol, maxRow >= minRow else { return nil }

        let rawMinX = media.minX + CGFloat(minCol) / scale
        let rawMaxX = media.minX + CGFloat(maxCol + 1) / scale
        let rawMaxY = media.minY + CGFloat(pxH - minRow) / scale
        let rawMinY = media.minY + CGFloat(pxH - 1 - maxRow) / scale

        let minX = max(media.minX, rawMinX - paddingPoints)
        let maxX = min(media.maxX, rawMaxX + paddingPoints)
        let minY = max(media.minY, rawMinY - paddingPoints)
        let maxY = min(media.maxY, rawMaxY + paddingPoints)

        let crop = CGRect(x: minX, y: minY, width: max(36, maxX - minX), height: max(36, maxY - minY))
        if crop.width > media.width * 0.94 && crop.height > media.height * 0.94 {
            return nil
        }
        return crop
    }

    /// Computes conservative normalized margin insets across up to `maxSamplePages` interior pages
    /// so headers, footnotes, and wide figures are never clipped.
    public static func computeDocumentCropInsets(
        for document: PDFDocument,
        maxSamplePages: Int = 8
    ) -> PDFCropInsets? {
        let count = document.pageCount
        guard count > 0 else { return nil }

        let indices: [Int]
        if count == 1 {
            indices = [0]
        } else {
            let upper = min(count, 1 + maxSamplePages)
            indices = Array(1..<upper)
        }

        var minLeft: CGFloat = 0.32
        var minRight: CGFloat = 0.32
        var minTop: CGFloat = 0.32
        var minBottom: CGFloat = 0.32
        var matchedAny = false

        for idx in indices {
            guard let page = document.page(at: idx),
                  let ink = computeInkCropRect(for: page) else {
                continue
            }
            let media = page.bounds(for: .mediaBox)
            guard media.width > 12, media.height > 12 else { continue }
            matchedAny = true

            let l = max(0, (ink.minX - media.minX) / media.width)
            let r = max(0, (media.maxX - ink.maxX) / media.width)
            let b = max(0, (ink.minY - media.minY) / media.height)
            let t = max(0, (media.maxY - ink.maxY) / media.height)

            minLeft = min(minLeft, l)
            minRight = min(minRight, r)
            minBottom = min(minBottom, b)
            minTop = min(minTop, t)
        }

        guard matchedAny else { return nil }
        let clamped = PDFCropInsets(
            left: min(max(minLeft, 0), 0.32),
            right: min(max(minRight, 0), 0.32),
            top: min(max(minTop, 0), 0.32),
            bottom: min(max(minBottom, 0), 0.32)
        )
        let maxInset = max(max(clamped.left, clamped.right), max(clamped.top, clamped.bottom))
        guard maxInset >= 0.025 else { return nil }
        return clamped
    }

    public static func applyCrop(_ insets: PDFCropInsets?, to document: PDFDocument) {
        for idx in 0..<document.pageCount {
            guard let page = document.page(at: idx) else { continue }
            let media = page.bounds(for: .mediaBox)
            guard let insets else {
                page.setBounds(media, for: .cropBox)
                continue
            }
            let x = media.minX + insets.left * media.width
            let y = media.minY + insets.bottom * media.height
            let w = max(36, media.width * (1.0 - insets.left - insets.right))
            let h = max(36, media.height * (1.0 - insets.top - insets.bottom))
            let crop = CGRect(x: x, y: y, width: min(w, media.maxX - x), height: min(h, media.maxY - y))
            page.setBounds(crop, for: .cropBox)
        }
    }
}

public enum PDFColumnDetector {
    /// Detects two-column academic layout on `page` by analyzing line selection bounding boxes
    /// relative to the page midpoint.
    public static func detectColumns(on page: PDFPage) -> [CGRect] {
        let box = page.bounds(for: .cropBox)
        guard box.width > 100, box.height > 100 else { return [] }
        guard let lines = page.selection(for: box)?.selectionsByLine(), !lines.isEmpty else {
            return []
        }

        let midX = box.midX
        let tol = box.width * 0.03
        var leftRect: CGRect?
        var rightRect: CGRect?
        var leftCount = 0
        var rightCount = 0
        var crossingCount = 0

        for line in lines {
            let b = line.bounds(for: page)
            guard b.width > box.width * 0.08, b.height > 2 else { continue }
            if b.maxX <= midX + tol && b.width < box.width * 0.56 {
                leftCount += 1
                leftRect = leftRect.map { $0.union(b) } ?? b
            } else if b.minX >= midX - tol && b.width < box.width * 0.56 {
                rightCount += 1
                rightRect = rightRect.map { $0.union(b) } ?? b
            } else if b.minX < midX - tol && b.maxX > midX + tol && b.width > box.width * 0.58 {
                crossingCount += 1
            }
        }

        guard leftCount >= 5,
              rightCount >= 5,
              leftCount + rightCount > crossingCount * 2,
              let l = leftRect,
              let r = rightRect else {
            return []
        }

        let paddedLeft = l.insetBy(dx: -10, dy: -12).intersection(box)
        let paddedRight = r.insetBy(dx: -10, dy: -12).intersection(box)
        guard !paddedLeft.isNull, !paddedRight.isNull else { return [] }
        return [paddedLeft, paddedRight]
    }
}

public struct PDFSearchMatch: Identifiable, Sendable, Hashable {
    public var id: String
    public var pageIndex: Int
    public var snippet: String
    public var matchText: String

    public init(id: String, pageIndex: Int, snippet: String, matchText: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.snippet = snippet
        self.matchText = matchText
    }
}

public enum PDFSearch {
    public static func search(url: URL, query: String, limit: Int = 40) -> [PDFSearchMatch] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return search(document: doc, query: query, limit: limit)
    }

    public static func search(document: PDFDocument, query: String, limit: Int = 40) -> [PDFSearchMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let selections = document.findString(q, withOptions: .caseInsensitive)
        var out: [PDFSearchMatch] = []
        out.reserveCapacity(min(selections.count, limit))

        for (idx, sel) in selections.prefix(limit).enumerated() {
            guard let page = sel.pages.first else { continue }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }
            let rawPageText = page.string ?? ""
            let snippet = buildSnippet(in: rawPageText, matching: q) ?? (sel.string ?? q)
            out.append(
                PDFSearchMatch(
                    id: "pdf:\(pageIndex):\(idx)",
                    pageIndex: pageIndex,
                    snippet: snippet,
                    matchText: sel.string ?? q
                )
            )
        }
        return out
    }

    private static func buildSnippet(in text: String, matching query: String) -> String? {
        guard !text.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let start = text.index(range.lowerBound, offsetBy: -36, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 56, limitedBy: text.endIndex) ?? text.endIndex
        let core = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = start > text.startIndex ? "..." : ""
        let suffix = end < text.endIndex ? "..." : ""
        return "\(prefix)\(core)\(suffix)"
    }
}
