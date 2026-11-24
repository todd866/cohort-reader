import ReaderModel
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Focus-Capable Text Input (Deterministic ViewModel-Only State)

struct InlineCommandTextField: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    let placeholder: String
    let text: String
    let fontSize: CGFloat
    let focusToken: Int
    let onTextChange: (String) -> Void
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    var onShiftSubmit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    var body: some View {
        if isSnapshot {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: fontSize))
                .foregroundStyle(text.isEmpty ? ReaderPalette.secondary : ReaderPalette.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        } else {
            PlatformInlineTextField(
                placeholder: placeholder,
                text: text,
                fontSize: fontSize,
                focusToken: focusToken,
                onTextChange: onTextChange,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onSubmit: onSubmit,
                onShiftSubmit: onShiftSubmit,
                onEscape: onEscape
            )
            .frame(height: fontSize + 10)
        }
    }
}

#if canImport(AppKit)
private struct PlatformInlineTextField: NSViewRepresentable {
    let placeholder: String
    let text: String
    let fontSize: CGFloat
    let focusToken: Int
    let onTextChange: (String) -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onSubmit: (() -> Void)?
    let onShiftSubmit: (() -> Void)?
    let onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: fontSize)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        context.coordinator.lastFocusToken = focusToken
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlatformInlineTextField
        var lastFocusToken: Int = 0

        init(_ parent: PlatformInlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                if let onMoveUp = parent.onMoveUp {
                    onMoveUp()
                    return true
                }
            case #selector(NSResponder.moveDown(_:)):
                if let onMoveDown = parent.onMoveDown {
                    onMoveDown()
                    return true
                }
            case #selector(NSResponder.insertNewline(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift, let onShiftSubmit = parent.onShiftSubmit {
                    onShiftSubmit()
                    return true
                }
                if let onSubmit = parent.onSubmit {
                    onSubmit()
                    return true
                }
            case #selector(NSResponder.cancelOperation(_:)):
                if let onEscape = parent.onEscape {
                    onEscape()
                    return true
                }
            default:
                break
            }
            return false
        }
    }
}
#elseif canImport(UIKit)
private struct PlatformInlineTextField: UIViewRepresentable {
    let placeholder: String
    let text: String
    let fontSize: CGFloat
    let focusToken: Int
    let onTextChange: (String) -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onSubmit: (() -> Void)?
    let onShiftSubmit: (() -> Void)?
    let onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.placeholder = placeholder
        field.font = .systemFont(ofSize: fontSize)
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .go
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        context.coordinator.lastFocusToken = focusToken
        DispatchQueue.main.async {
            field.becomeFirstResponder()
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text {
            field.text = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.becomeFirstResponder()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PlatformInlineTextField
        var lastFocusToken: Int = 0

        init(_ parent: PlatformInlineTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ sender: UITextField) {
            parent.onTextChange(sender.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit?()
            return true
        }
    }
}
#endif

// MARK: - Command Palette (⌘K)

public struct CommandPaletteOverlay: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let items = vm.commandPaletteItems()
        let activeIdx = items.isEmpty ? 0 : min(max(0, vm.commandPaletteSelectionIndex), items.count - 1)
        let displayed = isSnapshot ? Array(items.prefix(8)) : items

        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    vm.closeCommandPalette()
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ReaderPalette.accent)

                    InlineCommandTextField(
                        placeholder: "Jump to book, page, or command…",
                        text: vm.commandPaletteQuery,
                        fontSize: 14.5,
                        focusToken: vm.isCommandPalettePresented ? 1 : 0,
                        onTextChange: { next in
                            vm.commandPaletteQuery = next
                            vm.commandPaletteSelectionIndex = 0
                        },
                        onMoveUp: { vm.moveCommandPaletteSelection(delta: -1) },
                        onMoveDown: { vm.moveCommandPaletteSelection(delta: 1) },
                        onSubmit: { Task { await vm.executeSelectedCommandPaletteItem() } },
                        onEscape: { vm.closeCommandPalette() }
                    )

                    Button {
                        vm.closeCommandPalette()
                    } label: {
                        KeycapBadge("esc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close command palette")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(ReaderPalette.elevated)

                Divider()

                Group {
                    if displayed.isEmpty {
                        Text("No matching books or commands")
                            .font(.system(size: 13))
                            .foregroundStyle(ReaderPalette.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if isSnapshot {
                        rowsStack(items: displayed, activeIndex: activeIdx)
                    } else {
                        ScrollView {
                            rowsStack(items: displayed, activeIndex: activeIdx)
                        }
                        .frame(maxHeight: 336)
                    }
                }
                .background(ReaderPalette.background)

                Divider()

                HStack(spacing: 12) {
                    Text("↑↓ navigate")
                    Text("↩ execute")
                    Text("esc dismiss")
                    Spacer()
                    Text("\(items.count) items")
                        .monospacedDigit()
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(ReaderPalette.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(ReaderPalette.surface)
            }
            .frame(maxWidth: 540)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ReaderPalette.hairline, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.24), radius: 24, y: 12)
            .padding(.top, 56)
            .padding(.horizontal, 16)
        }
    }

    private func rowsStack(items: [CommandPaletteItem], activeIndex: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                let isSelected = idx == activeIndex
                Button {
                    Task { await vm.executeCommandPaletteItem(item) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(isSelected ? ReaderPalette.accent : ReaderPalette.secondary)
                            .frame(width: 20, alignment: .center)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(ReaderPalette.label)
                                .lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        if let sc = item.shortcut, !sc.isEmpty {
                            KeycapBadge(sc, emphasized: isSelected)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isSelected ? ReaderPalette.accent.opacity(0.11) : Color.clear)
                    .overlay(alignment: .leading) {
                        if isSelected {
                            Rectangle()
                                .fill(ReaderPalette.accent)
                                .frame(width: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Single-Screen Keycap Cheatsheet HUD (?)

public struct KeyboardShortcutsOverlay: View {
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    private struct Entry: Identifiable {
        var id: String { label }
        let label: String
        let keys: String
    }

    private var navEntries: [Entry] {
        [
            Entry(label: "Command Palette", keys: "⌘K"),
            Entry(label: "Find Inline", keys: "⌘F /"),
            Entry(label: "Next / Prev Hit", keys: "↩ ⇧↩"),
            Entry(label: "Go to Page / Ch", keys: ": ⌘G"),
            Entry(label: "Scroll / Step", keys: "j k ↑ ↓"),
            Entry(label: "Page / Chapter", keys: "h l ␣"),
            Entry(label: "Top / Bottom", keys: "g G"),
            Entry(label: "Jump Back / Fwd", keys: "⌘[ ⌘]"),
        ]
    }

    private var viewEntries: [Entry] {
        [
            Entry(label: "Zoom / Scale", keys: "⌘+ ⌘-"),
            Entry(label: "Reset Scale", keys: "⌘0"),
            Entry(label: "Cycle Theme", keys: "⌥⌘T t"),
            Entry(label: "EPUB Scroll/Pages", keys: "⌥⌘P p"),
            Entry(label: "Two-Page Spread", keys: "⌥⌘2 2"),
            Entry(label: "Crop Margins", keys: "⌥⌘C c"),
            Entry(label: "Contents", keys: "⌘T"),
            Entry(label: "Typography", keys: "⇧⌘T"),
            Entry(label: "Focus Mode", keys: "⌘. f"),
        ]
    }

    private var toolEntries: [Entry] {
        [
            Entry(label: "Switch Views", keys: "⌘1–4"),
            Entry(label: "Toggle Sidebar", keys: "⌘\\"),
            Entry(label: "Next / Prev Tab", keys: "⇧⌘[ ⇧⌘]"),
            Entry(label: "Jump Tab 1–9", keys: "⌥⌘1–9"),
            Entry(label: "Close Tab", keys: "⌘W"),
            Entry(label: "Open File", keys: "⌘O"),
            Entry(label: "Sign PDF", keys: "⌥⌘S s"),
            Entry(label: "Send to Inbox", keys: "⇧⌘U"),
            Entry(label: "Sync / Settings", keys: "⌘R ⌘,"),
        ]
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    vm.isShortcutsHUDPresented = false
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                    KeycapBadge("?")
                    KeycapBadge("⌘/")
                    Spacer()
                    Button {
                        vm.isShortcutsHUDPresented = false
                    } label: {
                        KeycapBadge("esc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close shortcuts")
                }

                Divider()

                GeometryReader { geo in
                    if geo.size.width >= 600 {
                        HStack(alignment: .top, spacing: 18) {
                            shortcutColumn(title: "Navigation", entries: navEntries)
                            Divider()
                            shortcutColumn(title: "Reading & View", entries: viewEntries)
                            Divider()
                            shortcutColumn(title: "Tabs & Tools", entries: toolEntries)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            shortcutColumn(title: "Navigation", entries: Array(navEntries.prefix(6)))
                            Divider()
                            shortcutColumn(title: "Reading & View", entries: Array(viewEntries.prefix(6)))
                        }
                    }
                }
                #if os(macOS)
                .frame(height: 236)
                #else
                .frame(height: 280)
                #endif
            }
            .padding(16)
            .frame(maxWidth: 700)
            .background(ReaderPalette.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ReaderPalette.hairline, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.24), radius: 24, y: 12)
            .padding(20)
        }
    }

    private func shortcutColumn(title: String, entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ReaderPalette.accent)
                .padding(.bottom, 2)

            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.label)
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderPalette.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    KeycapBadge(entry.keys)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Spatially Stable Floating Find & Go-To-Page Bars

struct InlineFindOverlay: View {
    @Bindable var vm: ReaderViewModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderPalette.accent)

            InlineCommandTextField(
                placeholder: "Find in document",
                text: vm.inlineFindQuery,
                fontSize: 12.5,
                focusToken: vm.isInlineFindPresented ? 1 : 0,
                onTextChange: { vm.updateInlineFindQuery($0) },
                onSubmit: { vm.stepInlineFind(delta: 1) },
                onShiftSubmit: { vm.stepInlineFind(delta: -1) },
                onEscape: { vm.closeInlineFind() }
            )

            if !vm.inlineFindQuery.isEmpty {
                let countText = vm.inlineFindTotalCount > 0
                    ? "\(vm.inlineFindActiveIndex)/\(vm.inlineFindTotalCount)"
                    : "0/0"
                Text(countText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ReaderPalette.secondary)
                    .monospacedDigit()
            }

            Button {
                vm.stepInlineFind(delta: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ReaderPalette.label)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous match")
            .help("Previous Match (⇧⌘G)")

            Button {
                vm.stepInlineFind(delta: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ReaderPalette.label)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next match")
            .help("Next Match (⌘G)")

            Button {
                vm.closeInlineFind()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ReaderPalette.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Find")
            .help("Close Find (Esc)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: 336)
        .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ReaderPalette.hairline, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
    }
}

struct InlineGoToPageOverlay: View {
    @Bindable var vm: ReaderViewModel

    var body: some View {
        let placeholder: String = {
            if let meta = vm.activePDFMetadata, vm.activePDFURL != nil {
                return "Page 1–\(max(1, meta.pageCount))"
            }
            if let doc = vm.activeEPUB {
                return "Chapter 1–\(max(1, doc.spineHrefs.count))"
            }
            return "Go to page"
        }()

        HStack(spacing: 7) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderPalette.accent)

            InlineCommandTextField(
                placeholder: placeholder,
                text: vm.goToPageQuery,
                fontSize: 12.5,
                focusToken: vm.isGoToPagePresented ? 1 : 0,
                onTextChange: { vm.goToPageQuery = $0 },
                onSubmit: { Task { await vm.submitGoToPage() } },
                onEscape: { vm.closeGoToPage() }
            )

            Button {
                Task { await vm.submitGoToPage() }
            } label: {
                KeycapBadge("↩", emphasized: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump")

            Button {
                vm.closeGoToPage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ReaderPalette.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: 248)
        .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ReaderPalette.hairline, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
    }
}
