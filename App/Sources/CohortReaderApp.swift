import ReaderKit
import ReaderStorage
import SwiftUI
#if canImport(AppKit)
import AppKit

@MainActor
private final class CohortAppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    static var onOpenURLs: (([URL]) -> Void)?
    static var onKeyEvent: ((UInt16, UInt, String?, String?) -> Bool)?
    private nonisolated(unsafe) var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modRaw = event.modifierFlags.rawValue
            let chars = event.characters
            let charsIgnoring = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                Self.onKeyEvent?(keyCode, modRaw, chars, charsIgnoring) ?? false
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
        CohortAppDelegate.onKeyEvent = { keyCode, modRaw, chars, charsIgnoring in
            Self.handleLocalKeyEvent(
                keyCode: keyCode,
                modifierRawValue: modRaw,
                characters: chars,
                charactersIgnoringModifiers: charsIgnoring,
                vm: model
            )
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
        charactersIgnoringModifiers: String?,
        vm: ReaderViewModel
    ) -> Bool {
        let mods = NSEvent.ModifierFlags(rawValue: modifierRawValue).intersection([.command, .option, .control, .shift])
        let hasCmd = mods.contains(.command)
        let hasOpt = mods.contains(.option)
        let hasCtrl = mods.contains(.control)
        let hasShift = mods.contains(.shift)

        // ⌃Tab / ⌃⇧Tab tab cycling
        if keyCode == 48 && hasCtrl && !hasCmd && !hasOpt {
            Task { await vm.selectAdjacentTab(delta: hasShift ? -1 : 1) }
            return true
        }

        let rawChar = (charactersIgnoringModifiers ?? characters ?? "").lowercased()

        // Direct ⌘ dispatch before WKWebView / PDFView responders swallow key equivalents.
        // Standard system/edit shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z/⌘Q/⌘H/⌘M/⌃⌘F) are intentionally untouched.
        if hasCmd && !hasCtrl {
            if !hasOpt {
                switch rawChar {
                case "k" where !hasShift:
                    vm.openCommandPalette()
                    return true
                case "f" where !hasShift:
                    vm.openInlineFind()
                    return true
                case "g":
                    if vm.isInlineFindPresented {
                        vm.stepInlineFind(delta: hasShift ? -1 : 1)
                        return true
                    } else if !hasShift && vm.activeBook != nil {
                        vm.openGoToPage()
                        return true
                    }
                case "=", "+" :
                    if vm.activePDFURL != nil || vm.activeEPUB != nil {
                        vm.increaseReadingScale()
                        return true
                    }
                case "-":
                    if vm.activePDFURL != nil || vm.activeEPUB != nil {
                        vm.decreaseReadingScale()
                        return true
                    }
                case "0":
                    if vm.activePDFURL != nil || vm.activeEPUB != nil {
                        vm.resetReadingScale()
                        return true
                    }
                case "\\":
                    vm.toggleSidebar()
                    return true
                case "/", "?":
                    vm.toggleShortcutsHUD()
                    return true
                case "1" where !hasShift:
                    vm.selectedTab = .shelf
                    return true
                case "2" where !hasShift:
                    vm.selectedTab = .read
                    return true
                case "3" where !hasShift:
                    vm.selectedTab = .map
                    return true
                case "4" where !hasShift:
                    vm.selectedTab = .search
                    vm.searchFocusToken += 1
                    return true
                case "[", "{" where hasShift:
                    if vm.openTabs.count >= 2 {
                        Task { await vm.selectAdjacentTab(delta: -1) }
                    }
                    return true
                case "]", "}" where hasShift:
                    if vm.openTabs.count >= 2 {
                        Task { await vm.selectAdjacentTab(delta: 1) }
                    }
                    return true
                case "[" where !hasShift:
                    if vm.activeEPUB != nil || vm.activePDFURL != nil {
                        Task { await vm.navigateBackOrPrevious() }
                        return true
                    }
                case "]" where !hasShift:
                    if vm.activeEPUB != nil || vm.activePDFURL != nil {
                        Task { await vm.navigateForwardOrNext() }
                        return true
                    }
                case "w" where !hasShift:
                    if let activeId = vm.activeBook?.id {
                        Task { await vm.closeTab(id: activeId) }
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                    return true
                case "," where !hasShift:
                    vm.transitionSheet(to: .settings)
                    return true
                case "." where !hasShift:
                    if vm.activeBook != nil {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            vm.isReaderChromeHidden.toggle()
                        }
                        return true
                    }
                case "o" where !hasShift:
                    vm.openExternalFileWithPanel()
                    return true
                case "t":
                    if hasShift {
                        if vm.activeEPUB != nil {
                            vm.transitionSheet(to: .typography)
                            return true
                        }
                    } else if vm.activeBook != nil {
                        vm.tocSegment = 0
                        vm.transitionSheet(to: .toc)
                        return true
                    }
                case "r" where !hasShift:
                    if !vm.serverURL.isEmpty {
                        Task { await vm.syncServerCatalog(silent: false) }
                        return true
                    }
                default:
                    // Numpad +, -, 0 keyCodes for scale shortcuts
                    if (keyCode == 69) && (vm.activePDFURL != nil || vm.activeEPUB != nil) {
                        vm.increaseReadingScale()
                        return true
                    }
                    if (keyCode == 27 || keyCode == 78) && (vm.activePDFURL != nil || vm.activeEPUB != nil) {
                        vm.decreaseReadingScale()
                        return true
                    }
                    if (keyCode == 29 || keyCode == 82) && (vm.activePDFURL != nil || vm.activeEPUB != nil) {
                        vm.resetReadingScale()
                        return true
                    }
                }
            } else if hasOpt && !hasShift {
                if (rawChar == "2" || keyCode == 19), vm.selectedTab == .read, vm.activePDFURL != nil, vm.openTabs.count < 2 {
                    vm.togglePDFTwoUpMode()
                    return true
                }
                if let tabNum = Self.optionDigitNumber(rawChar: rawChar, keyCode: keyCode) {
                    Task { await vm.selectTabByNumber(tabNum) }
                    return true
                }
                if rawChar == "t" || keyCode == 17 {
                    if vm.activeBook != nil {
                        vm.cycleActiveReadingTheme()
                        return true
                    }
                } else if rawChar == "p" || keyCode == 35 {
                    if vm.activeEPUB != nil {
                        vm.toggleEPUBReadingFlow()
                        return true
                    }
                } else if rawChar == "c" || keyCode == 8 {
                    if vm.activePDFURL != nil {
                        vm.togglePDFAutoCrop()
                        return true
                    }
                } else if rawChar == "s" || keyCode == 1 {
                    if vm.activePDFURL != nil {
                        vm.transitionSheet(to: .pdfSign)
                        return true
                    }
                }
            }
        }

        // Let menu bar .commands or AppKit handle any remaining Command/Option/Control combination
        if hasCmd || hasOpt || hasCtrl {
            return false
        }

        if keyCode == 53 && vm.isShortcutsHUDPresented {
            vm.isShortcutsHUDPresented = false
            return true
        }

        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView || responder is NSTextField {
                return false
            }
            if keyCode == 53 && vm.handleEscapeKey() {
                return true
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
        case 115: key = "Home"
        case 119: key = "End"
        case 116: key = "PageUp"
        case 121: key = "PageDown"
        case 51: key = "Backspace"
        case 117: key = "Delete"
        default: key = characters
        }
        guard let key, !key.isEmpty else { return false }
        return vm.handleSingleKeyCommand(key, shift: hasShift)
    }

    private static func optionDigitNumber(rawChar: String, keyCode: UInt16) -> Int? {
        if let n = Int(rawChar), (1...9).contains(n) {
            return n
        }
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
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
            sharedCommands
        }
        #else
        WindowGroup {
            rootContent
        }
        .commands {
            sharedCommands
        }
        #endif
    }

    @CommandsBuilder
    private var sharedCommands: some Commands {
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
                #if os(macOS)
                vm.openExternalFileWithPanel()
                #else
                vm.requestFileImport()
                #endif
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Close Tab") {
                if let activeId = vm.activeBook?.id {
                    Task { await vm.closeTab(id: activeId) }
                } else {
                    #if os(macOS)
                    NSApp.keyWindow?.performClose(nil)
                    #endif
                }
            }
            .keyboardShortcut("w", modifiers: .command)

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
                Task {
                    #if os(macOS)
                    await vm.saveSignedPDFWithPanel()
                    #else
                    if await vm.prepareSignedPDFExport() != nil {
                        vm.isExportingSignedPDF = true
                    }
                    #endif
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(vm.activePDFURL == nil || vm.pendingPDFStamps.isEmpty)
        }

        #if os(macOS)
        CommandGroup(replacing: .sidebar) {
            Button(vm.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                vm.toggleSidebar()
            }
            .keyboardShortcut("\\", modifiers: .command)
        }
        #endif

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

            Button("Find") {
                vm.openInlineFind()
            }
            .keyboardShortcut("f", modifiers: .command)

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

            Button("Previous Chapter / Jump Back") {
                Task { await vm.navigateBackOrPrevious() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(vm.activeEPUB == nil && vm.activePDFURL == nil)

            Button("Next Chapter / Jump Forward") {
                Task { await vm.navigateForwardOrNext() }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(vm.activeEPUB == nil && vm.activePDFURL == nil)

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
                .keyboardShortcut("=", modifiers: .command)
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
