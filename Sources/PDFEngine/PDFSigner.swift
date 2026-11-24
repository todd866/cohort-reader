import CoreGraphics
import CoreText
import Foundation

public struct SignaturePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

public struct CodableRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum SignatureInkColor: String, CaseIterable, Codable, Sendable {
    case navy = "Blue Ink"
    case black = "Black"

    public var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .navy: return (0.08, 0.20, 0.44)
        case .black: return (0.07, 0.08, 0.10)
        }
    }
}

public struct SavedSignature: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var strokes: [[SignaturePoint]]
    public var typedText: String?
    public var inkColor: SignatureInkColor
    public var aspectRatio: Double
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        label: String,
        strokes: [[SignaturePoint]] = [],
        typedText: String? = nil,
        inkColor: SignatureInkColor = .navy,
        aspectRatio: Double = 2.6,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.strokes = strokes
        self.typedText = typedText
        self.inkColor = inkColor
        self.aspectRatio = max(0.5, aspectRatio)
        self.createdAt = createdAt
    }
}

public enum PDFStampKind: Codable, Sendable, Hashable {
    case signature(SavedSignature)
    case text(String, SignatureInkColor)

    public var inkColor: SignatureInkColor {
        switch self {
        case .signature(let sig): return sig.inkColor
        case .text(_, let color): return color
        }
    }

    public var displayTitle: String {
        switch self {
        case .signature(let sig): return sig.label
        case .text(let s, _): return s
        }
    }
}

public struct PDFStampPlacement: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var pageIndex: Int
    /// Visual top-left normalized bounds (0...1 across the visible page box).
    public var normalizedRect: CodableRect
    public var kind: PDFStampKind

    public init(
        id: String = UUID().uuidString,
        pageIndex: Int,
        normalizedRect: CodableRect,
        kind: PDFStampKind
    ) {
        self.id = id
        self.pageIndex = max(0, pageIndex)
        self.normalizedRect = normalizedRect
        self.kind = kind
    }
}

public enum PDFSignerError: Error, Sendable, LocalizedError {
    case unreadableSource
    case contextCreationFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableSource:
            return "Could not open source PDF document for signing."
        case .contextCreationFailed:
            return "Could not allocate CoreGraphics PDF output context."
        }
    }
}

public enum SignatureStore {
    public static func defaultURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("CohortReader", isDirectory: true)
            .appendingPathComponent("signatures.json")
    }

    public static func load(from url: URL? = defaultURL()) -> [SavedSignature] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([SavedSignature].self, from: data)) ?? []
    }

    public static func save(_ signatures: [SavedSignature], to url: URL? = defaultURL()) throws {
        guard let url else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(signatures)
        try data.write(to: url, options: .atomic)
    }
}

public enum PDFSigner {
    public static func flattenStamps(
        _ stamps: [PDFStampPlacement],
        onto sourceURL: URL,
        outputURL: URL
    ) throws {
        let data = try Data(contentsOf: sourceURL)
        let out = try flattenStamps(stamps, onto: data)
        try out.write(to: outputURL, options: .atomic)
    }

    /// Renders every original page cleanly in vector form into a new PDF with all stamps flattened,
    /// preserving original text layers, fonts, and selectability.
    public static func flattenStamps(
        _ stamps: [PDFStampPlacement],
        onto sourceData: Data
    ) throws -> Data {
        guard let provider = CGDataProvider(data: sourceData as CFData),
              let srcDoc = CGPDFDocument(provider),
              srcDoc.numberOfPages > 0 else {
            throw PDFSignerError.unreadableSource
        }

        let outData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFSignerError.contextCreationFailed
        }

        let stampsByPage = Dictionary(grouping: stamps, by: \.pageIndex)

        for oneBasedPage in 1...srcDoc.numberOfPages {
            guard let page = srcDoc.page(at: oneBasedPage) else { continue }
            let zeroBased = oneBasedPage - 1

            let crop = page.getBoxRect(.cropBox)
            let rot = ((page.rotationAngle % 360) + 360) % 360
            let visualSize = (rot == 90 || rot == 270)
                ? CGSize(width: crop.height, height: crop.width)
                : crop.size
            var visualRect = CGRect(origin: .zero, size: visualSize)

            let mediaBoxData = Data(bytes: &visualRect, count: MemoryLayout<CGRect>.size) as CFData
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: mediaBoxData,
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)

            // Draw original page upright into visualRect using PDFPage's rotation-aware transform
            ctx.saveGState()
            let xform = page.getDrawingTransform(.cropBox, rect: visualRect, rotate: 0, preserveAspectRatio: true)
            ctx.concatenate(xform)
            ctx.drawPDFPage(page)
            ctx.restoreGState()

            if let pageStamps = stampsByPage[zeroBased] {
                for stamp in pageStamps {
                    let nr = stamp.normalizedRect
                    let w = max(8, CGFloat(nr.width) * visualSize.width)
                    let h = max(8, CGFloat(nr.height) * visualSize.height)
                    let x = CGFloat(nr.x) * visualSize.width
                    let y = visualSize.height - (CGFloat(nr.y) + CGFloat(nr.height)) * visualSize.height
                    let targetRect = CGRect(x: x, y: y, width: w, height: h)
                    drawStamp(stamp.kind, in: targetRect, on: ctx)
                }
            }

            ctx.endPDFPage()
        }

        ctx.closePDF()
        return outData as Data
    }

    private static func drawStamp(_ kind: PDFStampKind, in rect: CGRect, on ctx: CGContext) {
        let c = kind.inkColor.rgb
        let ink = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [c.r, c.g, c.b, 1.0])!

        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch kind {
        case .signature(let sig):
            if !sig.strokes.isEmpty {
                ctx.setStrokeColor(ink)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setLineWidth(max(1.4, min(4.2, rect.height * 0.045)))

                for stroke in sig.strokes where !stroke.isEmpty {
                    let pts = stroke.map { p in
                        CGPoint(
                            x: rect.minX + CGFloat(p.x) * rect.width,
                            y: rect.minY + (1.0 - CGFloat(p.y)) * rect.height
                        )
                    }
                    if pts.count == 1 {
                        let r = ctx.convertToUserSpace(CGSize(width: 1.5, height: 1.5)).width
                        ctx.setFillColor(ink)
                        ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
                        continue
                    }
                    ctx.beginPath()
                    ctx.move(to: pts[0])
                    if pts.count == 2 {
                        ctx.addLine(to: pts[1])
                    } else {
                        for i in 1..<pts.count {
                            let prev = pts[i - 1]
                            let curr = pts[i]
                            let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
                            ctx.addQuadCurve(to: mid, control: prev)
                        }
                        if let last = pts.last {
                            ctx.addLine(to: last)
                        }
                    }
                    ctx.strokePath()
                }
            } else if let typed = sig.typedText, !typed.isEmpty {
                drawCoreText(typed, in: rect, italic: true, color: ink, on: ctx)
            }
        case .text(let text, _):
            drawCoreText(text, in: rect, italic: false, color: ink, on: ctx)
        }
    }

    private static func drawCoreText(
        _ string: String,
        in rect: CGRect,
        italic: Bool,
        color: CGColor,
        on ctx: CGContext
    ) {
        let baseFontName: CFString = italic ? "Georgia-Italic" as CFString : "HelveticaNeue" as CFString
        var fontSize = max(10.0, rect.height * 0.62)
        var font = CTFontCreateWithName(baseFontName, fontSize, nil)

        func makeLine(_ f: CTFont) -> CTLine {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let attrStr = NSAttributedString(string: string, attributes: attrs)
            return CTLineCreateWithAttributedString(attrStr)
        }

        var line = makeLine(font)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > rect.width * 0.94, width > 1 {
            let shrink = (rect.width * 0.94) / width
            fontSize = max(8.0, fontSize * shrink)
            font = CTFontCreateWithName(baseFontName, fontSize, nil)
            line = makeLine(font)
        }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let finalWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let textHeight = ascent + descent
        let drawX = rect.minX + max(2, (rect.width - finalWidth) * 0.5)
        let drawY = rect.minY + (rect.height - textHeight) * 0.5 + descent
        ctx.textPosition = CGPoint(x: drawX, y: drawY)
        CTLineDraw(line, ctx)
    }
}
