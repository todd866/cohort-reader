import ReaderKit
import ReaderStorage
import SwiftUI

@main
struct CohortReaderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: ReaderViewModel

    init() {
        let store = Self.makePersistentStore()
        _vm = State(initialValue: ReaderViewModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ReaderRootView(vm: vm)
                .task {
                    await vm.bootstrap(loadSampleBook: true)
                }
                .onOpenURL { url in
                    Task {
                        if url.isFileURL {
                            await vm.quickOpenExternalFile(from: url)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        Task { await vm.flushProgressOutbox() }
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1140, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF or EPUB…") {
                    vm.openExternalFileWithPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Close Tab") {
                    if let activeId = vm.activeBook?.id {
                        Task { await vm.closeTab(id: activeId) }
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(vm.activeBook == nil)

                Divider()

                Button("Save Signed PDF…") {
                    Task { await vm.saveSignedPDFWithPanel() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(vm.activePDFURL == nil || vm.pendingPDFStamps.isEmpty)
            }

            CommandMenu("Reader") {
                Button("Library") { vm.selectedTab = .shelf }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Read") { vm.selectedTab = .read }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Atlas") { vm.selectedTab = .map }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Search") { vm.selectedTab = .search }
                    .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("Find in Document") {
                    vm.tocSegment = 2
                    vm.activeSheet = .toc
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(vm.activeBook == nil)

                Button("Jump Back in PDF") {
                    Task { await vm.jumpBackInPDF() }
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(vm.pdfJumpBackStack.isEmpty)

                Button("Jump Forward in PDF") {
                    Task { await vm.jumpForwardInPDF() }
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(vm.pdfJumpForwardStack.isEmpty)

                Divider()

                Button("Zoom In") { vm.zoomInPDF() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(vm.activePDFURL == nil)

                Button("Zoom Out") { vm.zoomOutPDF() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(vm.activePDFURL == nil)

                Button("Fit Page Width") { vm.resetPDFZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(vm.activePDFURL == nil)

                Divider()

                Button("Toggle Margin Crop") { vm.togglePDFAutoCrop() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Cycle PDF Paper Theme") { vm.cyclePDFAppearance() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Sign & Stamp PDF") { vm.activeSheet = .pdfSign }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Toggle Focus Mode") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        vm.isReaderChromeHidden.toggle()
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(vm.activeBook == nil)
            }
        }
        #endif
    }

    private static func makePersistentStore() -> ReaderStore {
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dbDir = appSupport.appendingPathComponent("CohortReader", isDirectory: true)
            let cacheRoot = docs.appendingPathComponent("CohortReaderCache", isDirectory: true)
            do {
                try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                let dbURL = dbDir.appendingPathComponent("cohort-reader.sqlite")
                return try ReaderStore(dbPath: dbURL.path, cacheRoot: cacheRoot)
            } catch {
                // Fall back to in-memory store only if sandbox directories fail.
            }
        }
        return (try? ReaderStore(dbPath: ":memory:"))!
    }
}
