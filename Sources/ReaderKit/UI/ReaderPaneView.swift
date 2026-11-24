import EPUBEngine
import PDFEngine
import PDFKit
import ReaderModel
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ReaderPaneView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let activeTheme = ReaderPalette.resolvedTheme(vm.typography.theme, colorScheme: colorScheme)
        let chromeBg = ReaderPalette.themeSurface(activeTheme)
        let chromeFg = ReaderPalette.themeForeground(activeTheme)

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
                    .accessibilityLabel("Contents, Notes & Find")

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
                            ReaderHaptics.light()
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
                GeometryReader { geo in
                    let ratio = min(max(Double(book.progressPercent) / 100.0, 0), 1)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(chromeFg.opacity(0.10))
                        Rectangle()
                            .fill(ReaderPalette.accent)
                            .frame(width: ratio > 0 ? max(3, geo.size.width * ratio) : 0)
                    }
                }
                .frame(height: 2)
            } else {
                Divider()
            }

            ZStack(alignment: .bottom) {
                if let epub = vm.activeEPUB {
                    if isSnapshot {
                        SnapshotEPUBReaderBody(vm: vm, document: epub)
                    } else {
                        let chapterKey = "\(vm.activeBook?.id ?? ""):\(vm.activeEPUBSpineIndex):\(vm.activeNotes.count):\(vm.activeHighlights.count)"
                        let typographyJS = EPUBHTMLComposer.typographyUpdateJS(typography: vm.typography, resolvedTheme: activeTheme)
                        EPUBWebView(
                            html: vm.currentChapterHTML(resolvedTheme: activeTheme),
                            chapterKey: chapterKey,
                            typographyJS: typographyJS,
                            document: epub,
                            baseArchiveDir: (epub.spineHrefs[safe: vm.activeEPUBSpineIndex] as NSString?)?.deletingLastPathComponent ?? "",
                            onNoteTap: { noteId in
                                if let hit = vm.activeNotes.first(where: { $0.id == noteId }) {
                                    ReaderHaptics.selection()
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
                                    ReaderHaptics.light()
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        vm.isReaderChromeHidden.toggle()
                                    }
                                case "prev":
                                    ReaderHaptics.selection()
                                    Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex - 1) }
                                case "next":
                                    ReaderHaptics.selection()
                                    Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex + 1) }
                                default:
                                    break
                                }
                            }
                        )
                        .background(ReaderPalette.themeBackground(activeTheme))
                    }
                } else if let pdfURL = vm.activePDFURL {
                    if isSnapshot {
                        SnapshotPDFReaderBody(book: vm.activeBook, metadata: vm.activePDFMetadata, pageIndex: vm.activePDFPageIndex)
                    } else {
                        PDFKitReaderView(
                            url: pdfURL,
                            pageIndex: vm.activePDFPageIndex,
                            theme: activeTheme,
                            onPageChanged: { newPage in
                                Task { await vm.selectPDFPage(newPage) }
                            },
                            onCenterTap: {
                                ReaderHaptics.light()
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    vm.isReaderChromeHidden.toggle()
                                }
                            }
                        )
                    }
                } else if let book = vm.activeBook {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(book.title)
                            .font(.system(size: 18, weight: .semibold, design: .serif))
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
                        Text("Choose a book or paper from Library to begin reading.")
                            .font(.system(size: 13))
                            .foregroundStyle(ReaderPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Floating selection bar
                if !vm.activeSelectionText.isEmpty && !isSnapshot {
                    HStack(spacing: 10) {
                        Button {
                            ReaderHaptics.light()
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
                            ReaderHaptics.light()
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
                            ReaderHaptics.light()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                vm.isReaderChromeHidden = false
                            }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(chromeFg)
                                .padding(9)
                                .background(chromeBg.opacity(0.92), in: Circle())
                                .overlay(Circle().stroke(chromeFg.opacity(0.18), lineWidth: 1))
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
                let displayIdx = vm.scrubChapterTarget ?? vm.activeEPUBSpineIndex
                let total = max(1, epub.spineHrefs.count)
                let mins = vm.estimatedChapterMinutesRemaining()
                let pct = vm.activeBook?.progressPercent ?? 0

                Divider()
                VStack(spacing: 4) {
                    if !isSnapshot && epub.spineHrefs.count > 1 {
                        Slider(
                            value: Binding(
                                get: { Double(vm.scrubChapterTarget ?? vm.activeEPUBSpineIndex) },
                                set: { vm.scrubChapterTarget = Int($0.rounded()) }
                            ),
                            in: 0...Double(max(1, epub.spineHrefs.count - 1)),
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing, let target = vm.scrubChapterTarget {
                                    vm.scrubChapterTarget = nil
                                    ReaderHaptics.selection()
                                    Task { await vm.selectEPUBSpine(target) }
                                }
                            }
                        )
                        .tint(ReaderPalette.accent)
                        .controlSize(.mini)
                    }

                    HStack {
                        Button {
                            ReaderHaptics.selection()
                            Task { await vm.selectEPUBSpine(vm.activeEPUBSpineIndex - 1) }
                        } label: {
                            Label("Prev", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(chromeFg)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.activeEPUBSpineIndex <= 0)

                        Spacer()

                        Button {
                            vm.isTOCPresented = true
                        } label: {
                            let timeSuffix = (mins ?? 0) > 0 ? " · ~\(mins!) min" : ""
                            Text("Ch \(displayIdx + 1)/\(total) · \(pct)%\(timeSuffix)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(chromeFg.opacity(0.68))
                                .monospacedDigit()
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            ReaderHaptics.selection()
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(chromeBg)
            } else if vm.activePDFURL != nil, let meta = vm.activePDFMetadata, (!vm.isReaderChromeHidden || isSnapshot) {
                let displayIdx = vm.scrubPDFPageTarget ?? vm.activePDFPageIndex
                let total = max(1, meta.pageCount)

                Divider()
                VStack(spacing: 4) {
                    if !isSnapshot && meta.pageCount > 1 {
                        Slider(
                            value: Binding(
                                get: { Double(vm.scrubPDFPageTarget ?? vm.activePDFPageIndex) },
                                set: { vm.scrubPDFPageTarget = Int($0.rounded()) }
                            ),
                            in: 0...Double(max(1, meta.pageCount - 1)),
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing, let target = vm.scrubPDFPageTarget {
                                    vm.scrubPDFPageTarget = nil
                                    ReaderHaptics.selection()
                                    Task { await vm.selectPDFPage(target) }
                                }
                            }
                        )
                        .tint(ReaderPalette.accent)
                        .controlSize(.mini)
                    }

                    HStack {
                        Button {
                            ReaderHaptics.selection()
                            Task { await vm.selectPDFPage(vm.activePDFPageIndex - 1) }
                        } label: {
                            Label("Prev", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(chromeFg)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.activePDFPageIndex <= 0)

                        Spacer()

                        Button {
                            vm.isTOCPresented = true
                        } label: {
                            Text("Page \(displayIdx + 1)/\(total) · \(vm.activeBook?.progressPercent ?? 0)%")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(chromeFg.opacity(0.68))
                                .monospacedDigit()
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            ReaderHaptics.selection()
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(chromeBg)
            }
        }
        #if os(iOS)
        .statusBarHidden(vm.isReaderChromeHidden && !isSnapshot)
        #endif
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
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var vm: ReaderViewModel
    let document: EPUBDocument

    var body: some View {
        let chapter = document.chapter(at: vm.activeEPUBSpineIndex)
        let paragraphs = chapter.map { EPUBHTMLTextExtractor.extractParagraphs(fromHTML: String(data: $0.xhtmlData, encoding: .utf8) ?? "") } ?? []
        let notes = vm.activeNotes.filter { $0.spine == vm.activeEPUBSpineIndex }

        let activeTheme = ReaderPalette.resolvedTheme(vm.typography.theme, colorScheme: colorScheme)
        let bg = ReaderPalette.themeBackground(activeTheme)
        let surface = ReaderPalette.themeSurface(activeTheme)
        let fg = ReaderPalette.themeForeground(activeTheme)
        let muted = fg.opacity(0.68)
        let padX = CGFloat(vm.typography.marginWidth.horizontalPaddingPx)
        let extraLineSpacing = max(2, CGFloat(vm.typography.fontSize) * (CGFloat(vm.typography.lineHeight) - 1.25))

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
                            .lineSpacing(extraLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !notes.isEmpty {
                    Rectangle()
                        .fill(fg.opacity(0.14))
                        .frame(height: 1)
                        .padding(.top, 6)
                    Text("Margin notes (\(notes.count))")
                        .font(.system(size: 12.5, weight: .semibold, design: .serif))
                        .foregroundStyle(muted)
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
                                    .background(ReaderPalette.accent.opacity(0.14), in: Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.label)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(fg)
                                    Text(note.note)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(9)
                            .background(surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(fg.opacity(0.10), lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, padX)
            .padding(.vertical, 18)
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
                attr[range].backgroundColor = ReaderPalette.accent.opacity(0.16)
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
                .font(.system(size: 17, weight: .semibold, design: .serif))
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
    let chapterKey: String
    let typographyJS: String
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
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.document = document
        if context.coordinator.lastChapterKey != chapterKey {
            context.coordinator.lastChapterKey = chapterKey
            context.coordinator.lastTypographyJS = typographyJS
            let base = URL(string: "cohortbook://local/\(baseArchiveDir)/")
            web.loadHTMLString(html, baseURL: base)
        } else if context.coordinator.lastTypographyJS != typographyJS {
            context.coordinator.lastTypographyJS = typographyJS
            web.evaluateJavaScript(typographyJS, completionHandler: nil)
        }
    }
}

private struct PDFKitReaderView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int
    let theme: ReaderTheme
    let onPageChanged: (Int) -> Void
    let onCenterTap: () -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(onPageChanged: onPageChanged, onCenterTap: onCenterTap)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(ReaderPalette.themeBackground(theme))
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(PDFViewCoordinator.handleCenterTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onCenterTap = onCenterTap
        view.backgroundColor = UIColor(ReaderPalette.themeBackground(theme))
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
    let chapterKey: String
    let typographyJS: String
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
        if context.coordinator.lastChapterKey != chapterKey {
            context.coordinator.lastChapterKey = chapterKey
            context.coordinator.lastTypographyJS = typographyJS
            let base = URL(string: "cohortbook://local/\(baseArchiveDir)/")
            web.loadHTMLString(html, baseURL: base)
        } else if context.coordinator.lastTypographyJS != typographyJS {
            context.coordinator.lastTypographyJS = typographyJS
            web.evaluateJavaScript(typographyJS, completionHandler: nil)
        }
    }
}

private struct PDFKitReaderView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int
    let theme: ReaderTheme
    let onPageChanged: (Int) -> Void
    let onCenterTap: () -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(onPageChanged: onPageChanged, onCenterTap: onCenterTap)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(ReaderPalette.themeBackground(theme))
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onCenterTap = onCenterTap
        view.backgroundColor = NSColor(ReaderPalette.themeBackground(theme))
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
    var lastChapterKey: String = ""
    var lastTypographyJS: String = ""
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

#if canImport(UIKit)
@MainActor
private final class PDFViewCoordinator: NSObject, UIGestureRecognizerDelegate {
    let onPageChanged: (Int) -> Void
    var onCenterTap: () -> Void
    private weak var pdfView: PDFView?
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(onPageChanged: @escaping (Int) -> Void, onCenterTap: @escaping () -> Void) {
        self.onPageChanged = onPageChanged
        self.onCenterTap = onCenterTap
    }

    func observe(_ pdfView: PDFView) {
        self.pdfView = pdfView
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

    @objc func handleCenterTap(_ recognizer: UITapGestureRecognizer) {
        guard let pdfView else { return }
        guard pdfView.currentSelection == nil else { return }
        let width = max(1, pdfView.bounds.width)
        let ratio = recognizer.location(in: pdfView).x / width
        if ratio >= 0.20 && ratio <= 0.80 {
            onCenterTap()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
#else
@MainActor
private final class PDFViewCoordinator: NSObject {
    let onPageChanged: (Int) -> Void
    var onCenterTap: () -> Void
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(onPageChanged: @escaping (Int) -> Void, onCenterTap: @escaping () -> Void) {
        self.onPageChanged = onPageChanged
        self.onCenterTap = onCenterTap
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
#endif

// MARK: - Sheets

public struct MarginNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerSnapshotMode) private var isSnapshot
    public let note: MarginNote
    public var serverURL: String
    public var bookId: String
    public var onSendToCohort: (() -> Void)?

    public init(
        note: MarginNote,
        serverURL: String = "",
        bookId: String = "",
        onSendToCohort: (() -> Void)? = nil
    ) {
        self.note = note
        self.serverURL = serverURL
        self.bookId = bookId
        self.onSendToCohort = onSendToCohort
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
                    if let onSendToCohort {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("To Cohort", action: onSendToCohort)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func parsedCoordinates(_ mapSpec: String) -> (lat: Double, lon: Double)? {
        guard mapSpec.hasPrefix("locator:") else { return nil }
        let parts = mapSpec.dropFirst("locator:".count)
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func noteContent(includeHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if includeHeader {
                HStack {
                    Text("Margin Note")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                    Spacer()
                    if onSendToCohort != nil {
                        Text("To Cohort")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(ReaderPalette.cohortGreen)
                    }
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
                .font(.system(size: 20, weight: .semibold, design: .serif))
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
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let mapSpec = note.map, !mapSpec.isEmpty {
                if let coords = parsedCoordinates(mapSpec) {
                    OfflineLocatorMapView(lat: coords.lat, lon: coords.lon, placeLabel: note.label)
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

private struct OfflineLocatorMapView: View {
    let lat: Double
    let lon: Double
    let placeLabel: String

    private var formattedCoordinate: String {
        let latHem = lat >= 0 ? "N" : "S"
        let lonHem = lon >= 0 ? "E" : "W"
        return String(format: "%.2f° %@, %.2f° %@", abs(lat), latHem, abs(lon), lonHem)
    }

    // Simplified vector continent outlines in (lon, lat) degrees for zero-network equirectangular context.
    private static let landmassPolygons: [[(Double, Double)]] = [
        // North America
        [(-168, 65), (-140, 70), (-125, 70), (-95, 72), (-80, 62), (-64, 52), (-56, 51), (-68, 44), (-75, 35), (-81, 25), (-83, 29), (-90, 29), (-97, 26), (-88, 21), (-83, 10), (-79, 9), (-86, 11), (-93, 15), (-105, 20), (-112, 27), (-118, 32), (-124, 41), (-125, 49), (-136, 58), (-154, 58)],
        // South America
        [(-79, 10), (-72, 12), (-62, 10), (-50, 1), (-35, -6), (-39, -18), (-46, -24), (-54, -34), (-65, -42), (-68, -54), (-74, -52), (-74, -40), (-71, -30), (-71, -18), (-81, -5), (-79, 2)],
        // Europe & Eurasia
        [(-9, 37), (-9, 43), (-2, 43), (-4, 48), (2, 51), (9, 55), (5, 61), (18, 70), (30, 71), (58, 69), (90, 74), (130, 72), (170, 66), (160, 56), (140, 48), (128, 36), (120, 31), (110, 20), (104, 2), (98, 12), (90, 22), (78, 8), (68, 23), (56, 26), (48, 29), (35, 31), (28, 36), (22, 37), (15, 38), (12, 44), (5, 43), (-5, 36)],
        // Africa
        [(-6, 35), (10, 37), (32, 31), (43, 12), (51, 12), (40, -5), (35, -24), (20, -35), (15, -26), (12, -12), (9, 4), (0, 5), (-8, 5), (-17, 15), (-16, 24)],
        // Australia
        [(114, -22), (129, -15), (137, -12), (143, -11), (153, -27), (150, -37), (138, -36), (129, -32), (115, -34)],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    let w = size.width
                    let h = size.height

                    func project(lon: Double, lat: Double) -> CGPoint {
                        let x = ((lon + 180.0) / 360.0) * w
                        let y = ((90.0 - lat) / 180.0) * h
                        return CGPoint(x: x, y: y)
                    }

                    // Graticule grid (30 deg steps)
                    var grid = Path()
                    for lonStep in stride(from: -150.0, through: 150.0, by: 30.0) {
                        let top = project(lon: lonStep, lat: 90)
                        let bot = project(lon: lonStep, lat: -90)
                        grid.move(to: top)
                        grid.addLine(to: bot)
                    }
                    for latStep in stride(from: -60.0, through: 60.0, by: 30.0) {
                        let left = project(lon: -180, lat: latStep)
                        let right = project(lon: 180, lat: latStep)
                        grid.move(to: left)
                        grid.addLine(to: right)
                    }
                    ctx.stroke(grid, with: .color(ReaderPalette.hairline.opacity(0.65)), lineWidth: 0.5)

                    // Landmasses
                    for poly in Self.landmassPolygons {
                        var path = Path()
                        for (idx, pt) in poly.enumerated() {
                            let p = project(lon: pt.0, lat: pt.1)
                            if idx == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                        path.closeSubpath()
                        ctx.fill(path, with: .color(ReaderPalette.secondary.opacity(0.20)))
                        ctx.stroke(path, with: .color(ReaderPalette.secondary.opacity(0.32)), lineWidth: 0.6)
                    }

                    // Target pin & crosshairs
                    let target = project(lon: lon, lat: lat)
                    var cross = Path()
                    cross.move(to: CGPoint(x: target.x, y: 0))
                    cross.addLine(to: CGPoint(x: target.x, y: h))
                    cross.move(to: CGPoint(x: 0, y: target.y))
                    cross.addLine(to: CGPoint(x: w, y: target.y))
                    ctx.stroke(cross, with: .color(ReaderPalette.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))

                    let outer = CGRect(x: target.x - 11, y: target.y - 11, width: 22, height: 22)
                    ctx.fill(Path(ellipseIn: outer), with: .color(ReaderPalette.accent.opacity(0.16)))
                    ctx.stroke(Path(ellipseIn: outer), with: .color(ReaderPalette.accent.opacity(0.65)), lineWidth: 1)

                    let inner = CGRect(x: target.x - 4, y: target.y - 4, width: 8, height: 8)
                    ctx.fill(Path(ellipseIn: inner), with: .color(ReaderPalette.accent))
                }
                .frame(height: 138)

                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ReaderPalette.accent)
                    Text("\(placeLabel) · \(formattedCoordinate)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ReaderPalette.label)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ReaderPalette.elevated.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 0.75))
                .padding(8)
            }
        }
        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 0.75))
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
                    Text("Find").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if vm.tocSegment == 2 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12.5))
                            .foregroundStyle(ReaderPalette.secondary)
                        TextField("Search inside book", text: $vm.tocSearchQuery)
                            .font(.system(size: 13.5))
                            .onSubmit { vm.runInBookSearch() }
                            .onChange(of: vm.tocSearchQuery) { _, _ in vm.runInBookSearch() }
                        if !vm.tocSearchQuery.isEmpty {
                            Button {
                                vm.tocSearchQuery = ""
                                vm.inBookMatches = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(ReaderPalette.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                List {
                    if vm.tocSegment == 0 {
                        if let epub = vm.activeEPUB {
                            ForEach(epub.toc) { entry in
                                Button {
                                    ReaderHaptics.selection()
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
                                    ReaderHaptics.selection()
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
                    } else if vm.tocSegment == 1 {
                        if !vm.activeHighlights.isEmpty {
                            Section("Saved Highlights") {
                                ForEach(vm.activeHighlights) { h in
                                    HStack(alignment: .top, spacing: 8) {
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
                                                    .multilineTextAlignment(.leading)
                                                if !h.note.isEmpty {
                                                    Text(h.note)
                                                        .font(.system(size: 11.5))
                                                        .foregroundStyle(ReaderPalette.secondary)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            dismiss()
                                            vm.prepareCohortDraft(quote: h.quote)
                                        } label: {
                                            Image(systemName: "rectangle.badge.plus")
                                                .font(.system(size: 13))
                                                .foregroundStyle(ReaderPalette.cohortGreen)
                                                .padding(4)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Send highlight to Cohort")

                                        Button {
                                            Task { await vm.deleteHighlight(h) }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(ReaderPalette.secondary)
                                                .padding(4)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Delete highlight")
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            Task { await vm.deleteHighlight(h) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
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
                    } else {
                        if vm.tocSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                            Text("Type at least 2 characters to search chapters.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(ReaderPalette.secondary)
                        } else if vm.inBookMatches.isEmpty {
                            Text("No passages matched \"\(vm.tocSearchQuery)\".")
                                .font(.system(size: 12.5))
                                .foregroundStyle(ReaderPalette.secondary)
                        } else {
                            ForEach(vm.inBookMatches) { hit in
                                Button {
                                    ReaderHaptics.selection()
                                    Task {
                                        await vm.selectEPUBSpine(hit.spineIndex)
                                        dismiss()
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(hit.chapterTitle)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(ReaderPalette.accent)
                                            Spacer()
                                            Text("Ch \(hit.spineIndex + 1)")
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(ReaderPalette.secondary)
                                        }
                                        Text(hit.snippet)
                                            .font(.system(size: 12.5, design: .serif))
                                            .foregroundStyle(ReaderPalette.label)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(vm.tocSegment == 0 ? "Contents" : (vm.tocSegment == 1 ? "Notes & Highlights" : "Find in Book"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

public struct TypographySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Binding public var typography: ReaderTypography
    public var onChange: () -> Void

    public init(typography: Binding<ReaderTypography>, onChange: @escaping () -> Void) {
        self._typography = typography
        self.onChange = onChange
    }

    public var body: some View {
        if isSnapshot {
            panelBody(includeHeader: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ReaderPalette.background)
        } else {
            NavigationStack {
                ScrollView {
                    panelBody(includeHeader: false)
                }
                .background(ReaderPalette.background)
                .navigationTitle("Typography")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onChange(of: typography) { _, _ in onChange() }
            .presentationDetents([.medium, .large])
        }
    }

    private func panelBody(includeHeader: Bool) -> some View {
        let previewTheme = ReaderPalette.resolvedTheme(typography.theme, colorScheme: colorScheme)
        let previewBg = ReaderPalette.themeBackground(previewTheme)
        let previewFg = ReaderPalette.themeForeground(previewTheme)
        let previewDesign: Font.Design = typography.fontFamily == .mono ? .monospaced : (typography.fontFamily == .sans ? .default : .serif)
        let previewLineSpacing = max(2, CGFloat(typography.fontSize) * (CGFloat(typography.lineHeight) - 1.25))

        return VStack(alignment: .leading, spacing: 14) {
            if includeHeader {
                HStack {
                    Text("Typography")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                    Spacer()
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderPalette.accent)
                }
                Divider()
            }

            // Live Preview Strip
            Text("The world we inhabit is shaped as much by quiet tools of legibility as by grand designs.")
                .font(.system(size: min(22, max(13, typography.fontSize)), design: previewDesign))
                .foregroundStyle(previewFg)
                .lineSpacing(previewLineSpacing)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .padding(.horizontal, CGFloat(typography.marginWidth.horizontalPaddingPx) * 0.7)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(previewBg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 0.75))

            // Theme Swatches
            VStack(alignment: .leading, spacing: 7) {
                Text("Page Theme")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReaderPalette.secondary)
                HStack(spacing: 8) {
                    ForEach(ReaderTheme.allCases, id: \.self) { theme in
                        let selected = typography.theme == theme
                        Button {
                            ReaderHaptics.selection()
                            typography.theme = theme
                            onChange()
                        } label: {
                            VStack(spacing: 5) {
                                themeSwatchCircle(theme)
                                Text(theme.rawValue)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? ReaderPalette.accent : ReaderPalette.label)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(selected ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: selected ? 1.5 : 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Typeface Specimens
            VStack(alignment: .leading, spacing: 7) {
                Text("Typeface")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReaderPalette.secondary)
                HStack(spacing: 8) {
                    ForEach(ReaderFontFamily.allCases, id: \.self) { fam in
                        let selected = typography.fontFamily == fam
                        let design: Font.Design = fam == .mono ? .monospaced : (fam == .sans ? .default : .serif)
                        Button {
                            ReaderHaptics.selection()
                            typography.fontFamily = fam
                            onChange()
                        } label: {
                            VStack(spacing: 2) {
                                Text("Aa")
                                    .font(.system(size: 19, weight: .semibold, design: design))
                                    .foregroundStyle(ReaderPalette.label)
                                Text(fam.rawValue)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? ReaderPalette.accent : ReaderPalette.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(selected ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: selected ? 1.5 : 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Size & Spacing Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        ReaderHaptics.selection()
                        typography.fontSize = max(14, typography.fontSize - 1)
                        onChange()
                    } label: {
                        Text("A−")
                            .font(.system(size: 13, weight: .semibold, design: .serif))
                            .frame(width: 34, height: 28)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(ReaderPalette.label)
                    }
                    .buttonStyle(.plain)

                    if isSnapshot {
                        InstrumentGauge(ratio: (typography.fontSize - 14.0) / 14.0, tint: ReaderPalette.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Slider(value: $typography.fontSize, in: 14...28, step: 1)
                            .tint(ReaderPalette.accent)
                    }

                    Button {
                        ReaderHaptics.selection()
                        typography.fontSize = min(28, typography.fontSize + 1)
                        onChange()
                    } label: {
                        Text("A+")
                            .font(.system(size: 14.5, weight: .semibold, design: .serif))
                            .frame(width: 34, height: 28)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(ReaderPalette.label)
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(typography.fontSize)) pt")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ReaderPalette.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Line spacing")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.label)
                    if isSnapshot {
                        InstrumentGauge(ratio: (typography.lineHeight - 1.25) / 0.70, tint: ReaderPalette.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Slider(value: $typography.lineHeight, in: 1.25...1.95, step: 0.05)
                            .tint(ReaderPalette.accent)
                    }
                    Text(String(format: "%.2f×", typography.lineHeight))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ReaderPalette.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Margins")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.label)
                        .frame(width: 58, alignment: .leading)
                    segmentedStrip(
                        options: ReaderMarginWidth.allCases,
                        selected: typography.marginWidth,
                        label: \.rawValue
                    ) { next in
                        ReaderHaptics.selection()
                        typography.marginWidth = next
                        onChange()
                    }
                }

                HStack(spacing: 10) {
                    Text("Align")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.label)
                        .frame(width: 58, alignment: .leading)
                    segmentedStrip(
                        options: ReaderTextAlignment.allCases,
                        selected: typography.textAlignment,
                        label: \.rawValue
                    ) { next in
                        ReaderHaptics.selection()
                        typography.textAlignment = next
                        onChange()
                    }
                }
            }
            .padding(12)
            .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 0.75))

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func segmentedStrip<T: Hashable>(
        options: [T],
        selected: T,
        label: KeyPath<T, String>,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSel = option == selected
                Button {
                    onSelect(option)
                } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 11.5, weight: isSel ? .semibold : .medium))
                        .foregroundStyle(isSel ? Color.white : ReaderPalette.label)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            isSel ? ReaderPalette.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 0.75))
    }

    @ViewBuilder
    private func themeSwatchCircle(_ theme: ReaderTheme) -> some View {
        if theme == .auto {
            ZStack {
                Circle()
                    .fill(ReaderPalette.themeBackground(.paper))
                Circle()
                    .trim(from: 0.5, to: 1.0)
                    .fill(ReaderPalette.themeBackground(.ink))
                Circle()
                    .strokeBorder(ReaderPalette.hairline, lineWidth: 1)
            }
            .frame(width: 24, height: 24)
        } else {
            Circle()
                .fill(ReaderPalette.themeBackground(theme))
                .overlay(Circle().strokeBorder(ReaderPalette.hairline, lineWidth: 1))
                .frame(width: 24, height: 24)
        }
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
