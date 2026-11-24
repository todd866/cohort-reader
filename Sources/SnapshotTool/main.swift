#if os(macOS)
import AppKit
import Foundation
import ReaderKit
import ReaderModel
import ReaderStorage
import SwiftUI

@MainActor
enum SnapshotRunner {
    static func run() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./shots"
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let store = try ReaderStore(dbPath: ":memory:")
        let vm = ReaderViewModel(store: store)
        await vm.bootstrap(loadSampleBook: true, runNetworkSync: false)

        let targets: [(label: String, size: CGSize)] = [
            ("iphone", CGSize(width: 390, height: 844)),
            ("macos", CGSize(width: 1280, height: 800)),
        ]

        // 1. Library
        vm.selectedTab = .shelf
        try renderScenario("shelf", targets: targets, outDir: outDir) {
            ReaderRootView(vm: vm)
        }

        // 2. Read EPUB (Frankenstein + underlined margin note)
        vm.selectedTab = .read
        try renderScenario("read-epub", targets: targets, outDir: outDir) {
            ReaderRootView(vm: vm)
        }

        // 3. Margin Note Sheet
        if let note = ShowcaseCatalog.sampleMarginNotes.first {
            try renderScenario("read-margin-note", targets: targets, outDir: outDir) {
                MarginNoteSheet(note: note)
            }
        }

        // 4. Atlas
        vm.selectedTab = .map
        try renderScenario("map", targets: targets, outDir: outDir) {
            ReaderRootView(vm: vm)
        }

        // 5. Discovery / Source-It-Yourself Detail Sheet
        if let discWork = ShowcaseCatalog.works.first(where: { $0.workId == "isbn:9780300078152" }) {
            try renderScenario("discover-detail", targets: targets, outDir: outDir) {
                DiscoveryDetailSheet(vm: vm, work: discWork)
            }
        }

        // 6. Search
        vm.selectedTab = .search
        vm.searchQuery = "state"
        try renderScenario("search", targets: targets, outDir: outDir) {
            ReaderRootView(vm: vm)
        }

        // 7. Settings
        try renderScenario("settings", targets: targets, outDir: outDir) {
            SettingsSheet(vm: vm)
        }

        print("Rendered Cohort Reader snapshots cleanly into \(outDir.path)")
    }

    private static func renderScenario<V: View>(
        _ name: String,
        targets: [(label: String, size: CGSize)],
        outDir: URL,
        @ViewBuilder content: @escaping () -> V
    ) throws {
        for target in targets {
            for isDark in [false, true] {
                let themeLabel = isDark ? "dark" : "light"
                let fileURL = outDir.appendingPathComponent("\(name)-\(target.label)-\(themeLabel).png")
                try renderPNG(size: target.size, isDark: isDark, to: fileURL, content: content)
            }
        }
    }

    private static func renderPNG<V: View>(
        size: CGSize,
        isDark: Bool,
        to fileURL: URL,
        @ViewBuilder content: () -> V
    ) throws {
        guard let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) else {
            throw NSError(domain: "SnapshotTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing NSAppearance"])
        }

        var capturedData: Data?
        appearance.performAsCurrentDrawingAppearance {
            let root = content()
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, isDark ? .dark : .light)
                .environment(\.readerSnapshotMode, true)
            let renderer = ImageRenderer(content: root)
            renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
            renderer.scale = 2.0

            if let cgImage = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                capturedData = rep.representation(using: .png, properties: [:])
            }
        }

        guard let data = capturedData else {
            throw NSError(domain: "SnapshotTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to render \(fileURL.lastPathComponent)"])
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

try await SnapshotRunner.run()
#else
print("SnapshotTool is macOS-only.")
#endif
