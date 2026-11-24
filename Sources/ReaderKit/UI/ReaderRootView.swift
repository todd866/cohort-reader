import ReaderModel
import SwiftUI
import UniformTypeIdentifiers

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
                if geo.size.width >= 760 {
                    HStack(spacing: 0) {
                        if !(vm.selectedTab == .read && vm.isReaderChromeHidden && (vm.activeEPUB != nil || vm.activePDFURL != nil) && !isSnapshot) {
                            desktopSidebarRail
                            Divider()
                        }
                        mainColumn(includeTabBar: false)
                    }
                } else {
                    mainColumn(includeTabBar: true)
                }
            }
            #else
            mainColumn(includeTabBar: true)
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
                        vm.lastHandoffMessage = "Saved signed PDF: \(url.lastPathComponent)"
                        vm.clearPendingStamps()
                    }
                }
        )
    }

    private func mainColumn(includeTabBar: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                switch vm.selectedTab {
                case .shelf:
                    ShelfView(vm: vm, onImportTap: { vm.requestFileImport() })
                case .read:
                    ReaderPaneView(vm: vm)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ReaderPalette.accent)
                Text("Cohort Reader")
                    .font(.system(size: 13.5, weight: .semibold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ForEach(ReaderTab.allCases, id: \.self) { tab in
                let isSelected = vm.selectedTab == tab
                Button {
                    vm.selectedTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                            .frame(width: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(isSelected ? ReaderPalette.accent : ReaderPalette.label)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        isSelected ? ReaderPalette.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .padding(.vertical, 6)

            Button {
                vm.openExternalFileWithPanel()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 13))
                        .frame(width: 18)
                    Text("Open PDF…")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(ReaderPalette.label)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ReaderPalette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                vm.activeSheet = .settings
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(vm.isServerConnected ? ReaderPalette.cohortGreen : ReaderPalette.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(vm.isServerConnected ? "Home Connected" : "Settings")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: 176)
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
