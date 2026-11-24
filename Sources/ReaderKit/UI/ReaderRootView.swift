import ReaderModel
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct ReaderRootView: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    private var importTypes: [UTType] {
        var list: [UTType] = [.pdf]
        if let epub = UTType(filenameExtension: "epub") {
            list.append(epub)
        }
        return list
    }

    public var body: some View {
        Group {
            #if os(macOS)
            GeometryReader { geo in
                let focusHidden = vm.selectedTab == .read && vm.isReaderChromeHidden && (vm.activeEPUB != nil || vm.activePDFURL != nil) && !isSnapshot
                let showSidebar = geo.size.width >= 760 && !vm.isSidebarCollapsed && !focusHidden
                if showSidebar {
                    HStack(spacing: 0) {
                        desktopSidebarRail
                        Divider()
                        mainColumn(includeTabBar: false, isSidebarVisible: true)
                    }
                } else {
                    mainColumn(includeTabBar: geo.size.width < 760, isSidebarVisible: false)
                }
            }
            #else
            mainColumn(includeTabBar: true, isSidebarVisible: false)
            #endif
        }
        .background(ReaderPalette.background)
        .sheet(item: $vm.activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(vm: vm)
            case .marginNote(let note):
                MarginNoteSheet(
                    note: note,
                    serverURL: vm.serverURL,
                    bookId: vm.activeBook?.id ?? "",
                    onSendToCohort: {
                        vm.prepareCohortDraft(quote: "\(note.label) — \"\(note.anchor)\"\n\(note.note)")
                    }
                )
            case .discovery(let work):
                DiscoveryDetailSheet(vm: vm, work: work)
            case .cohortDraft(let draft):
                CohortDraftSheet(vm: vm, draft: draft)
            case .toc:
                TOCSheet(vm: vm)
            case .typography:
                TypographySheet(typography: $vm.typography, onChange: { vm.saveTypography() })
            case .pdfSign:
                PDFSignatureSheet(vm: vm)
            case .footnote(let preview):
                FootnotePreviewSheet(preview: preview, vm: vm)
            }
        }
        .userActivity(
            "md.cohort.reader.reading",
            element: vm.activeBook.map {
                "\($0.id):\(vm.activePDFURL != nil ? vm.activePDFPageIndex : vm.activeEPUBSpineIndex)"
            }
        ) { _, activity in
            guard !isSnapshot, let info = vm.currentHandoffUserInfo() else {
                activity.isEligibleForHandoff = false
                return
            }
            activity.title = vm.activeBook?.title ?? "Reading in Cohort Reader"
            activity.isEligibleForHandoff = true
            activity.userInfo = info
            activity.needsSave = true
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var handled = false
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.isFileURL else { return }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "pdf" || ext == "epub" else { return }
                    Task { @MainActor in
                        await vm.quickOpenExternalFile(from: url)
                    }
                }
            }
            return handled
        }
        .overlay {
            if vm.isCommandPalettePresented {
                CommandPaletteOverlay(vm: vm)
            } else if vm.isShortcutsHUDPresented {
                KeyboardShortcutsOverlay(vm: vm)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toastMessage, !isSnapshot {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(ReaderPalette.cohortGreen)
                    Text(toast)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ReaderPalette.label)
                        .lineLimit(2)
                    #if os(macOS)
                    if let savedPath = vm.lastSignedSavePath, toast.contains("Saved signed PDF") {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: savedPath)])
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReaderPalette.accent)
                        .buttonStyle(.plain)
                    }
                    #endif
                    Button {
                        vm.dismissToast()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ReaderPalette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss notification")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.14), radius: 8, y: 3)
                .padding(.bottom, 20)
                .padding(.horizontal, 16)
            }
        }
        .background(
            Color.clear
                .fileImporter(
                    isPresented: $vm.isImporterPresented,
                    allowedContentTypes: importTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let first = urls.first {
                        Task { await vm.importLocalFile(from: first) }
                    }
                }
                .fileExporter(
                    isPresented: $vm.isExportingSignedPDF,
                    document: SignedPDFFileDocument(data: vm.exportedSignedPDFData ?? Data()),
                    contentType: .pdf,
                    defaultFilename: vm.exportedSignedFilename
                ) { result in
                    if case .success(let url) = result {
                        vm.lastSignedSavePath = url.path
                        vm.showToast("Saved signed PDF: \(url.lastPathComponent)")
                        vm.clearPendingStamps()
                    }
                }
        )
    }

    private func mainColumn(includeTabBar: Bool, isSidebarVisible: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                switch vm.selectedTab {
                case .shelf:
                    ShelfView(vm: vm, onImportTap: { vm.requestFileImport() })
                case .read:
                    ReaderPaneView(vm: vm, isSidebarVisible: isSidebarVisible)
                case .map:
                    ManifoldMapView(vm: vm)
                case .search:
                    SearchLibraryView(vm: vm)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()

            if let err = vm.bannerError, !isSnapshot {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.tvAmber)
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ReaderPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        vm.bannerError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ReaderPalette.secondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(ReaderPalette.surface)
            }

            if includeTabBar && !(vm.selectedTab == .read && vm.isReaderChromeHidden && (vm.activeEPUB != nil || vm.activePDFURL != nil) && !isSnapshot) {
                Divider()
                tabBar
            }
        }
    }

    #if os(macOS)
    private var desktopSidebarRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ReaderPalette.accent)
                Text("Cohort Reader")
                    .font(.system(size: 13.5, weight: .semibold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Button {
                    vm.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ReaderPalette.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Sidebar")
                .help("Hide Sidebar (⌘\\)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Button {
                vm.openCommandPalette()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ReaderPalette.secondary)
                    Text("Quick Open…")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.secondary)
                    Spacer()
                    KeycapBadge("⌘K")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(ReaderPalette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help("Command Palette (⌘K)")
            .padding(.bottom, 4)

            ForEach(Array(ReaderTab.allCases.enumerated()), id: \.element) { idx, tab in
                let isSelected = vm.selectedTab == tab
                Button {
                    vm.selectedTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .frame(width: 17)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        Spacer()
                        KeycapBadge("⌘\(idx + 1)")
                    }
                    .foregroundStyle(isSelected ? ReaderPalette.accent : ReaderPalette.label)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6.5)
                    .background(
                        isSelected ? ReaderPalette.accent.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tab.rawValue) (⌘\(idx + 1))")
            }

            Divider()
                .padding(.vertical, 5)

            Button {
                vm.openExternalFileWithPanel()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 12.5))
                        .frame(width: 17)
                    Text("Open File…")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    KeycapBadge("⌘O")
                }
                .foregroundStyle(ReaderPalette.label)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(ReaderPalette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help("Open PDF or EPUB (⌘O)")

            if !vm.openTabs.isEmpty {
                Divider()
                    .padding(.vertical, 5)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(vm.openTabs.prefix(5).enumerated()), id: \.element.id) { idx, tab in
                        let active = vm.activeBook?.id == tab.id
                        HStack(spacing: 6) {
                            Button {
                                Task { await vm.selectTab(id: tab.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(active ? ReaderPalette.accent : ReaderPalette.secondary.opacity(0.35))
                                        .frame(width: 5.5, height: 5.5)
                                    Text(tab.book.title)
                                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                                        .foregroundStyle(active ? ReaderPalette.label : ReaderPalette.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(tab.book.title) (⌥⌘\(idx + 1))")

                            Button {
                                Task { await vm.closeTab(id: tab.id) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(ReaderPalette.secondary.opacity(0.65))
                                    .padding(3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close \(tab.book.title)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            active ? ReaderPalette.background.opacity(0.8) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                }
            }

            Spacer()

            Divider()

            HStack(spacing: 6) {
                Button {
                    vm.activeSheet = .settings
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(vm.isServerConnected ? ReaderPalette.cohortGreen : ReaderPalette.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(vm.isServerConnected ? "Home Sync" : "Settings")
                            .font(.system(size: 12))
                            .foregroundStyle(ReaderPalette.secondary)
                            .lineLimit(1)
                        Spacer()
                        KeycapBadge("⌘,")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")

                Button {
                    vm.toggleShortcutsHUD()
                } label: {
                    KeycapBadge("?")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keyboard Shortcuts")
                .help("Keyboard Shortcuts (? or ⌘/)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: 222)
        .frame(maxHeight: .infinity)
        .background(ReaderPalette.surface)
    }
    #endif

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ReaderTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .background(ReaderPalette.surface)
    }

    private func tabButton(_ tab: ReaderTab) -> some View {
        let isSelected = vm.selectedTab == tab
        let fontWeight: Font.Weight = isSelected ? .semibold : .regular
        let color = isSelected ? ReaderPalette.accent : ReaderPalette.secondary
        return Button {
            vm.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16, weight: fontWeight))
                    .frame(height: 18)
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: fontWeight))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
    }
}

private struct FootnotePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: FootnotePreview
    @Bindable var vm: ReaderViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(preview.body)
                        .font(.system(size: 16, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
            .background(ReaderPalette.background)
            .navigationTitle(preview.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let doc = vm.activeEPUB {
                    let baseHref = preview.archivePath.components(separatedBy: "#").first ?? preview.archivePath
                    let baseName = (baseHref as NSString).lastPathComponent
                    if let targetIdx = doc.spineHrefs.firstIndex(where: { $0 == baseHref || ($0 as NSString).lastPathComponent == baseName }),
                       targetIdx != vm.activeEPUBSpineIndex {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Jump to Source") {
                                Task {
                                    await vm.selectEPUBSpine(targetIdx)
                                    dismiss()
                                }
                            }
                        }
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

private struct SignedPDFFileDocument: FileDocument, Sendable {
    static let readableContentTypes: [UTType] = [.pdf]
    static let writableContentTypes: [UTType] = [.pdf]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
