#if os(macOS)
import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFEngine
import PDFKit
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

        // 7. Typography
        try renderScenario("typography", targets: targets, outDir: outDir) {
            TypographySheet(typography: .constant(vm.typography), onChange: {})
        }

        // 8. Settings
        try renderScenario("settings", targets: targets, outDir: outDir) {
            SettingsSheet(vm: vm)
        }

        // 8b. Command Palette & Shortcuts HUD (desktop)
        vm.selectedTab = .shelf
        vm.openCommandPalette()
        try renderScenario("command-palette", targets: [("macos", CGSize(width: 1280, height: 800))], outDir: outDir) {
            ReaderRootView(vm: vm)
        }
        vm.closeCommandPalette()

        vm.isShortcutsHUDPresented = true
        try renderScenario("shortcuts-hud", targets: [("macos", CGSize(width: 1280, height: 800))], outDir: outDir) {
            ReaderRootView(vm: vm)
        }
        vm.isShortcutsHUDPresented = false

        // 9. PDF Reader + Placed Vector Stamp Preview (clean-room synthetic PDF)
        let tmpPDFURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohort-snapshot-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpPDFURL) }
        if buildSampleAcademicPDF(to: tmpPDFURL) {
            let sampleSig = SavedSignature(
                label: "M. Shelley",
                strokes: [[
                    SignaturePoint(x: 0.08, y: 0.65),
                    SignaturePoint(x: 0.22, y: 0.25),
                    SignaturePoint(x: 0.36, y: 0.68),
                    SignaturePoint(x: 0.55, y: 0.38),
                    SignaturePoint(x: 0.72, y: 0.55),
                    SignaturePoint(x: 0.90, y: 0.42),
                ]],
                inkColor: .navy,
                aspectRatio: 2.6
            )
            vm.savedSignatures = [sampleSig]
            vm.signatureDraftStrokes = sampleSig.strokes
            await vm.quickOpenExternalFile(from: tmpPDFURL)
            vm.pendingPDFStamps = [
                PDFStampPlacement(
                    pageIndex: 0,
                    normalizedRect: CodableRect(x: 0.22, y: 0.72, width: 0.34, height: 0.11),
                    kind: .signature(sampleSig)
                ),
            ]
            try renderScenario("read-pdf", targets: targets, outDir: outDir) {
                ReaderRootView(vm: vm)
            }

            // 10. Signature Pad Sheet
            try renderScenario("pdf-sign", targets: targets, outDir: outDir) {
                PDFSignatureSheet(vm: vm)
            }
        }

        print("Rendered Cohort Reader snapshots cleanly into \(outDir.path)")
    }

    private static func buildSampleAcademicPDF(to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        let lines = [
            "Lightweight Local-First Document Signatures",
            "Sample Research & Consent Agreement",
            "",
            "1. All parsing, margin trimming, and vector signature flattening",
            "occur locally using CoreGraphics and PDFKit with zero network calls.",
            "",
            "2. Original selectable text and vector fonts remain intact in the signed PDF.",
            "",
            "Participant Signature: _________________________________",
        ]
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Georgia" as CFString, 14, nil)
        let boldFont = CTFontCreateWithName("Georgia-Bold" as CFString, 18, nil)
        for (idx, lineText) in lines.enumerated() where !lineText.isEmpty {
            let f = idx == 0 ? boldFont : font
            let attr = NSAttributedString(
                string: lineText,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f]
            )
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 56, y: 710 - CGFloat(idx) * 28)
            CTLineDraw(ctLine, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return true
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
