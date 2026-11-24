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

        let isPDFActive = vm.activePDFURL != nil || (vm.activeBook?.format == .pdf || vm.activeBook?.format == .article)
        #if os(macOS)
        let showTabStrip = (!vm.isReaderChromeHidden || isSnapshot) && !vm.openTabs.isEmpty
        #else
        let showTabStrip = (!vm.isReaderChromeHidden || isSnapshot) && vm.openTabs.count > 1
        #endif

        VStack(spacing: 0) {
            if showTabStrip {
                openTabsStrip(chromeBg: chromeBg, chromeFg: chromeFg)
            }

            if (!vm.isReaderChromeHidden || isSnapshot) && vm.activeTabIsQuickOpen {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(ReaderPalette.accent)
                    Text("Quick Open · local file")
                        .font(.system(size: 11.5))
                        .foregroundStyle(chromeFg.opacity(0.75))
                    Spacer()
                    if vm.isServerConnected {
                        Button {
                            Task { await vm.sendActiveDocumentToHomeInbox() }
                        } label: {
                            #if os(macOS)
                            Label(vm.isSendingToInbox ? "Sending…" : "Send to Phone", systemImage: "iphone.and.arrow.forward")
                            #else
                            Label(vm.isSendingToInbox ? "Sending…" : "Sync to Mac", systemImage: "laptopcomputer.and.arrow.down")
                            #endif
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ReaderPalette.cohortGreen)
                        .buttonStyle(.plain)
                        .disabled(vm.isSendingToInbox)
                    }
                    Button {
                        Task { await vm.promoteActiveQuickOpenToLibrary() }
                    } label: {
                        Text("Save to Library")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(ReaderPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(ReaderPalette.surface.opacity(0.85))
                Divider()
            }

            if !vm.isReaderChromeHidden || isSnapshot {
                // Top Reader Bar
                HStack(spacing: 6) {
                    Button {
                        ReaderHaptics.selection()
                        vm.cancelActiveOpen()
                        vm.selectedTab = .shelf
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Library")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(ReaderPalette.accent)
                        .padding(.vertical, 4)
                        .padding(.trailing, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Library")

                    Button {
                        vm.activeSheet = .toc
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(chromeFg)
                            .padding(5)
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
                    .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)

                    if vm.activeBook != nil {
                        if isPDFActive {
                            Button {
                                ReaderHaptics.selection()
                                vm.togglePDFAutoCrop()
                            } label: {
                                Image(systemName: "crop")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(vm.pdfAutoCropEnabled ? ReaderPalette.accent : chromeFg)
                                    .padding(5)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Crop Margins")
                            .help("Trim wide PDF margins")

                            if isSnapshot {
                                Image(systemName: vm.pdfAppearance.symbol)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(vm.pdfAppearance == .auto ? chromeFg : ReaderPalette.accent)
                                    .padding(5)
                            } else {
                                Menu {
                                    Section("Paper Appearance") {
                                        ForEach(PDFPaperAppearance.allCases, id: \.self) { mode in
                                            Button {
                                                ReaderHaptics.selection()
                                                vm.setPDFAppearance(mode)
                                            } label: {
                                                if vm.pdfAppearance == mode {
                                                    Label(mode.label, systemImage: "checkmark")
                                                } else {
                                                    Label(mode.label, systemImage: mode.symbol)
                                                }
                                            }
                                        }
                                    }
                                    #if os(macOS)
                                    Section("Zoom & Layout") {
                                        Button {
                                            ReaderHaptics.selection()
                                            vm.togglePDFTwoUpMode()
                                        } label: {
                                            Label("Two-Page Spread", systemImage: vm.pdfTwoUpMode ? "checkmark" : "book")
                                        }
                                        Button { vm.zoomInPDF() } label: {
                                            Label("Zoom In", systemImage: "plus.magnifyingglass")
                                        }
                                        Button { vm.zoomOutPDF() } label: {
                                            Label("Zoom Out", systemImage: "minus.magnifyingglass")
                                        }
                                        Button { vm.resetPDFZoom() } label: {
                                            Label("Fit Page", systemImage: "arrow.up.left.and.arrow.down.right")
                                        }
                                    }
                                    #endif
                                    Section("Navigation & Sync") {
                                        Button {
                                            vm.tocSegment = 0
                                            vm.tocShowsPDFThumbnails = true
                                            vm.activeSheet = .toc
                                        } label: {
                                            Label("Go to Page & Thumbnails…", systemImage: "square.grid.2x2")
                                        }
                                        if vm.isServerConnected {
                                            Button {
                                                Task { await vm.sendActiveDocumentToHomeInbox() }
                                            } label: {
                                                #if os(macOS)
                                                Label("Send to Phone", systemImage: "iphone.and.arrow.forward")
                                                #else
                                                Label("Sync to Mac", systemImage: "laptopcomputer.and.arrow.down")
                                                #endif
                                            }
                                            .disabled(vm.isSendingToInbox)
                                        }
                                    }
                                } label: {
                                    Image(systemName: vm.pdfAppearance.symbol)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(vm.pdfAppearance == .auto ? chromeFg : ReaderPalette.accent)
                                        .padding(5)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .accessibilityLabel("PDF Paper Theme & Zoom")
                                .help("Paper Theme & Zoom")
                            }

                            if vm.pdfDetectedColumnCount > 1 || vm.pdfTwoColumnMode {
                                Button {
                                    ReaderHaptics.selection()
                                    vm.pdfTwoColumnMode.toggle()
                                    vm.pdfTwoColumnStep = 0
                                } label: {
                                    Image(systemName: "rectangle.split.2x1")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(vm.pdfTwoColumnMode ? ReaderPalette.accent : chromeFg)
                                        .padding(5)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Column Flow")
                                .help("Step down academic columns")
                            }

                            Button {
                                ReaderHaptics.light()
                                vm.activeSheet = .pdfSign
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "signature")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(vm.pendingPDFStamps.isEmpty ? chromeFg : ReaderPalette.accent)
                                        .padding(6)
                                    if !vm.pendingPDFStamps.isEmpty {
                                        Circle()
                                            .fill(ReaderPalette.cohortGreen)
                                            .frame(width: 6, height: 6)
                                            .offset(x: -2, y: 2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Sign PDF")
                            .help("Sign & Stamp PDF")
                        } else {
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
                                vm.activeSheet = .typography
                            } label: {
                                Text("Aa")
                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                    .foregroundStyle(chromeFg)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Typography")
                        }

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
                        let chapterKey = "\(vm.activeBook?.id ?? ""):\(vm.activeEPUBSpineIndex):\(vm.activeNotes.count):\(vm.typography.readingFlow.rawValue)"
                        let typographyJS = EPUBHTMLComposer.typographyUpdateJS(typography: vm.typography, resolvedTheme: activeTheme)
                        let currentHref = epub.spineHrefs[safe: vm.activeEPUBSpineIndex] ?? ""
                        EPUBWebView(
                            html: vm.currentChapterHTML(resolvedTheme: activeTheme),
                            chapterKey: chapterKey,
                            typographyJS: typographyJS,
                            document: epub,
                            baseArchiveDir: (currentHref as NSString).deletingLastPathComponent,
                            currentChapterHref: currentHref,
                            chapterHighlights: vm.activeHighlights.filter { $0.spine == vm.activeEPUBSpineIndex },
                            onNoteTap: { noteId in
                                if let hit = vm.activeNotes.first(where: { $0.id == noteId }) {
                                    ReaderHaptics.selection()
                                    vm.activeSheet = .marginNote(hit)
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
                            onSelectSpine: { idx in
                                ReaderHaptics.selection()
                                Task { await vm.selectEPUBSpine(idx) }
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
                            },
                            onFootnoteTap: { path, frag in
                                ReaderHaptics.selection()
                                vm.previewEPUBFootnote(archivePath: path, fragment: frag)
                            }
                        )
                        .background(ReaderPalette.themeBackground(activeTheme))
                    }
                } else if let pdfURL = vm.activePDFURL {
                    if isSnapshot {
                        SnapshotPDFReaderBody(
                            book: vm.activeBook,
                            metadata: vm.activePDFMetadata,
                            pageIndex: vm.activePDFPageIndex,
                            stamps: vm.pendingPDFStamps.filter { $0.pageIndex == vm.activePDFPageIndex }
                        )
                    } else {
                        let resolvedPaper: PDFPaperAppearance = {
                            switch vm.pdfAppearance {
                            case .auto:
                                switch activeTheme {
                                case .ink: return .night
                                case .sepia: return .sepia
                                case .paper, .auto: return .original
                                }
                            default:
                                return vm.pdfAppearance
                            }
                        }()

                        ZStack {
                            PDFKitReaderView(
                                url: pdfURL,
                                pageIndex: vm.activePDFPageIndex,
                                theme: activeTheme,
                                autoCrop: vm.pdfAutoCropEnabled,
                                twoColumnMode: vm.pdfTwoColumnMode,
                                twoColumnStep: vm.pdfTwoColumnStep,
                                twoUpMode: vm.pdfTwoUpMode,
                                zoomScale: vm.pdfZoomScale,
                                highlights: vm.activeHighlights,
                                searchHighlightQuery: vm.activePDFSearchHighlight,
                                onPageChanged: { newPage in
                                    Task { await vm.selectPDFPage(newPage) }
                                },
                                onSelectionChanged: { text in
                                    vm.activeSelectionText = text
                                },
                                onColumnsDetected: { count in
                                    vm.pdfDetectedColumnCount = count
                                },
                                onPageFrameChanged: { frame in
                                    if abs(vm.activePDFPageFrame.minX - frame.minX) > 1
                                        || abs(vm.activePDFPageFrame.minY - frame.minY) > 1
                                        || abs(vm.activePDFPageFrame.width - frame.width) > 1
                                        || abs(vm.activePDFPageFrame.height - frame.height) > 1 {
                                        vm.activePDFPageFrame = frame
                                    }
                                },
                                onCenterTap: {
                                    ReaderHaptics.light()
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        vm.isReaderChromeHidden.toggle()
                                    }
                                }
                            )
                            .modifier(PDFPaperAppearanceModifier(appearance: resolvedPaper))

                            let pageStamps = vm.pendingPDFStamps.filter { $0.pageIndex == vm.activePDFPageIndex }
                            if !pageStamps.isEmpty {
                                PDFStampOverlayView(vm: vm, stamps: pageStamps)
                            }
                        }
                    }
                } else if let book = vm.activeBook {
                    if vm.openingBookId == book.id {
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Opening \(book.title)")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                                .foregroundStyle(ReaderPalette.label)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(book.shortCitation)
                                .font(.system(size: 12.5))
                                .foregroundStyle(ReaderPalette.secondary)
                            if book.bytes > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: book.bytes, countStyle: .file))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(ReaderPalette.secondary)
                            }
                            Button {
                                vm.cancelActiveOpen()
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(ReaderPalette.label)
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(book.title)
                                .font(.system(size: 18, weight: .semibold, design: .serif))
                                .foregroundStyle(ReaderPalette.label)
                            Text(book.shortCitation)
                                .font(.system(size: 13))
                                .foregroundStyle(ReaderPalette.secondary)
                            Text(book.summary.isEmpty ? "Offline copy is not downloaded yet." : book.summary)
                                .font(.system(size: 14))
                                .foregroundStyle(ReaderPalette.label)
                            if let cid = book.canonicalId {
                                Text(cid)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(ReaderPalette.accent)
                            }
                            HStack(spacing: 10) {
                                if book.epubURL != nil || book.openAccessURL != nil || book.source == .homeServer {
                                    Button {
                                        Task { await vm.openBook(book) }
                                    } label: {
                                        Text("Download & Read")
                                            .font(.system(size: 13, weight: .semibold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(ReaderPalette.accent, in: RoundedRectangle(cornerRadius: 7))
                                            .foregroundStyle(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button {
                                    vm.selectedTab = .shelf
                                } label: {
                                    Text("Back to Library")
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                                        .foregroundStyle(ReaderPalette.label)
                                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
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
                } else if vm.activePDFURL != nil && !vm.pendingPDFStamps.isEmpty && !isSnapshot {
                    PDFSigningActionBar(vm: vm)
                        .padding(.bottom, 12)
                } else if vm.activePDFURL != nil && !vm.pdfJumpBackStack.isEmpty && !isSnapshot {
                    HStack(spacing: 8) {
                        if let backPage = vm.pdfJumpBackStack.last {
                            Button {
                                ReaderHaptics.selection()
                                Task { await vm.jumpBackInPDF() }
                            } label: {
                                Label("Back to p. \(backPage + 1)", systemImage: "arrow.uturn.backward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ReaderPalette.label)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(ReaderPalette.surface, in: Capsule())
                                    .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        if let fwdPage = vm.pdfJumpForwardStack.last {
                            Button {
                                ReaderHaptics.selection()
                                Task { await vm.jumpForwardInPDF() }
                            } label: {
                                Label("p. \(fwdPage + 1)", systemImage: "arrow.uturn.forward")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(ReaderPalette.surface, in: Capsule())
                                    .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .shadow(radius: 4, y: 2)
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
                            Label("Controls", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(chromeFg)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(chromeBg.opacity(0.94), in: Capsule())
                                .overlay(Capsule().stroke(chromeFg.opacity(0.22), lineWidth: 1))
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
                    if let scrubIdx = vm.scrubChapterTarget {
                        Text(epub.chapter(at: scrubIdx)?.title ?? "Chapter \(scrubIdx + 1)")
                            .font(.system(size: 11.5, weight: .medium, design: .serif))
                            .foregroundStyle(chromeFg)
                            .lineLimit(1)
                    }
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
                            vm.activeSheet = .toc
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
                            Task {
                                if vm.pdfTwoColumnMode && vm.pdfDetectedColumnCount >= 2 {
                                    await vm.stepPDFColumn(delta: -1)
                                } else {
                                    await vm.selectPDFPage(vm.activePDFPageIndex - 1)
                                }
                            }
                        } label: {
                            Label("Prev", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(chromeFg)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.activePDFPageIndex <= 0 && (!vm.pdfTwoColumnMode || vm.pdfTwoColumnStep == 0))

                        Spacer()

                        Button {
                            vm.activeSheet = .toc
                        } label: {
                            let colBadge = (vm.pdfTwoColumnMode && vm.pdfDetectedColumnCount >= 2) ? " · Col \(vm.pdfTwoColumnStep + 1)/2" : ""
                            Text("Page \(displayIdx + 1)/\(total)\(colBadge) · \(vm.activeBook?.progressPercent ?? 0)%")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(chromeFg.opacity(0.68))
                                .monospacedDigit()
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            ReaderHaptics.selection()
                            Task {
                                if vm.pdfTwoColumnMode && vm.pdfDetectedColumnCount >= 2 {
                                    await vm.stepPDFColumn(delta: 1)
                                } else {
                                    await vm.selectPDFPage(vm.activePDFPageIndex + 1)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Next")
                                Image(systemName: "chevron.right")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(chromeFg)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.activePDFPageIndex + 1 >= meta.pageCount && (!vm.pdfTwoColumnMode || vm.pdfTwoColumnStep == 1))
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

    private func openTabsStrip(chromeBg: Color, chromeFg: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(vm.openTabs) { tab in
                    let active = vm.activeBook?.id == tab.id
                    HStack(spacing: 5) {
                        Button {
                            Task { await vm.selectTab(id: tab.id) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tab.book.format == .epub ? "book.closed" : "doc.text")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(active ? ReaderPalette.accent : chromeFg.opacity(0.65))
                                Text(tab.book.title)
                                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                                    .foregroundStyle(chromeFg)
                                    .lineLimit(1)
                                    .frame(maxWidth: 150, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await vm.closeTab(id: tab.id) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(chromeFg.opacity(0.5))
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close \(tab.book.title)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        active ? ReaderPalette.background : chromeBg.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(active ? ReaderPalette.hairline : Color.clear, lineWidth: 0.75)
                    )
                }

                #if os(macOS)
                Button {
                    vm.openExternalFileWithPanel()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(chromeFg.opacity(0.75))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open file in new tab")
                .help("Open PDF or EPUB (⌘O)")
                #endif
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(chromeBg.opacity(0.92))
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
                            vm.activeSheet = .marginNote(note)
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
    var stamps: [PDFStampPlacement] = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)

            VStack(alignment: .leading, spacing: 10) {
                Text(metadata?.title ?? book?.title ?? "PDF")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.14))
                Text("Page \(pageIndex + 1) / \(max(1, metadata?.pageCount ?? 1))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color(red: 0.42, green: 0.44, blue: 0.48))
                Divider()
                if let front = metadata?.frontMatterText, !front.isEmpty {
                    Text(front)
                        .font(.system(size: 12.5, design: .serif))
                        .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.22))
                        .lineSpacing(3)
                }
                Spacer()
            }
            .padding(20)

            if !stamps.isEmpty {
                GeometryReader { geo in
                    ForEach(stamps) { stamp in
                        let rect = CGRect(
                            x: stamp.normalizedRect.x * geo.size.width,
                            y: stamp.normalizedRect.y * geo.size.height,
                            width: stamp.normalizedRect.width * geo.size.width,
                            height: stamp.normalizedRect.height * geo.size.height
                        )
                        SignatureVectorPreview(kind: stamp.kind)
                            .frame(width: rect.width, height: rect.height)
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .foregroundStyle(ReaderPalette.accent)
                            )
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFPaperAppearanceModifier: ViewModifier {
    let appearance: PDFPaperAppearance

    func body(content: Content) -> some View {
        switch appearance {
        case .original, .auto:
            content
        case .sepia:
            content
                .overlay {
                    Color(red: 0.96, green: 0.90, blue: 0.77)
                        .blendMode(.multiply)
                        .allowsHitTesting(false)
                }
        case .night:
            content
                .colorInvert()
                .hueRotation(.degrees(180))
                .contrast(0.94)
        }
    }
}

private struct PDFStampOverlayView: View {
    @Bindable var vm: ReaderViewModel
    let stamps: [PDFStampPlacement]

    var body: some View {
        GeometryReader { geo in
            let pageFrame: CGRect = {
                let pf = vm.activePDFPageFrame
                if pf.width > 40 && pf.height > 40 {
                    return pf
                }
                return CGRect(origin: .zero, size: geo.size)
            }()

            ZStack(alignment: .topLeading) {
                ForEach(stamps) { stamp in
                    let w = max(44, stamp.normalizedRect.width * pageFrame.width)
                    let h = max(24, stamp.normalizedRect.height * pageFrame.height)
                    let cx = pageFrame.minX + stamp.normalizedRect.x * pageFrame.width + w * 0.5
                    let cy = pageFrame.minY + stamp.normalizedRect.y * pageFrame.height + h * 0.5
                    let selected = vm.selectedStampId == stamp.id

                    ZStack {
                        SignatureVectorPreview(kind: stamp.kind)
                            .frame(width: w, height: h)
                            .padding(4)
                            .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        selected ? ReaderPalette.accent : ReaderPalette.hairline,
                                        style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [4, 3])
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.selectedStampId = stamp.id
                            }
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        let origin = vm.stampDragOriginRect ?? stamp.normalizedRect
                                        if vm.stampDragOriginRect == nil {
                                            vm.stampDragOriginRect = origin
                                            vm.selectedStampId = stamp.id
                                        }
                                        let dx = value.translation.width / max(1, pageFrame.width)
                                        let dy = value.translation.height / max(1, pageFrame.height)
                                        var updated = origin
                                        updated.x = origin.x + dx
                                        updated.y = origin.y + dy
                                        vm.updatePendingStamp(id: stamp.id, normalizedRect: updated)
                                    }
                                    .onEnded { _ in
                                        vm.stampDragOriginRect = nil
                                    }
                            )

                        if selected {
                            Button {
                                vm.removePendingStamp(id: stamp.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(ReaderPalette.label, ReaderPalette.background)
                            }
                            .buttonStyle(.plain)
                            .offset(x: w * 0.5 + 4, y: -h * 0.5 - 4)

                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(ReaderPalette.accent, in: Circle())
                                .offset(x: w * 0.5 + 4, y: h * 0.5 + 4)
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let origin = vm.stampResizeOriginRect ?? stamp.normalizedRect
                                            if vm.stampResizeOriginRect == nil {
                                                vm.stampResizeOriginRect = origin
                                            }
                                            let dw = value.translation.width / max(1, pageFrame.width)
                                            let dh = value.translation.height / max(1, pageFrame.height)
                                            var updated = origin
                                            updated.width = origin.width + dw
                                            updated.height = origin.height + dh
                                            vm.updatePendingStamp(id: stamp.id, normalizedRect: updated)
                                        }
                                        .onEnded { _ in
                                            vm.stampResizeOriginRect = nil
                                        }
                                )
                        }
                    }
                    .position(x: cx, y: cy)
                }
            }
        }
    }
}

private struct PDFSigningActionBar: View {
    @Bindable var vm: ReaderViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                vm.activeSheet = .pdfSign
            } label: {
                Label("Stamp", systemImage: "signature")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReaderPalette.label)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 14)

            Button {
                vm.placeQuickTextStamp(PDFSignatureSheet.todayFormatted())
            } label: {
                Label("Date", systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ReaderPalette.label)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 14)

            Button {
                vm.clearPendingStamps()
            } label: {
                Text("Clear")
                    .font(.system(size: 12))
                    .foregroundStyle(ReaderPalette.secondary)
            }
            .buttonStyle(.plain)

            if vm.isServerConnected {
                Divider().frame(height: 14)

                Button {
                    Task {
                        if let data = await vm.prepareSignedPDFExport() {
                            await vm.sendActiveDocumentToHomeInbox(
                                overrideData: data,
                                overrideFilename: vm.exportedSignedFilename
                            )
                            vm.clearPendingStamps()
                        }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReaderPalette.accent)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSendingToInbox)
                .accessibilityLabel("Flatten and send signed PDF to Home Inbox")
                .help("Flatten & send signed PDF to Home Inbox")
            }

            Divider().frame(height: 14)

            Button {
                Task {
                    #if os(macOS)
                    await vm.saveSignedPDFWithPanel()
                    #else
                    if await vm.prepareSignedPDFExport() != nil {
                        vm.isExportingSignedPDF = true
                    }
                    #endif
                }
            } label: {
                Label("Save Signed PDF", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ReaderPalette.cohortGreen, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ReaderPalette.surface, in: Capsule())
        .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 1))
        .shadow(radius: 6, y: 2)
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
    let currentChapterHref: String
    let chapterHighlights: [ReadingHighlight]
    let onNoteTap: (String) -> Void
    let onProgress: (Double, Int) -> Void
    let onSelection: (String) -> Void
    let onSelectSpine: (Int) -> Void
    let onZoneTap: (String) -> Void
    let onFootnoteTap: (String, String) -> Void

    func makeCoordinator() -> EPUBWebCoordinator {
        EPUBWebCoordinator(
            document: document,
            currentChapterHref: currentChapterHref,
            onNoteTap: onNoteTap,
            onProgress: onProgress,
            onSelection: onSelection,
            onSelectSpine: onSelectSpine,
            onZoneTap: onZoneTap,
            onFootnoteTap: onFootnoteTap
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "cohortbook")
        config.userContentController.add(context.coordinator, name: "cohortReader")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.currentChapterHref = currentChapterHref
        context.coordinator.onNoteTap = onNoteTap
        context.coordinator.onProgress = onProgress
        context.coordinator.onSelection = onSelection
        context.coordinator.onSelectSpine = onSelectSpine
        context.coordinator.onZoneTap = onZoneTap
        context.coordinator.onFootnoteTap = onFootnoteTap
        let currentHighlightIds = Set(chapterHighlights.map(\.id))
        if context.coordinator.lastChapterKey != chapterKey {
            context.coordinator.lastChapterKey = chapterKey
            context.coordinator.lastTypographyJS = typographyJS
            context.coordinator.lastHighlightIds = currentHighlightIds
            let base = baseArchiveDir.isEmpty ? URL(string: "cohortbook://local/") : URL(string: "cohortbook://local/\(baseArchiveDir)/")
            web.loadHTMLString(html, baseURL: base)
        } else {
            if context.coordinator.lastTypographyJS != typographyJS {
                context.coordinator.lastTypographyJS = typographyJS
                web.evaluateJavaScript(typographyJS, completionHandler: nil)
            }
            if context.coordinator.lastHighlightIds != currentHighlightIds {
                if context.coordinator.lastHighlightIds.isSubset(of: currentHighlightIds) {
                    let addedIds = currentHighlightIds.subtracting(context.coordinator.lastHighlightIds)
                    for hl in chapterHighlights where addedIds.contains(hl.id) {
                        if let encoded = try? JSONEncoder().encode([hl.quote]),
                           let arrStr = String(data: encoded, encoding: .utf8) {
                            web.evaluateJavaScript("window.__cohortAddHighlight && window.__cohortAddHighlight(\(arrStr)[0]);", completionHandler: nil)
                        }
                    }
                    context.coordinator.lastHighlightIds = currentHighlightIds
                } else {
                    context.coordinator.lastHighlightIds = currentHighlightIds
                    let base = baseArchiveDir.isEmpty ? URL(string: "cohortbook://local/") : URL(string: "cohortbook://local/\(baseArchiveDir)/")
                    web.loadHTMLString(html, baseURL: base)
                }
            }
        }
    }
}

private struct PDFKitReaderView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int
    let theme: ReaderTheme
    let autoCrop: Bool
    let twoColumnMode: Bool
    let twoColumnStep: Int
    let twoUpMode: Bool
    let zoomScale: Double
    let highlights: [ReadingHighlight]
    let searchHighlightQuery: String?
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (String) -> Void
    let onColumnsDetected: (Int) -> Void
    let onPageFrameChanged: (CGRect) -> Void
    let onCenterTap: () -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(
            onPageChanged: onPageChanged,
            onSelectionChanged: onSelectionChanged,
            onColumnsDetected: onColumnsDetected,
            onPageFrameChanged: onPageFrameChanged,
            onCenterTap: onCenterTap
        )
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = (twoUpMode && !twoColumnMode) ? .twoUpContinuous : .singlePageContinuous
        view.backgroundColor = UIColor(ReaderPalette.themeBackground(theme))
        view.document = PDFDocument(url: url)
        view.delegate = context.coordinator
        context.coordinator.observe(view)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(PDFViewCoordinator.handleCenterTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onCenterTap = onCenterTap
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onColumnsDetected = onColumnsDetected
        context.coordinator.onPageFrameChanged = onPageFrameChanged
        view.backgroundColor = UIColor(ReaderPalette.themeBackground(theme))
        context.coordinator.syncDocumentState(
            on: view,
            url: url,
            pageIndex: pageIndex,
            autoCrop: autoCrop,
            twoColumnMode: twoColumnMode,
            twoColumnStep: twoColumnStep,
            twoUpMode: twoUpMode,
            zoomScale: zoomScale,
            highlights: highlights,
            searchQuery: searchHighlightQuery
        )
    }
}
#elseif canImport(AppKit)
private struct EPUBWebView: NSViewRepresentable {
    let html: String
    let chapterKey: String
    let typographyJS: String
    let document: EPUBDocument
    let baseArchiveDir: String
    let currentChapterHref: String
    let chapterHighlights: [ReadingHighlight]
    let onNoteTap: (String) -> Void
    let onProgress: (Double, Int) -> Void
    let onSelection: (String) -> Void
    let onSelectSpine: (Int) -> Void
    let onZoneTap: (String) -> Void
    let onFootnoteTap: (String, String) -> Void

    func makeCoordinator() -> EPUBWebCoordinator {
        EPUBWebCoordinator(
            document: document,
            currentChapterHref: currentChapterHref,
            onNoteTap: onNoteTap,
            onProgress: onProgress,
            onSelection: onSelection,
            onSelectSpine: onSelectSpine,
            onZoneTap: onZoneTap,
            onFootnoteTap: onFootnoteTap
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "cohortbook")
        config.userContentController.add(context.coordinator, name: "cohortReader")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.currentChapterHref = currentChapterHref
        context.coordinator.onNoteTap = onNoteTap
        context.coordinator.onProgress = onProgress
        context.coordinator.onSelection = onSelection
        context.coordinator.onSelectSpine = onSelectSpine
        context.coordinator.onZoneTap = onZoneTap
        context.coordinator.onFootnoteTap = onFootnoteTap
        let currentHighlightIds = Set(chapterHighlights.map(\.id))
        if context.coordinator.lastChapterKey != chapterKey {
            context.coordinator.lastChapterKey = chapterKey
            context.coordinator.lastTypographyJS = typographyJS
            context.coordinator.lastHighlightIds = currentHighlightIds
            let base = baseArchiveDir.isEmpty ? URL(string: "cohortbook://local/") : URL(string: "cohortbook://local/\(baseArchiveDir)/")
            web.loadHTMLString(html, baseURL: base)
        } else {
            if context.coordinator.lastTypographyJS != typographyJS {
                context.coordinator.lastTypographyJS = typographyJS
                web.evaluateJavaScript(typographyJS, completionHandler: nil)
            }
            if context.coordinator.lastHighlightIds != currentHighlightIds {
                if context.coordinator.lastHighlightIds.isSubset(of: currentHighlightIds) {
                    let addedIds = currentHighlightIds.subtracting(context.coordinator.lastHighlightIds)
                    for hl in chapterHighlights where addedIds.contains(hl.id) {
                        if let encoded = try? JSONEncoder().encode([hl.quote]),
                           let arrStr = String(data: encoded, encoding: .utf8) {
                            web.evaluateJavaScript("window.__cohortAddHighlight && window.__cohortAddHighlight(\(arrStr)[0]);", completionHandler: nil)
                        }
                    }
                    context.coordinator.lastHighlightIds = currentHighlightIds
                } else {
                    context.coordinator.lastHighlightIds = currentHighlightIds
                    let base = baseArchiveDir.isEmpty ? URL(string: "cohortbook://local/") : URL(string: "cohortbook://local/\(baseArchiveDir)/")
                    web.loadHTMLString(html, baseURL: base)
                }
            }
        }
    }
}

private struct PDFKitReaderView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int
    let theme: ReaderTheme
    let autoCrop: Bool
    let twoColumnMode: Bool
    let twoColumnStep: Int
    let twoUpMode: Bool
    let zoomScale: Double
    let highlights: [ReadingHighlight]
    let searchHighlightQuery: String?
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (String) -> Void
    let onColumnsDetected: (Int) -> Void
    let onPageFrameChanged: (CGRect) -> Void
    let onCenterTap: () -> Void

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(
            onPageChanged: onPageChanged,
            onSelectionChanged: onSelectionChanged,
            onColumnsDetected: onColumnsDetected,
            onPageFrameChanged: onPageFrameChanged,
            onCenterTap: onCenterTap
        )
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = (twoUpMode && !twoColumnMode) ? .twoUpContinuous : .singlePageContinuous
        view.backgroundColor = NSColor(ReaderPalette.themeBackground(theme))
        view.document = PDFDocument(url: url)
        view.delegate = context.coordinator
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onCenterTap = onCenterTap
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onColumnsDetected = onColumnsDetected
        context.coordinator.onPageFrameChanged = onPageFrameChanged
        view.backgroundColor = NSColor(ReaderPalette.themeBackground(theme))
        context.coordinator.syncDocumentState(
            on: view,
            url: url,
            pageIndex: pageIndex,
            autoCrop: autoCrop,
            twoColumnMode: twoColumnMode,
            twoColumnStep: twoColumnStep,
            twoUpMode: twoUpMode,
            zoomScale: zoomScale,
            highlights: highlights,
            searchQuery: searchHighlightQuery
        )
    }
}
#endif

@MainActor
private final class EPUBWebCoordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
    var document: EPUBDocument
    var currentChapterHref: String
    var lastChapterKey: String = ""
    var lastTypographyJS: String = ""
    var lastHighlightIds: Set<String> = []
    var onNoteTap: (String) -> Void
    var onProgress: (Double, Int) -> Void
    var onSelection: (String) -> Void
    var onSelectSpine: (Int) -> Void
    var onZoneTap: (String) -> Void
    var onFootnoteTap: (String, String) -> Void

    init(
        document: EPUBDocument,
        currentChapterHref: String,
        onNoteTap: @escaping (String) -> Void,
        onProgress: @escaping (Double, Int) -> Void,
        onSelection: @escaping (String) -> Void,
        onSelectSpine: @escaping (Int) -> Void,
        onZoneTap: @escaping (String) -> Void,
        onFootnoteTap: @escaping (String, String) -> Void
    ) {
        self.document = document
        self.currentChapterHref = currentChapterHref
        self.onNoteTap = onNoteTap
        self.onProgress = onProgress
        self.onSelection = onSelection
        self.onSelectSpine = onSelectSpine
        self.onZoneTap = onZoneTap
        self.onFootnoteTap = onFootnoteTap
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .linkActivated {
            guard let url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "cohortbook" {
                var clean = url.path
                while clean.hasPrefix("/") { clean.removeFirst() }
                let baseArchivePath = (clean.components(separatedBy: "#").first ?? clean).removingPercentEncoding ?? clean
                if let frag = url.fragment, !frag.isEmpty {
                    let targetArchive = (baseArchivePath.isEmpty || baseArchivePath.hasSuffix("/")) ? currentChapterHref : baseArchivePath
                    let fragLow = frag.lowercased()
                    let looksLikeFootnote = ["fn", "ftn", "note", "endnote", "foot", "ref", "cit", "bib"].contains { fragLow.contains($0) }
                    let isSameChapterAnchor = (baseArchivePath.isEmpty || baseArchivePath.hasSuffix("/") || targetArchive == currentChapterHref)
                    if looksLikeFootnote || targetArchive != currentChapterHref {
                        if document.extractFootnotePreview(archivePath: targetArchive, fragmentId: frag) != nil {
                            onFootnoteTap(targetArchive, frag)
                            decisionHandler(.cancel)
                            return
                        }
                    }
                    if isSameChapterAnchor {
                        decisionHandler(.allow)
                        return
                    }
                }
                let isDirFragment = (clean.isEmpty || clean.hasSuffix("/")) && url.fragment != nil
                if isDirFragment {
                    decisionHandler(.allow)
                    return
                }
                clean = baseArchivePath
                if let exactIdx = document.spineHrefs.firstIndex(where: { $0 == clean }) {
                    onSelectSpine(exactIdx)
                    decisionHandler(.cancel)
                    return
                }
                let filename = (clean as NSString).lastPathComponent
                if !filename.isEmpty,
                   let suffixIdx = document.spineHrefs.firstIndex(where: { ($0 as NSString).lastPathComponent == filename }) {
                    onSelectSpine(suffixIdx)
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.cancel)
                return
            }
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                #if canImport(UIKit)
                UIApplication.shared.open(url)
                #elseif canImport(AppKit)
                NSWorkspace.shared.open(url)
                #endif
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
            return
        }

        if url == nil || url?.scheme == "cohortbook" || url?.scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
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
private final class PDFViewCoordinator: NSObject, PDFViewDelegate {
    let onPageChanged: (Int) -> Void
    var onSelectionChanged: (String) -> Void
    var onColumnsDetected: (Int) -> Void
    var onPageFrameChanged: (CGRect) -> Void
    var onCenterTap: () -> Void
    private weak var pdfView: PDFView?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    private var currentURL: URL?
    private var cachedCropURL: URL?
    private var cachedCropInsets: PDFCropInsets?
    private var appliedCropState: Bool?
    private var lastHighlightKey: String = ""
    private var lastSearchQuery: String = ""
    private var lastReportedSelection: String = ""
    private var lastZoomScale: Double = 1.0
    private var lastColumnKey: String = ""

    init(
        onPageChanged: @escaping (Int) -> Void,
        onSelectionChanged: @escaping (String) -> Void,
        onColumnsDetected: @escaping (Int) -> Void,
        onPageFrameChanged: @escaping (CGRect) -> Void,
        onCenterTap: @escaping () -> Void
    ) {
        self.onPageChanged = onPageChanged
        self.onSelectionChanged = onSelectionChanged
        self.onColumnsDetected = onColumnsDetected
        self.onPageFrameChanged = onPageFrameChanged
        self.onCenterTap = onCenterTap
    }

    func observe(_ pdfView: PDFView) {
        self.pdfView = pdfView
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(forName: Notification.Name.PDFViewPageChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                Task { @MainActor in
                    guard let self, let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return }
                    let idx = doc.index(for: page)
                    if idx != NSNotFound {
                        self.onPageChanged(idx)
                    }
                    let cols = PDFColumnDetector.detectColumns(on: page)
                    self.onColumnsDetected(cols.count)
                    self.emitPageFrame(for: pdfView)
                }
            }
        )
        observers.append(
            nc.addObserver(forName: Notification.Name.PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                Task { @MainActor in
                    guard let self, let pdfView else { return }
                    self.emitPageFrame(for: pdfView)
                }
            }
        )
        observers.append(
            nc.addObserver(forName: Notification.Name.PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                Task { @MainActor in
                    guard let self, let pdfView else { return }
                    let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text != self.lastReportedSelection {
                        self.lastReportedSelection = text
                        self.onSelectionChanged(text)
                    }
                }
            }
        )
    }

    func syncDocumentState(
        on view: PDFView,
        url: URL,
        pageIndex: Int,
        autoCrop: Bool,
        twoColumnMode: Bool,
        twoColumnStep: Int,
        twoUpMode: Bool,
        zoomScale: Double,
        highlights: [ReadingHighlight],
        searchQuery: String?
    ) {
        let desiredDisplayMode: PDFDisplayMode = (twoUpMode && !twoColumnMode) ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != desiredDisplayMode {
            view.displayMode = desiredDisplayMode
        }
        if currentURL != url || view.document == nil {
            currentURL = url
            cachedCropURL = nil
            cachedCropInsets = nil
            appliedCropState = nil
            lastHighlightKey = ""
            lastSearchQuery = ""
            lastZoomScale = 1.0
            lastColumnKey = ""
            view.document = PDFDocument(url: url)
        }

        guard let doc = view.document else { return }

        if cachedCropURL != url {
            cachedCropURL = url
            cachedCropInsets = PDFCropAnalyzer.computeDocumentCropInsets(for: doc)
            appliedCropState = nil
        }

        if appliedCropState != autoCrop {
            appliedCropState = autoCrop
            PDFCropAnalyzer.applyCrop(autoCrop ? cachedCropInsets : nil, to: doc)
            view.layoutDocumentView()
        }

        let hlKey = "\(highlights.count):\(highlights.first?.id ?? ""):\(highlights.last?.id ?? "")"
        if lastHighlightKey != hlKey {
            lastHighlightKey = hlKey
            applyInMemoryHighlights(highlights, to: doc)
        }

        let cleanQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if lastSearchQuery != cleanQuery {
            lastSearchQuery = cleanQuery
            if cleanQuery.count >= 2 {
                let hits = doc.findString(cleanQuery, withOptions: .caseInsensitive)
                view.highlightedSelections = Array(hits.prefix(40))
            } else {
                view.highlightedSelections = nil
            }
        }

        if pageIndex >= 0, pageIndex < doc.pageCount,
           let target = doc.page(at: pageIndex),
           view.currentPage != target {
            view.go(to: target)
        }

        if let currentPage = view.currentPage {
            let cols = PDFColumnDetector.detectColumns(on: currentPage)
            onColumnsDetected(cols.count)

            let colKey = "\(twoColumnMode):\(twoColumnStep):\(pageIndex):\(cols.count)"
            if twoColumnMode && cols.count >= 2 {
                if lastColumnKey != colKey {
                    lastColumnKey = colKey
                    let colRect = cols[min(max(0, twoColumnStep), cols.count - 1)]
                    view.autoScales = false
                    let targetScale = max(view.minScaleFactor, min(view.maxScaleFactor, (view.bounds.width * 0.92) / max(120, colRect.width)))
                    if targetScale.isFinite && targetScale > 0 {
                        view.scaleFactor = targetScale
                    }
                    view.go(to: CGRect(x: colRect.minX, y: max(colRect.minY, colRect.maxY - 24), width: colRect.width, height: 24), on: currentPage)
                }
            } else {
                if !lastColumnKey.isEmpty {
                    lastColumnKey = ""
                    view.autoScales = true
                }
                if abs(lastZoomScale - zoomScale) > 0.01 {
                    lastZoomScale = zoomScale
                    if abs(zoomScale - 1.0) < 0.01 {
                        view.autoScales = true
                    } else {
                        view.autoScales = false
                        let fit = max(0.2, view.scaleFactorForSizeToFit)
                        view.scaleFactor = fit * zoomScale
                    }
                }
            }
        }

        emitPageFrame(for: view)
    }

    private func applyInMemoryHighlights(_ highlights: [ReadingHighlight], to doc: PDFDocument) {
        let marker = "cohort-reader-highlight"
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for ann in page.annotations where ann.userName == marker {
                page.removeAnnotation(ann)
            }
        }
        guard !highlights.isEmpty else { return }
        for h in highlights {
            let quote = String(h.quote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
            guard quote.count >= 3 else { continue }
            if h.spine >= 0, h.spine < doc.pageCount, let page = doc.page(at: h.spine),
               let sel = page.document?.findString(quote, withOptions: .caseInsensitive).first(where: { $0.pages.contains(page) }) {
                for line in sel.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    ann.userName = marker
                    #if canImport(UIKit)
                    ann.color = UIColor.systemYellow.withAlphaComponent(0.36)
                    #elseif canImport(AppKit)
                    ann.color = NSColor.systemYellow.withAlphaComponent(0.36)
                    #endif
                    page.addAnnotation(ann)
                }
            }
        }
    }

    private func emitPageFrame(for view: PDFView) {
        guard let page = view.currentPage, view.bounds.width > 10, view.bounds.height > 10 else { return }
        let box = page.bounds(for: .cropBox)
        let converted = view.convert(box, from: page)
        #if canImport(AppKit)
        let topY = view.isFlipped ? converted.minY : (view.bounds.height - converted.maxY)
        let frame = CGRect(x: converted.minX, y: topY, width: converted.width, height: converted.height)
        #else
        let frame = converted
        #endif
        if frame.width > 20 && frame.height > 20 {
            onPageFrameChanged(frame)
        }
    }

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        Task { @MainActor in
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    #if canImport(UIKit)
    @objc func handleCenterTap(_ recognizer: UITapGestureRecognizer) {
        guard let pdfView else { return }
        guard pdfView.currentSelection == nil else { return }
        let width = max(1, pdfView.bounds.width)
        let ratio = recognizer.location(in: pdfView).x / width
        if ratio >= 0.20 && ratio <= 0.80 {
            onCenterTap()
        }
    }
    #endif

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

#if canImport(UIKit)
extension PDFViewCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
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

struct TOCSheet: View {
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
                        TextField(vm.activePDFURL != nil ? "Search inside PDF" : "Search inside book", text: $vm.tocSearchQuery)
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

                if vm.tocSegment == 0 && vm.activeEPUB == nil,
                   let meta = vm.activePDFMetadata {
                    HStack(spacing: 8) {
                        Text("Go to page")
                            .font(.system(size: 12))
                            .foregroundStyle(ReaderPalette.secondary)
                        TextField("1-\(max(1, meta.pageCount))", text: $vm.pdfThumbnailPageInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .onSubmit {
                                if let p = Int(vm.pdfThumbnailPageInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                                   p >= 1, p <= meta.pageCount {
                                    Task {
                                        await vm.selectPDFPage(p - 1, recordJump: true)
                                        dismiss()
                                    }
                                }
                            }
                        Button("Go") {
                            if let p = Int(vm.pdfThumbnailPageInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                               p >= 1, p <= meta.pageCount {
                                Task {
                                    await vm.selectPDFPage(p - 1, recordJump: true)
                                    dismiss()
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.bordered)

                        Spacer()

                        if !meta.outline.isEmpty {
                            HStack(spacing: 4) {
                                Button {
                                    vm.tocShowsPDFThumbnails = false
                                } label: {
                                    Text("Outline")
                                        .font(.system(size: 11.5, weight: !vm.tocShowsPDFThumbnails ? .semibold : .medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(!vm.tocShowsPDFThumbnails ? ReaderPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .foregroundStyle(!vm.tocShowsPDFThumbnails ? .white : ReaderPalette.label)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    vm.tocShowsPDFThumbnails = true
                                } label: {
                                    Text("Pages")
                                        .font(.system(size: 11.5, weight: vm.tocShowsPDFThumbnails ? .semibold : .medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(vm.tocShowsPDFThumbnails ? ReaderPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .foregroundStyle(vm.tocShowsPDFThumbnails ? .white : ReaderPalette.label)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(2)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                if vm.tocSegment == 0 && vm.activeEPUB == nil,
                   let meta = vm.activePDFMetadata,
                   let pdfURL = vm.activePDFURL,
                   vm.tocShowsPDFThumbnails || meta.outline.isEmpty {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 94), spacing: 10)],
                            spacing: 12
                        ) {
                            ForEach(0..<meta.pageCount, id: \.self) { idx in
                                PDFPageThumbnailTile(
                                    url: pdfURL,
                                    pageIndex: idx,
                                    isCurrentPage: idx == vm.activePDFPageIndex
                                ) {
                                    ReaderHaptics.selection()
                                    Task {
                                        await vm.selectPDFPage(idx, recordJump: true)
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .padding(14)
                    }
                    .background(ReaderPalette.background)
                } else {
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
                                                if vm.activePDFURL != nil {
                                                    await vm.selectPDFPage(h.spine, recordJump: true)
                                                } else {
                                                    await vm.selectEPUBSpine(h.spine)
                                                }
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
                                            vm.transitionSheet(to: .marginNote(note))
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
                            Text(vm.activePDFURL != nil ? "Type at least 2 characters to search PDF pages." : "Type at least 2 characters to search chapters.")
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
                                        if vm.activePDFURL != nil {
                                            await vm.selectPDFPage(hit.spineIndex, recordJump: true)
                                        } else {
                                            await vm.selectEPUBSpine(hit.spineIndex)
                                        }
                                        dismiss()
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(hit.chapterTitle)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(ReaderPalette.accent)
                                            Spacer()
                                            Text(vm.activePDFURL != nil ? "p.\(hit.spineIndex + 1)" : "Ch \(hit.spineIndex + 1)")
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
            }
            .navigationTitle(vm.tocSegment == 0 ? "Contents" : (vm.tocSegment == 1 ? "Notes & Highlights" : (vm.activePDFURL != nil ? "Find in PDF" : "Find in Book")))
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

                HStack(spacing: 10) {
                    Text("Flow")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.label)
                        .frame(width: 58, alignment: .leading)
                    segmentedStrip(
                        options: EPUBReadingFlow.allCases,
                        selected: typography.readingFlow,
                        label: \.rawValue
                    ) { next in
                        ReaderHaptics.selection()
                        typography.readingFlow = next
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

@Observable
@MainActor
private final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()
    #if canImport(UIKit)
    private var images: [String: UIImage] = [:]
    #elseif canImport(AppKit)
    private var images: [String: NSImage] = [:]
    #endif
    private var inFlight: Set<String> = []
    private var order: [String] = []

    private func key(url: URL, pageIndex: Int) -> String {
        "\(url.path)#\(pageIndex)"
    }

    #if canImport(UIKit)
    func image(for url: URL, pageIndex: Int) -> UIImage? {
        images[key(url: url, pageIndex: pageIndex)]
    }
    #elseif canImport(AppKit)
    func image(for url: URL, pageIndex: Int) -> NSImage? {
        images[key(url: url, pageIndex: pageIndex)]
    }
    #endif

    func requestThumbnail(url: URL, pageIndex: Int) {
        let k = key(url: url, pageIndex: pageIndex)
        guard images[k] == nil, !inFlight.contains(k) else { return }
        inFlight.insert(k)
        Task {
            let imgData: Data? = await Task.detached(priority: .utility) {
                guard let doc = PDFDocument(url: url),
                      let page = doc.page(at: pageIndex) else { return nil }
                let thumb = page.thumbnail(of: CGSize(width: 160, height: 220), for: .cropBox)
                #if canImport(UIKit)
                return thumb.pngData()
                #elseif canImport(AppKit)
                guard let tiff = thumb.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff) else { return nil }
                return rep.representation(using: .png, properties: [:])
                #endif
            }.value
            self.inFlight.remove(k)
            guard let imgData else { return }
            #if canImport(UIKit)
            guard let img = UIImage(data: imgData) else { return }
            #elseif canImport(AppKit)
            guard let img = NSImage(data: imgData) else { return }
            #endif
            self.images[k] = img
            self.order.append(k)
            if self.order.count > 120 {
                let evict = self.order.removeFirst()
                self.images.removeValue(forKey: evict)
            }
        }
    }
}

private struct PDFPageThumbnailTile: View {
    let url: URL
    let pageIndex: Int
    let isCurrentPage: Bool
    let onSelect: () -> Void

    var body: some View {
        let cache = PDFThumbnailCache.shared
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                    if let cached = cache.image(for: url, pageIndex: pageIndex) {
                        #if canImport(UIKit)
                        Image(uiImage: cached)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(3)
                        #elseif canImport(AppKit)
                        Image(nsImage: cached)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(3)
                        #endif
                    } else {
                        Text("\(pageIndex + 1)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.gray.opacity(0.6))
                    }
                }
                .frame(height: 118)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isCurrentPage ? ReaderPalette.accent : ReaderPalette.hairline,
                            lineWidth: isCurrentPage ? 2 : 0.75
                        )
                )

                Text("p.\(pageIndex + 1)")
                    .font(.system(size: 11, weight: isCurrentPage ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isCurrentPage ? ReaderPalette.accent : ReaderPalette.secondary)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            cache.requestThumbnail(url: url, pageIndex: pageIndex)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
