import EPUBEngine
import PDFEngine
import PDFKit
import ReaderModel
import SwiftUI
import WebKit

public struct ReaderPaneView: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let chromeBg = ReaderPalette.themeSurface(vm.typography.theme)
        let chromeFg = ReaderPalette.themeForeground(vm.typography.theme)

        VStack(spacing: 0) {
            if !vm.isReaderChromeHidden || isSnapshot {
                // Top Reader Bar
                HStack(spacing: 8) {
                    Button {
                        vm.isTOCPresented = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(chromeFg)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.activeBook == nil)
                    .accessibilityLabel("Contents and Notes")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.activeBook?.title ?? "No document open")
                            .font(.system(size: 13.5, weight: .semibold, design: .serif))
                            .foregroundStyle(chromeFg)
                            .lineLimit(1)
                            .help(vm.activeBook?.title ?? "")
                        if let sub = currentSubtitle {
                            Text(sub)
                                .font(.system(size: 11))
                                .foregroundStyle(chromeFg.opacity(0.65))
                                .lineLimit(1)
                                .help(sub)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if vm.activeBook != nil {
                        Button {
                            let sampleQuote = vm.activeSelectionText.isEmpty
                                ? (vm.currentChapter()?.plainText.split(separator: ".").first.map(String.init) ?? vm.activeBook?.summary ?? "")
                                : vm.activeSelectionText
                            vm.prepareCohortDraft(quote: sampleQuote)
                        } label: {
                            Image(systemName: "rectangle.badge.plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(chromeFg)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send passage to Cohort")

                        Button {
                            vm.isTypographyPresented = true
                        } label: {
                            Text("Aa")
                                .font(.system(size: 13, weight: .semibold, design: .serif))
                                .foregroundStyle(chromeFg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Typography")

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                vm.isReaderChromeHidden.toggle()
                            }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(chromeFg)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Focus Reading")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(chromeBg)
            }

            if let book = vm.activeBook {
                InstrumentGauge(ratio: Double(book.progressPercent) / 100.0, tint: ReaderPalette.accent)
            } else {
                Divider()
            }

            ZStack(alignment: .bottom) {
                if let epub = vm.activeEPUB {
                    if isSnapshot {
                        SnapshotEPUBReaderBody(vm: vm, document: epub)
                    } else {
                        EPUBWebView(
                            html: vm.currentChapterHTML(),
                            document: epub,
                            baseArchiveDir: (epub.spineHrefs[safe: vm.activeEPUBSpineIndex] as NSString?)?.deletingLastPathComponent ?? "",
                            onNoteTap: { noteId in
                                if let hit = vm.activeNotes.first(where: { $0.id == noteId }) {
                                    vm.presentedMarginNote = hit
                                }
                            },
                            onProgress: { frac, word in
                                Task {
                                    await vm.recordProgress(
                                        spine: vm.activeEPUBSpineIndex,
                                        fraction: frac,
                                        wordOffset: word,
                                        pageIndex: nil
                                    )
                                }
                            },
                            onSelection: { text in
                                vm.activeSelectionText = text
                            },
                            onZoneTap: { zone in
                                switch zone {
                                case "center":
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        vm.isReaderChromeHidden.toggle()
                                    }
                                case "prev":
                                    Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex - 1) }
                                case "next":
                                    Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex + 1) }
                                default:
                                    break
                                }
                            }
                        )
                    }
                } else if let pdfURL = vm.activePDFURL {
                    if isSnapshot {
                        SnapshotPDFReaderBody(book: vm.activeBook, metadata: vm.activePDFMetadata, pageIndex: vm.activePDFPageIndex)
                    } else {
                        PDFKitReaderView(
                            url: pdfURL,
                            pageIndex: vm.activePDFPageIndex,
                            onPageChanged: { newPage in
                                Task { await vm.selectPDFPage(newPage) }
                            }
                        )
                    }
                } else if let book = vm.activeBook {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(book.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(ReaderPalette.label)
                        Text(book.shortCitation)
                            .font(.system(size: 13))
                            .foregroundStyle(ReaderPalette.secondary)
                        Text(book.summary.isEmpty ? "Metadata reference entry." : book.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(ReaderPalette.label)
                        if let cid = book.canonicalId {
                            Text(cid)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(ReaderPalette.accent)
                        }
                        if book.epubURL != nil || book.openAccessURL != nil || book.source == .homeServer {
                            Button {
                                Task { await vm.downloadForOffline(book) }
                            } label: {
                                Text("Download Open / Library Edition")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(ReaderPalette.accent, in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 28))
                            .foregroundStyle(ReaderPalette.secondary)
                        Text("Choose a book or paper from Shelf to begin reading.")
                            .font(.system(size: 13))
                            .foregroundStyle(ReaderPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Floating selection bar
                if !vm.activeSelectionText.isEmpty && !isSnapshot {
                    HStack(spacing: 10) {
                        Button {
                            let q = vm.activeSelectionText
                            Task { await vm.saveQuickHighlight(quote: q) }
                        } label: {
                            Label("Highlight", systemImage: "highlighter")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ReaderPalette.label)
                        }
                        .buttonStyle(.plain)

                        Divider().frame(height: 14)

                        Button {
                            vm.prepareCohortDraft(quote: vm.activeSelectionText)
                        } label: {
                            Label("To Cohort", systemImage: "rectangle.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ReaderPalette.cohortGreen)
                        }
                        .buttonStyle(.plain)

                        Divider().frame(height: 14)

                        Button {
                            vm.activeSelectionText = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ReaderPalette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(ReaderPalette.surface, in: Capsule())
                    .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 1))
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 12)
                } else if vm.isReaderChromeHidden && !isSnapshot {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                vm.isReaderChromeHidden = false
                            }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ReaderPalette.label)
                                .padding(9)
                                .background(ReaderPalette.surface.opacity(0.92), in: Circle())
                                .overlay(Circle().stroke(ReaderPalette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show Controls")
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let epub = vm.activeEPUB, (!vm.isReaderChromeHidden || isSnapshot) {
                Divider()
                HStack {
                    Button {
                        Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex - 1) }
                    } label: {
                        Label("Prev", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(chromeFg)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.activeEPUBSpineIndex <= 0)

                    Spacer()

                    Text("Ch \(vm.activeEPUBSpineIndex + 1)/\(epub.spineHrefs.count) · \(vm.activeBook?.progressPercent ?? 0)%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(chromeFg.opacity(0.65))
                        .monospacedDigit()

                    Spacer()

                    Button {
                        Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex + 1) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(chromeFg)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.activeEPUBSpineIndex + 1 >= epub.spineHrefs.count)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(chromeBg)
            } else if vm.activePDFURL != nil, let meta = vm.activePDFMetadata, (!vm.isReaderChromeHidden || isSnapshot) {
                Divider()
                HStack {
                    Button {
                        Task { await vm.selectPDFPage(vm.activePDFPageIndex - 1) }
                    } label: {
                        Label("Prev", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(chromeFg)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.activePDFPageIndex <= 0)

                    Spacer()

                    Text("Page \(vm.activePDFPageIndex + 1)/\(max(1, meta.pageCount)) · \(vm.activeBook?.progressPercent ?? 0)%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(chromeFg.opacity(0.65))
                        .monospacedDigit()

                    Spacer()

                    Button {
                        Task { await vm.selectPDFPage(vm.activePDFPageIndex + 1) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(chromeFg)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.activePDFPageIndex + 1 >= meta.pageCount)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(chromeBg)
            }
        }
        .sheet(isPresented: $vm.isTOCPresented) {
            TOCSheet(vm: vm)
        }
        .sheet(isPresented: $vm.isTypographyPresented) {
            TypographySheet(typography: $vm.typography, onChange: { vm.saveTypography() })
        }
    }

    private var currentSubtitle: String? {
        if let chapter = vm.currentChapter() {
            return chapter.title
        }
        if let meta = vm.activePDFMetadata {
            return "Page \(vm.activePDFPageIndex + 1) of \(max(1, meta.pageCount))"
        }
        return vm.activeBook?.canonicalId
    }
}

private struct SnapshotEPUBReaderBody: View {
    @Bindable var vm: ReaderViewModel
    let document: EPUBDocument

    var body: some View {
        let chapter = document.chapter(at: vm.activeEPUBSpineIndex)
        let paragraphs = chapter.map { EPUBHTMLTextExtractor.extractParagraphs(fromHTML: String(data: $0.xhtmlData, encoding: .utf8) ?? "") } ?? []
        let notes = vm.activeNotes.filter { $0.spine == vm.activeEPUBSpineIndex }

        let bg = ReaderPalette.themeBackground(vm.typography.theme)
        let fg = ReaderPalette.themeForeground(vm.typography.theme)

        ReaderScrollContainer {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { idx, para in
                    if idx == 0 {
                        Text(para)
                            .font(.system(size: vm.typography.fontSize + 5, weight: .semibold, design: .serif))
                            .foregroundStyle(fg)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        highlightedParagraph(para, notes: notes, fg: fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !notes.isEmpty {
                    Divider()
                        .padding(.top, 6)
                    Text("Margin notes (\(notes.count))")
                        .font(.system(size: 12.5, weight: .semibold, design: .serif))
                        .foregroundStyle(ReaderPalette.secondary)
                    ForEach(notes) { note in
                        Button {
                            vm.presentedMarginNote = note
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(note.kind.capitalized)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(ReaderPalette.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(ReaderPalette.accent.opacity(0.12), in: Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.label)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(fg)
                                    Text(note.note)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(ReaderPalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(ReaderPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(bg)
    }

    private func highlightedParagraph(_ text: String, notes: [MarginNote], fg: Color) -> Text {
        var attr = AttributedString(text)
        attr.font = .system(size: vm.typography.fontSize, design: vm.typography.fontFamily == .mono ? .monospaced : (vm.typography.fontFamily == .sans ? .default : .serif))
        attr.foregroundColor = fg
        for note in notes {
            if let range = attr.range(of: note.anchor, options: .caseInsensitive) {
                attr[range].underlineStyle = Text.LineStyle(pattern: .dot, color: ReaderPalette.accent)
                attr[range].backgroundColor = ReaderPalette.accent.opacity(0.14)
            }
        }
        return Text(attr)
    }
}

private struct SnapshotPDFReaderBody: View {
    let book: BookItem?
    let metadata: PDFMetadataSummary?
    let pageIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metadata?.title ?? book?.title ?? "PDF")
                .font(.system(size: 17, weight: .semibold))
            Text("Page \(pageIndex + 1) / \(max(1, metadata?.pageCount ?? 1))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(ReaderPalette.secondary)
            if let front = metadata?.frontMatterText {
                Text(front)
                    .font(.system(size: 13))
                    .foregroundStyle(ReaderPalette.label)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Platform WebKit & PDFKit Wrappers

#if canImport(UIKit)
private struct EPUBWebView: UIViewRepresentable {
    let html: String
    let document: EPUBDocument
    let baseArchiveDir: String
    let onNoteTap: (String) -> Void
    let onProgress: (Double, Int) -> Void
    let onSelection: (String) -> Void
    let onZoneTap: (String) -> Void

    func makeCoordinator() -> EPUBWebCoordinator {
        EPUBWebCoordinator(document: document, onNoteTap: onNoteTap, onProgress: onProgress, onSelection: onSelection, onZoneTap: onZoneTap)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "cohortbook")
        config.userContentController.add(context.coordinator, name: "cohortReader")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.document = document
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            let base = URL(string: "cohortbook://local/\(baseArchiveDir)/")
            web.loadHTMLString(html, baseURL: base)
        }
    }
}

private struct PDFKitReaderView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(onPageChanged: onPageChanged)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let doc = view.document, pageIndex >= 0, pageIndex < doc.pageCount,
           let target = doc.page(at: pageIndex),
           view.currentPage != target {
            view.go(to: target)
        }
    }
}
#elseif canImport(AppKit)
private struct EPUBWebView: NSViewRepresentable {
    let html: String
    let document: EPUBDocument
    let baseArchiveDir: String
    let onNoteTap: (String) -> Void
    let onProgress: (Double, Int) -> Void
    let onSelection: (String) -> Void
    let onZoneTap: (String) -> Void

    func makeCoordinator() -> EPUBWebCoordinator {
        EPUBWebCoordinator(document: document, onNoteTap: onNoteTap, onProgress: onProgress, onSelection: onSelection, onZoneTap: onZoneTap)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "cohortbook")
        config.userContentController.add(context.coordinator, name: "cohortReader")
        let web = WKWebView(frame: .zero, configuration: config)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.document = document
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            let base = URL(string: "cohortbook://local/\(baseArchiveDir)/")
            web.loadHTMLString(html, baseURL: base)
        }
    }
}

private struct PDFKitReaderView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(onPageChanged: onPageChanged)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let doc = view.document, pageIndex >= 0, pageIndex < doc.pageCount,
           let target = doc.page(at: pageIndex),
           view.currentPage != target {
            view.go(to: target)
        }
    }
}
#endif

@MainActor
private final class EPUBWebCoordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    var document: EPUBDocument
    var lastHTML: String = ""
    let onNoteTap: (String) -> Void
    let onProgress: (Double, Int) -> Void
    let onSelection: (String) -> Void
    let onZoneTap: (String) -> Void

    init(
        document: EPUBDocument,
        onNoteTap: @escaping (String) -> Void,
        onProgress: @escaping (Double, Int) -> Void,
        onSelection: @escaping (String) -> Void,
        onZoneTap: @escaping (String) -> Void
    ) {
        self.document = document
        self.onNoteTap = onNoteTap
        self.onProgress = onProgress
        self.onSelection = onSelection
        self.onZoneTap = onZoneTap
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let path = urlSchemeTask.request.url?.path ?? ""
        if let res = document.resourceData(forArchivePath: path) {
            let resp = URLResponse(
                url: urlSchemeTask.request.url!,
                mimeType: res.mimeType,
                expectedContentLength: res.data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(res.data)
            urlSchemeTask.didFinish()
        } else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "noteTap":
            if let noteId = body["noteId"] as? String { onNoteTap(noteId) }
        case "progress":
            let frac = body["fraction"] as? Double ?? 0
            let word = body["wordOffset"] as? Int ?? 0
            onProgress(frac, word)
        case "selection":
            if let text = body["text"] as? String { onSelection(text) }
        case "zoneTap":
            if let zone = body["zone"] as? String { onZoneTap(zone) }
        default:
            break
        }
    }
}

@MainActor
private final class PDFViewCoordinator: NSObject {
    let onPageChanged: (Int) -> Void
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(onPageChanged: @escaping (Int) -> Void) {
        self.onPageChanged = onPageChanged
    }

    func observe(_ pdfView: PDFView) {
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            Task { @MainActor in
                guard let self, let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return }
                let idx = doc.index(for: page)
                if idx != NSNotFound {
                    self.onPageChanged(idx)
                }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - Sheets

public struct MarginNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerSnapshotMode) private var isSnapshot
    public let note: MarginNote
    public var serverURL: String
    public var bookId: String

    public init(note: MarginNote, serverURL: String = "", bookId: String = "") {
        self.note = note
        self.serverURL = serverURL
        self.bookId = bookId
    }

    public var body: some View {
        if isSnapshot {
            noteContent(includeHeader: true)
        } else {
            NavigationStack {
                ScrollView {
                    noteContent(includeHeader: false)
                }
                .background(ReaderPalette.background)
                .navigationTitle("Margin Note")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func noteContent(includeHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if includeHeader {
                HStack {
                    Text("Margin Note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ReaderPalette.label)
                    Spacer()
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderPalette.accent)
                }
                Divider()
            }

            HStack(spacing: 8) {
                Text(note.kind.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ReaderPalette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ReaderPalette.accent.opacity(0.12), in: Capsule())
                Text("·")
                    .foregroundStyle(ReaderPalette.secondary)
                if let url = URL(string: note.source), note.source.hasPrefix("https://") {
                    Link(destination: url) {
                        Text(note.source)
                            .font(.system(size: 11.5))
                            .underline()
                    }
                } else {
                    Text(note.source)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ReaderPalette.secondary)
                }
            }

            Text(note.label)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ReaderPalette.label)

            Text("\"\(note.anchor)\"")
                .font(.system(size: 12.5, design: .serif))
                .italic()
                .foregroundStyle(ReaderPalette.secondary)

            if let imageAsset = note.image, !imageAsset.isEmpty, !serverURL.isEmpty, !bookId.isEmpty {
                NoteAssetImageView(serverURL: serverURL, bookId: bookId, asset: imageAsset, isSnapshot: isSnapshot)
            }

            Divider()

            Text(note.note)
                .font(.system(size: 14.5))
                .foregroundStyle(ReaderPalette.label)
                .fixedSize(horizontal: false, vertical: true)

            if let mapSpec = note.map, !mapSpec.isEmpty {
                if mapSpec.hasPrefix("locator:") {
                    HStack(spacing: 8) {
                        Image(systemName: "map")
                            .foregroundStyle(ReaderPalette.accent)
                        Text("Offline locator coordinates: \(mapSpec.replacingOccurrences(of: "locator:", with: ""))")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(ReaderPalette.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                } else if !serverURL.isEmpty, !bookId.isEmpty {
                    NoteAssetImageView(serverURL: serverURL, bookId: bookId, asset: mapSpec, isSnapshot: isSnapshot)
                }
            }

            if let credit = note.credit, !credit.isEmpty {
                Text(credit)
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderPalette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderPalette.background)
    }
}

private struct TOCSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var vm: ReaderViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $vm.tocSegment) {
                    Text("Contents").tag(0)
                    Text("Notes (\(vm.activeNotes.count + vm.activeHighlights.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                List {
                    if vm.tocSegment == 0 {
                        if let epub = vm.activeEPUB {
                            ForEach(epub.toc) { entry in
                                Button {
                                    Task {
                                        await vm.selectEPUBSpine(entry.spineIndex)
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        Text(entry.title)
                                            .foregroundStyle(ReaderPalette.label)
                                        Spacer()
                                        if entry.spineIndex == vm.activeEPUBSpineIndex {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(ReaderPalette.accent)
                                        }
                                    }
                                }
                            }
                        } else if let meta = vm.activePDFMetadata {
                            ForEach(meta.outline) { entry in
                                Button {
                                    Task {
                                        await vm.selectPDFPage(entry.pageIndex)
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        Text(entry.title)
                                        Spacer()
                                        Text("p.\(entry.pageIndex + 1)")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(ReaderPalette.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        if !vm.activeHighlights.isEmpty {
                            Section("Saved Highlights") {
                                ForEach(vm.activeHighlights) { h in
                                    Button {
                                        Task {
                                            await vm.selectEPUBSpine(h.spine)
                                            dismiss()
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\"\(h.quote)\"")
                                                .font(.system(size: 12.5, design: .serif))
                                                .foregroundStyle(ReaderPalette.label)
                                            if !h.note.isEmpty {
                                                Text(h.note)
                                                    .font(.system(size: 11.5))
                                                    .foregroundStyle(ReaderPalette.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if !vm.activeNotes.isEmpty {
                            Section("Offline Margin Notes") {
                                ForEach(vm.activeNotes) { note in
                                    Button {
                                        Task {
                                            await vm.selectEPUBSpine(note.spine)
                                            dismiss()
                                            vm.presentedMarginNote = note
                                        }
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(note.kind.uppercased())
                                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                .foregroundStyle(ReaderPalette.accent)
                                                .frame(width: 44, alignment: .leading)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(note.label)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(ReaderPalette.label)
                                                Text(note.note)
                                                    .font(.system(size: 11.5))
                                                    .foregroundStyle(ReaderPalette.secondary)
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            Text("Ch \(note.spine + 1)")
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(ReaderPalette.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(vm.tocSegment == 0 ? "Contents" : "Notes & Highlights")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct TypographySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var typography: ReaderTypography
    var onChange: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $typography.theme) {
                        ForEach(ReaderTheme.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Typeface") {
                    Picker("Font", selection: $typography.fontFamily) {
                        ForEach(ReaderFontFamily.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Size (\(Int(typography.fontSize)) pt)") {
                    Slider(value: $typography.fontSize, in: 14...28, step: 1)
                }
                Section("Line Spacing (\(String(format: "%.2f", typography.lineHeight))×)") {
                    Slider(value: $typography.lineHeight, in: 1.25...1.95, step: 0.05)
                }
            }
            .onChange(of: typography) { _, _ in onChange() }
            .navigationTitle("Typography")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct CohortDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var vm: ReaderViewModel
    let draft: CohortCardDraft

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.sourceTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let cid = draft.canonicalId {
                    Text(cid)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ReaderPalette.accent)
                }
                Text(draft.quote)
                    .font(.system(size: 13, design: .serif))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 6))

                TextField("Study note or recall cue (optional)", text: $vm.cohortDraftNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                Button {
                    Task {
                        if let url = await vm.sendDraftToCohort(draft, note: vm.cohortDraftNote) {
                            openURL(url)
                        }
                        dismiss()
                    }
                } label: {
                    Text("Send Seed to Cohort")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(ReaderPalette.cohortGreen, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(16)
            .navigationTitle("Send to Cohort")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
