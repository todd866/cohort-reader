import ReaderKit
import ReaderStorage
import SwiftUI
#if canImport(AppKit)
import AppKit

@MainActor
private final class CohortAppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    static var onOpenURLs: (([URL]) -> Void)?
    static var onKeyEvent: ((UInt16, UInt, String?) -> Bool)?
    private nonisolated(unsafe) var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modRaw = event.modifierFlags.rawValue
            let chars = event.characters
            let handled = MainActor.assumeIsolated {
                Self.onKeyEvent?(keyCode, modRaw, chars) ?? false
            }
            return handled ? nil : event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

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
        CohortAppDelegate.onKeyEvent = { keyCode, modRaw, chars in
            Self.handleLocalKeyEvent(keyCode: keyCode, modifierRawValue: modRaw, characters: chars, vm: model)
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

    #if os(macOS)
    @MainActor
    private static func handleLocalKeyEvent(
        keyCode: UInt16,
        modifierRawValue: UInt,
        characters: String?,
        vm: ReaderViewModel
    ) -> Bool {
        let mods = NSEvent.ModifierFlags(rawValue: modifierRawValue).intersection([.command, .option, .control, .shift])

        // ⌃Tab / ⌃⇧Tab tab cycling
        if keyCode == 48 && mods.contains(.control) && !mods.contains(.command) && !mods.contains(.option) {
            Task { await vm.selectAdjacentTab(delta: mods.contains(.shift) ? -1 : 1) }
            return true
        }

        // Let menu bar .commands handle any Command/Option/Control combination
        if mods.contains(.command) || mods.contains(.option) || mods.contains(.control) {
            return false
        }

        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView || responder is NSTextField {
                return false
            }
            let clsName = NSStringFromClass(type(of: responder))
            if clsName.contains("WK") && vm.selectedTab == .read && vm.activeEPUB != nil {
                // WKWebView's own injected keydown handler dispatches EPUB single-key shortcuts
                return false
            }
        }

        let key: String?
        switch keyCode {
        case 53: key = "Escape"
        case 123: key = "ArrowLeft"
        case 124: key = "ArrowRight"
        case 125: key = "ArrowDown"
        case 126: key = "ArrowUp"
        case 36, 76: key = "Return"
        default: key = characters
        }
        guard let key, !key.isEmpty else { return false }
        return vm.handleSingleKeyCommand(key, shift: mods.contains(.shift))
    }
    #endif

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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    vm.transitionSheet(to: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("Quick Open / Command Palette…") {
                    vm.openCommandPalette()
                }
                .keyboardShortcut("k", modifiers: .command)

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

                ForEach(1...9, id: \.self) { tabNumber in
                    Button("Tab \(tabNumber)") {
                        Task { await vm.selectTabByNumber(tabNumber) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(tabNumber)")), modifiers: [.command, .option])
                    .disabled(tabNumber > vm.openTabs.count)
                }

                Divider()

                Button("Sync Home Library") {
                    Task { await vm.syncServerCatalog(silent: false) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(vm.serverURL.isEmpty)

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

            CommandGroup(replacing: .sidebar) {
                Button(vm.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    vm.toggleSidebar()
                }
                .keyboardShortcut("\\", modifiers: .command)
            }

            CommandMenu("Reader") {
                Button("Library") { vm.selectedTab = .shelf }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Read") { vm.selectedTab = .read }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Atlas") { vm.selectedTab = .map }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Search") {
                    vm.selectedTab = .search
                    vm.searchFocusToken += 1
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("Contents & Notes") {
                    vm.tocSegment = 0
                    vm.activeSheet = .toc
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(vm.activeBook == nil)

                Button("Typography & Flow…") {
                    vm.activeSheet = .typography
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(vm.activeEPUB == nil)

                Button("Find in Document") {
                    vm.openInlineFind()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(vm.activeBook == nil)

                Button(vm.isInlineFindPresented ? "Find Next" : "Go to Page or Chapter…") {
                    if vm.isInlineFindPresented {
                        vm.stepInlineFind(delta: 1)
                    } else {
                        vm.openGoToPage()
                    }
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(vm.activeBook == nil)

                Button("Find Previous") {
                    vm.stepInlineFind(delta: -1)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!vm.isInlineFindPresented)

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

                Button("Highlight Selection") {
                    let q = vm.activeSelectionText
                    Task { await vm.saveQuickHighlight(quote: q) }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(vm.activeSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Send Selection to Cohort") {
                    vm.prepareCohortDraft(quote: vm.activeSelectionText)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(vm.activeSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Divider()

                Button("Zoom In / Larger Text") { vm.increaseReadingScale() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(vm.activePDFURL == nil && vm.activeEPUB == nil)

                Button("Zoom Out / Smaller Text") { vm.decreaseReadingScale() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(vm.activePDFURL == nil && vm.activeEPUB == nil)

                Button("Fit Page / Reset Text Size") { vm.resetReadingScale() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(vm.activePDFURL == nil && vm.activeEPUB == nil)

                Divider()

                Button("Cycle Reading Theme") { vm.cycleActiveReadingTheme() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(vm.activeBook == nil)

                Button("Toggle EPUB Scroll / Pages") { vm.toggleEPUBReadingFlow() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(vm.activeEPUB == nil)

                Button("Toggle Two-Page Spread") { vm.togglePDFTwoUpMode() }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(vm.activePDFURL == nil)

                Button("Toggle Margin Crop") { vm.togglePDFAutoCrop() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
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

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    vm.toggleShortcutsHUD()
                }
                .keyboardShortcut("/", modifiers: .command)
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
