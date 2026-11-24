import ReaderKit
import ReaderStorage
import SwiftUI
#if canImport(AppKit)
import AppKit

@MainActor
private final class CohortAppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    static var onOpenURLs: (([URL]) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        if let handler = Self.onOpenURLs {
            handler(fileURLs)
        } else {
            Self.pendingURLs.append(contentsOf: fileURLs)
        }
    }
}
#endif

@main
struct CohortReaderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(CohortAppDelegate.self) private var appDelegate
    #endif
    @State private var vm: ReaderViewModel

    init() {
        let store = Self.makePersistentStore()
        let model = ReaderViewModel(store: store)
        #if os(macOS)
        CohortAppDelegate.onOpenURLs = { urls in
            model.noteExternalFileLaunch()
            Task { @MainActor in
                for url in urls {
                    await model.quickOpenExternalFile(from: url)
                }
            }
        }
        if !CohortAppDelegate.pendingURLs.isEmpty {
            let queued = CohortAppDelegate.pendingURLs
            CohortAppDelegate.pendingURLs.removeAll()
            model.noteExternalFileLaunch()
            Task { @MainActor in
                for url in queued {
                    await model.quickOpenExternalFile(from: url)
                }
            }
        }
        #endif
        _vm = State(initialValue: model)
    }

    private var rootContent: some View {
        ReaderRootView(vm: vm)
            .task {
                await vm.bootstrap(loadSampleBook: true)
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                vm.noteExternalFileLaunch()
                Task {
                    await vm.quickOpenExternalFile(from: url)
                }
            }
            .onContinueUserActivity("md.cohort.reader.reading") { activity in
                if let info = activity.userInfo {
                    Task { await vm.handleHandoffActivity(info) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await vm.syncOnForegroundIfStale() }
                } else {
                    Task { await vm.flushProgressOutbox() }
                }
            }
    }

    var body: some Scene {
        #if os(macOS)
        Window("Cohort Reader", id: "main") {
            rootContent
        }
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

                Button("Next Tab") {
                    Task { await vm.selectAdjacentTab(delta: 1) }
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(vm.openTabs.count < 2)

                Button("Previous Tab") {
                    Task { await vm.selectAdjacentTab(delta: -1) }
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(vm.openTabs.count < 2)

                Divider()

                Button("Send to Phone / Sync Inbox") {
                    Task { await vm.sendActiveDocumentToHomeInbox() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!vm.isServerConnected || vm.activeBook == nil || vm.isSendingToInbox)

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

                Button("Go to Page / Thumbnails…") {
                    vm.tocSegment = 0
                    vm.tocShowsPDFThumbnails = true
                    vm.activeSheet = .toc
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(vm.activePDFURL == nil)

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

                Button("Toggle Two-Page Spread") { vm.togglePDFTwoUpMode() }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Toggle Margin Crop") { vm.togglePDFAutoCrop() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Cycle PDF Paper Theme") { vm.cyclePDFAppearance() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Sign & Stamp PDF") { vm.activeSheet = .pdfSign }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Delete Selected Stamp") {
                    if let sid = vm.selectedStampId {
                        vm.removePendingStamp(id: sid)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(vm.selectedStampId == nil)

                Button("Toggle Focus Mode") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        vm.isReaderChromeHidden.toggle()
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(vm.activeBook == nil)
            }
        }
        #else
        WindowGroup {
            rootContent
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
