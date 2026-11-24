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

            if !(vm.selectedTab == .read && vm.isReaderChromeHidden && (vm.activeEPUB != nil || vm.activePDFURL != nil) && !isSnapshot) {
                Divider()
                tabBar
            }
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
        )
    }

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
