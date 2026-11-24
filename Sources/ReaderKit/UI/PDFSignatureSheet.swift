import PDFEngine
import ReaderModel
import SwiftUI

/// Lightweight FOSS signature pad, typed signature composer, and date/text stamp picker.
public struct PDFSignatureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    public var body: some View {
        if isSnapshot {
            sheetContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ReaderPalette.background)
        } else {
            NavigationStack {
                ScrollView {
                    sheetContent
                }
                .background(ReaderPalette.background)
                .navigationTitle("Sign & Stamp PDF")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isSnapshot {
                HStack {
                    Text("Sign & Stamp PDF")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                    Spacer()
                    Text("Close")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderPalette.accent)
                }
                Divider()
            }

            if !vm.savedSignatures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved signatures (tap to place)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReaderPalette.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.savedSignatures) { sig in
                                ZStack(alignment: .topTrailing) {
                                    Button {
                                        ReaderHaptics.selection()
                                        vm.placeSavedSignature(sig)
                                        dismiss()
                                    } label: {
                                        SignatureVectorPreview(
                                            kind: .signature(sig),
                                            color: nil
                                        )
                                        .frame(width: 112, height: 48)
                                        .padding(6)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)

                                    if !isSnapshot {
                                        Button {
                                            vm.deleteSavedSignature(id: sig.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(ReaderPalette.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .offset(x: 4, y: -4)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 64)
                }
            }

            HStack(spacing: 6) {
                modeTab(0, title: "Draw", systemImage: "scribble.variable")
                modeTab(1, title: "Type", systemImage: "textformat")
                modeTab(2, title: "Date & Text", systemImage: "calendar")
            }

            // Ink selector
            HStack(spacing: 8) {
                Text("Ink")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ReaderPalette.secondary)
                ForEach(SignatureInkColor.allCases, id: \.self) { ink in
                    let active = vm.signatureDraftInk == ink
                    Button {
                        vm.signatureDraftInk = ink
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(red: ink.rgb.r, green: ink.rgb.g, blue: ink.rgb.b))
                                .frame(width: 10, height: 10)
                            Text(ink.rawValue)
                                .font(.system(size: 12, weight: active ? .semibold : .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(active ? ReaderPalette.accent.opacity(0.14) : ReaderPalette.surface, in: Capsule())
                        .overlay(Capsule().stroke(active ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 1))
                        .foregroundStyle(ReaderPalette.label)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if vm.signatureDraftMode == 0 {
                drawSignaturePad
            } else if vm.signatureDraftMode == 1 {
                typeSignaturePad
            } else {
                dateAndTextPad
            }

            if vm.isServerConnected {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.icloud")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ReaderPalette.cohortGreen)
                    Text("Signatures synced with Home Library")
                        .font(.system(size: 11))
                        .foregroundStyle(ReaderPalette.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
    }

    private var drawSignaturePad: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 34)

                    if vm.signatureDraftStrokes.isEmpty && vm.signatureDraftCurrentStroke.isEmpty {
                        Text("Sign with finger, trackpad, or pencil")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.gray.opacity(0.65))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Canvas { ctx, size in
                        let c = vm.signatureDraftInk.rgb
                        let strokeColor = Color(red: c.r, green: c.g, blue: c.b)
                        var strokes = vm.signatureDraftStrokes
                        if !vm.signatureDraftCurrentStroke.isEmpty {
                            strokes.append(vm.signatureDraftCurrentStroke)
                        }
                        for stroke in strokes where !stroke.isEmpty {
                            let path = SignatureVectorPreview.bezierPath(for: stroke, in: size)
                            ctx.stroke(
                                path,
                                with: .color(strokeColor),
                                style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let nx = value.location.x / max(1, geo.size.width)
                            let ny = value.location.y / max(1, geo.size.height)
                            vm.signatureDraftCurrentStroke.append(SignaturePoint(x: nx, y: ny))
                        }
                        .onEnded { _ in
                            vm.commitDraftStroke()
                        }
                )
            }
            .frame(height: 155)

            HStack(spacing: 10) {
                Button {
                    vm.undoDraftStroke()
                } label: {
                    Text("Undo")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(vm.signatureDraftStrokes.isEmpty ? ReaderPalette.secondary : ReaderPalette.label)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(vm.signatureDraftStrokes.isEmpty)

                Button {
                    vm.clearDraftSignature()
                } label: {
                    Text("Clear")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle((vm.signatureDraftStrokes.isEmpty && vm.signatureDraftCurrentStroke.isEmpty) ? ReaderPalette.secondary : ReaderPalette.label)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(vm.signatureDraftStrokes.isEmpty && vm.signatureDraftCurrentStroke.isEmpty)

                Spacer()

                Button {
                    ReaderHaptics.selection()
                    vm.saveAndPlaceDraftSignature()
                    dismiss()
                } label: {
                    Text("Save & Place")
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            (vm.signatureDraftStrokes.isEmpty && vm.signatureDraftCurrentStroke.isEmpty)
                                ? ReaderPalette.secondary.opacity(0.35)
                                : ReaderPalette.accent,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.signatureDraftStrokes.isEmpty && vm.signatureDraftCurrentStroke.isEmpty)
            }
        }
    }

    private var typeSignaturePad: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Type your name or initials", text: $vm.signatureDraftTypedText)
                .textFieldStyle(.roundedBorder)

            let previewText = vm.signatureDraftTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                if previewText.isEmpty {
                    Text("Signature preview")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gray.opacity(0.6))
                } else {
                    Text(previewText)
                        .font(.custom("Georgia-Italic", size: 28))
                        .foregroundStyle(Color(
                            red: vm.signatureDraftInk.rgb.r,
                            green: vm.signatureDraftInk.rgb.g,
                            blue: vm.signatureDraftInk.rgb.b
                        ))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 12)
                }
            }
            .frame(height: 92)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 1))

            HStack {
                Spacer()
                Button {
                    ReaderHaptics.selection()
                    vm.saveAndPlaceDraftSignature()
                    dismiss()
                } label: {
                    Text("Save & Place")
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            previewText.isEmpty ? ReaderPalette.secondary.opacity(0.35) : ReaderPalette.accent,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(previewText.isEmpty)
            }
        }
    }

    private var dateAndTextPad: some View {
        let todayStr = Self.todayFormatted()
        let isoStr = Self.isoFormatted()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Quick stamps")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ReaderPalette.secondary)

            HStack(spacing: 8) {
                quickChip(todayStr)
                quickChip(isoStr)
                quickChip("✓")
                quickChip("✗")
            }

            Divider()

            Text("Custom text stamp")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ReaderPalette.secondary)

            HStack(spacing: 8) {
                TextField("Title, role, or short note", text: $vm.signatureDraftCustomText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    ReaderHaptics.selection()
                    vm.placeQuickTextStamp(vm.signatureDraftCustomText)
                    vm.signatureDraftCustomText = ""
                    dismiss()
                } label: {
                    Text("Place")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(ReaderPalette.accent, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.signatureDraftCustomText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func modeTab(_ index: Int, title: String, systemImage: String) -> some View {
        let selected = vm.signatureDraftMode == index
        return Button {
            ReaderHaptics.selection()
            vm.signatureDraftMode = index
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(selected ? ReaderPalette.accent : ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? .white : ReaderPalette.label)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func quickChip(_ text: String) -> some View {
        Button {
            ReaderHaptics.selection()
            vm.placeQuickTextStamp(text)
            dismiss()
        } label: {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ReaderPalette.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    public static func todayFormatted() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date())
    }

    public static func isoFormatted() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

/// Vector renderer shared between the saved-signatures tray and the live PDF page stamp overlay.
public struct SignatureVectorPreview: View {
    public let kind: PDFStampKind
    public var color: Color?

    public init(kind: PDFStampKind, color: Color? = nil) {
        self.kind = kind
        self.color = color
    }

    public var body: some View {
        let rgb = kind.inkColor.rgb
        let ink = color ?? Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        switch kind {
        case .signature(let sig):
            if !sig.strokes.isEmpty {
                GeometryReader { geo in
                    Path { path in
                        for stroke in sig.strokes where !stroke.isEmpty {
                            path.addPath(Self.bezierPath(for: stroke, in: geo.size))
                        }
                    }
                    .stroke(
                        ink,
                        style: StrokeStyle(
                            lineWidth: max(1.4, min(3.4, geo.size.height * 0.045)),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            } else {
                Text(sig.typedText ?? sig.label)
                    .font(.custom("Georgia-Italic", size: 22))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
            }
        case .text(let s, _):
            Text(s)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
    }

    public static func bezierPath(for stroke: [SignaturePoint], in size: CGSize) -> Path {
        var path = Path()
        guard let first = stroke.first else { return path }
        let pts = stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        path.move(to: pts[0])
        if pts.count == 1 {
            path.addEllipse(in: CGRect(x: pts[0].x - 1, y: pts[0].y - 1, width: 2, height: 2))
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let curr = pts[i]
            let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
            path.addQuadCurve(to: mid, control: prev)
        }
        if let last = pts.last {
            path.addLine(to: last)
        }
        _ = first
        return path
    }
}
