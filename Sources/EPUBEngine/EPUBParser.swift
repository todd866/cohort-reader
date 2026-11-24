import Foundation
import ReaderModel

public enum EPUBError: Error, Sendable, CustomStringConvertible {
    case missingContainer
    case missingOPF(String)
    case emptySpine
    case invalidResourcePath(String)

    public var description: String {
        switch self {
        case .missingContainer: return "EPUB is missing META-INF/container.xml"
        case .missingOPF(let p): return "EPUB OPF package not found at \(p)"
        case .emptySpine: return "EPUB spine contains no readable chapters"
        case .invalidResourcePath(let p): return "Resource not found in EPUB: \(p)"
        }
    }
}

public struct EPUBTocEntry: Identifiable, Sendable, Hashable {
    public var id: String { "\(spineIndex):\(title)" }
    public var title: String
    public var href: String
    public var spineIndex: Int

    public init(title: String, href: String, spineIndex: Int) {
        self.title = title
        self.href = href
        self.spineIndex = spineIndex
    }
}

public struct EPUBChapter: Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var href: String
    public var title: String
    public var xhtmlData: Data
    public var plainText: String
    public var wordCount: Int
}

public struct EPUBDocument: Sendable {
    public var title: String
    public var author: String
    public var canonicalId: String?
    public var language: String
    public var opfDir: String
    public var coverHref: String?
    public var spineHrefs: [String]
    public var toc: [EPUBTocEntry]
    public var resources: [String: Data]

    public func chapter(at index: Int) -> EPUBChapter? {
        guard index >= 0, index < spineHrefs.count else { return nil }
        let href = spineHrefs[index]
        guard let data = resources[href] else { return nil }
        let tocTitle = toc.first(where: { $0.spineIndex == index })?.title
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let plain = EPUBHTMLTextExtractor.extractPlainText(fromHTML: html)
        let title = tocTitle ?? EPUBHTMLTextExtractor.extractHeading(fromHTML: html) ?? "Chapter \(index + 1)"
        let words = plain.split { $0.isWhitespace }.count
        return EPUBChapter(index: index, href: href, title: title, xhtmlData: data, plainText: plain, wordCount: words)
    }

    public func resourceData(forArchivePath path: String) -> (data: Data, mimeType: String)? {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let clean = normalized.components(separatedBy: "#").first ?? normalized
        guard let data = resources[clean] else { return nil }
        return (data, EPUBMimeType.forPath(clean))
    }
}

public enum EPUBMimeType {
    public static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "xhtml", "xht": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }
}

public enum EPUBParser {
    public static func parse(url: URL) throws -> EPUBDocument {
        let archive = try ZIPArchive.read(from: url)
        return try parse(resources: archive)
    }

    public static func parse(data: Data) throws -> EPUBDocument {
        let archive = try ZIPArchive.read(from: data)
        return try parse(resources: archive)
    }

    public static func parse(resources: [String: Data]) throws -> EPUBDocument {
        guard let containerData = resources["META-INF/container.xml"] else {
            throw EPUBError.missingContainer
        }
        let containerDelegate = ContainerXMLDelegate()
        let cParser = XMLParser(data: containerData)
        cParser.delegate = containerDelegate
        cParser.parse()
        guard let opfPath = containerDelegate.fullPath, let opfData = resources[opfPath] else {
            throw EPUBError.missingOPF(containerDelegate.fullPath ?? "unknown")
        }

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let opfDelegate = OPFXMLDelegate()
        let oParser = XMLParser(data: opfData)
        oParser.delegate = opfDelegate
        oParser.parse()

        var spineHrefs: [String] = []
        for idref in opfDelegate.spineIdRefs {
            if let item = opfDelegate.manifestById[idref] {
                let resolved = resolveRelative(baseDir: opfDir, href: item.href)
                if resources[resolved] != nil {
                    spineHrefs.append(resolved)
                }
            }
        }
        guard !spineHrefs.isEmpty else {
            throw EPUBError.emptySpine
        }

        var coverHref: String?
        if let coverId = opfDelegate.coverMetaId, let item = opfDelegate.manifestById[coverId] {
            coverHref = resolveRelative(baseDir: opfDir, href: item.href)
        } else if let propCover = opfDelegate.manifestById.values.first(where: { $0.properties.contains("cover-image") }) {
            coverHref = resolveRelative(baseDir: opfDir, href: propCover.href)
        }

        var tocEntries: [EPUBTocEntry] = []
        if let navItem = opfDelegate.manifestById.values.first(where: { $0.properties.contains("nav") }) {
            let navPath = resolveRelative(baseDir: opfDir, href: navItem.href)
            if let navData = resources[navPath] {
                let navDir = (navPath as NSString).deletingLastPathComponent
                let navDelegate = NAVXMLDelegate()
                let nParser = XMLParser(data: navData)
                nParser.delegate = navDelegate
                nParser.parse()
                for entry in navDelegate.entries {
                    let full = resolveRelative(baseDir: navDir, href: stripFragment(entry.href))
                    if let idx = spineHrefs.firstIndex(of: full) {
                        tocEntries.append(EPUBTocEntry(title: entry.title, href: full, spineIndex: idx))
                    }
                }
            }
        }
        if tocEntries.isEmpty,
           let ncxId = opfDelegate.ncxId ?? opfDelegate.manifestById.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.id,
           let ncxItem = opfDelegate.manifestById[ncxId] {
            let ncxPath = resolveRelative(baseDir: opfDir, href: ncxItem.href)
            if let ncxData = resources[ncxPath] {
                let ncxDir = (ncxPath as NSString).deletingLastPathComponent
                let ncxDelegate = NCXXMLDelegate()
                let xParser = XMLParser(data: ncxData)
                xParser.delegate = ncxDelegate
                xParser.parse()
                for entry in ncxDelegate.entries {
                    let full = resolveRelative(baseDir: ncxDir, href: stripFragment(entry.href))
                    if let idx = spineHrefs.firstIndex(of: full) {
                        tocEntries.append(EPUBTocEntry(title: entry.title, href: full, spineIndex: idx))
                    }
                }
            }
        }

        if tocEntries.isEmpty {
            for (idx, href) in spineHrefs.enumerated() {
                let html = resources[href].flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let title = EPUBHTMLTextExtractor.extractHeading(fromHTML: html) ?? "Section \(idx + 1)"
                tocEntries.append(EPUBTocEntry(title: title, href: href, spineIndex: idx))
            }
        }

        var canonicalId: String?
        for ident in opfDelegate.identifiers {
            if let found = CanonicalIDNormalizer.extractCanonicalId(from: ident) {
                canonicalId = found
                break
            }
        }

        return EPUBDocument(
            title: opfDelegate.title.isEmpty ? "Untitled" : opfDelegate.title,
            author: opfDelegate.creators.isEmpty ? "Unknown" : opfDelegate.creators.joined(separator: "; "),
            canonicalId: canonicalId,
            language: opfDelegate.language.isEmpty ? "en" : opfDelegate.language,
            opfDir: opfDir,
            coverHref: coverHref,
            spineHrefs: spineHrefs,
            toc: tocEntries,
            resources: resources
        )
    }

    public static func resolveRelative(baseDir: String, href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let combined = baseDir.isEmpty ? decoded : "\(baseDir)/\(decoded)"
        var stack: [String] = []
        for comp in combined.split(separator: "/") {
            if comp == "." { continue }
            if comp == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(comp))
            }
        }
        return stack.joined(separator: "/")
    }

    private static func stripFragment(_ href: String) -> String {
        href.components(separatedBy: "#").first ?? href
    }
}

public enum SampleShowcaseEPUB {
    /// Generates a real in-memory/on-disk EPUB3 archive for the public-domain Frankenstein excerpt.
    public static func buildFrankensteinSampleData() throws -> Data {
        let mimetype = Data("application/epub+zip".utf8)
        let container = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8)

        let nav = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Table of Contents</title></head>
        <body>
          <nav epub:type="toc">
            <ol>
              <li><a href="ch1.xhtml">Letter I — St. Petersburgh</a></li>
              <li><a href="ch2.xhtml">Chapter IV — Natural Philosophy at Ingolstadt</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """.utf8)

        let opf = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:gutenberg:84</dc:identifier>
            <dc:title>Frankenstein; or, The Modern Prometheus</dc:title>
            <dc:creator>Mary Wollstonecraft Shelley</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.utf8)

        let entries: [ZIPArchive.Entry] = [
            ZIPArchive.Entry(path: "mimetype", data: mimetype, compress: false),
            ZIPArchive.Entry(path: "META-INF/container.xml", data: container),
            ZIPArchive.Entry(path: "OEBPS/content.opf", data: opf),
            ZIPArchive.Entry(path: "OEBPS/nav.xhtml", data: nav),
            ZIPArchive.Entry(path: "OEBPS/ch1.xhtml", data: Data(ShowcaseCatalog.sampleChapters[0].xhtml.utf8)),
            ZIPArchive.Entry(path: "OEBPS/ch2.xhtml", data: Data(ShowcaseCatalog.sampleChapters[1].xhtml.utf8)),
        ]
        return try ZIPArchive.write(entries)
    }
}

public enum EPUBHTMLTextExtractor {
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>", options: [])
    private static let headingRegex = try! NSRegularExpression(pattern: "<h[1-3][^>]*>(.*?)</h[1-3]>", options: [.caseInsensitive, .dotMatchesLineSeparators])

    public static func extractHeading(fromHTML html: String) -> String? {
        let ns = html as NSString
        guard let m = headingRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: m.range(at: 1))
        let plain = stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }

    public static func extractParagraphs(fromHTML html: String) -> [String] {
        // Split cleanly on block boundaries while preserving paragraph cadence for native snapshot & fallback view
        let replaced = html
            .replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</h1>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</h2>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</h3>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        let body = stripScriptStyle(replaced)
        let stripped = stripTags(body)
        return stripped
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func extractPlainText(fromHTML html: String) -> String {
        extractParagraphs(fromHTML: html).joined(separator: "\n\n")
    }

    private static func stripScriptStyle(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<head[\s\S]*?</head>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        return s
    }

    private static func stripTags(_ s: String) -> String {
        let ns = s as NSString
        let noTags = tagRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
    }
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var fullPath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.lowercased() == "rootfile", let p = attributeDict["full-path"], !p.isEmpty {
            fullPath = p
        }
    }
}

private struct ManifestItem {
    var id: String
    var href: String
    var mediaType: String
    var properties: Set<String>
}

private final class OPFXMLDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var creators: [String] = []
    var identifiers: [String] = []
    var language = ""
    var manifestById: [String: ManifestItem] = [:]
    var spineIdRefs: [String] = []
    var coverMetaId: String?
    var ncxId: String?

    private var currentElement = ""
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()
        currentElement = name
        currentText = ""

        if name == "item", let id = attributeDict["id"], let href = attributeDict["href"] {
            let mt = attributeDict["media-type"] ?? ""
            let props = Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            manifestById[id] = ManifestItem(id: id, href: href, mediaType: mt, properties: props)
        } else if name == "itemref", let idref = attributeDict["idref"] {
            if attributeDict["linear"]?.lowercased() != "no" {
                spineIdRefs.append(idref)
            }
        } else if name == "spine", let toc = attributeDict["toc"] {
            ncxId = toc
        } else if name == "meta", attributeDict["name"]?.lowercased() == "cover", let content = attributeDict["content"] {
            coverMetaId = content
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if name == "title" || name == "dc:title" {
                if title.isEmpty { title = trimmed }
            } else if name == "creator" || name == "dc:creator" {
                creators.append(trimmed)
            } else if name == "identifier" || name == "dc:identifier" {
                identifiers.append(trimmed)
            } else if name == "language" || name == "dc:language" {
                if language.isEmpty { language = trimmed }
            }
        }
        currentElement = ""
        currentText = ""
    }
}

private final class NAVXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [(title: String, href: String)] = []
    private var inTocNav = false
    private var currentHref: String?
    private var currentLabel = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()
        if name == "nav" {
            let epubType = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
            if epubType.contains("toc") || entries.isEmpty {
                inTocNav = true
            }
        } else if inTocNav && name == "a", let href = attributeDict["href"] {
            currentHref = href
            currentLabel = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentHref != nil {
            currentLabel += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "a", let href = currentHref {
            let label = currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                entries.append((title: label, href: href))
            }
            currentHref = nil
            currentLabel = ""
        } else if name == "nav" {
            inTocNav = false
        }
    }
}

private final class NCXXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [(title: String, href: String)] = []
    private var inNavLabel = false
    private var inText = false
    private var pendingLabel = ""
    private var pendingHref: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()
        if name == "navpoint" {
            pendingLabel = ""
            pendingHref = nil
        } else if name == "navlabel" {
            inNavLabel = true
        } else if name == "text" && inNavLabel {
            inText = true
        } else if name == "content", let src = attributeDict["src"] {
            pendingHref = src
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { pendingLabel += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "text" {
            inText = false
        } else if name == "navlabel" {
            inNavLabel = false
        } else if name == "navpoint" {
            let label = pendingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, let href = pendingHref {
                entries.append((title: label, href: href))
            }
            pendingLabel = ""
            pendingHref = nil
        }
    }
}
