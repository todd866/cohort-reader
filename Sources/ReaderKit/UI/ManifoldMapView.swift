import ManifoldClient
import ReaderModel
import SwiftUI

public struct ManifoldMapView: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let works = vm.manifoldWorks
        let selected = vm.selectedMapWork()
        let ranked = vm.rankedLensWorks()
        let activeMatch = vm.activeBook.flatMap { vm.manifoldWork(for: $0) }
        let isZoomedOrPanned = vm.mapZoom > 1.05 || abs(vm.mapPan.width) > 4 || abs(vm.mapPan.height) > 4

        VStack(spacing: 0) {
            // Clean Editorial Top Bar
            HStack(spacing: 8) {
                Text("Atlas")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                Spacer(minLength: 4)

                if isZoomedOrPanned {
                    Button {
                        ReaderHaptics.selection()
                        vm.mapZoom = 1.0
                        vm.mapPan = .zero
                    } label: {
                        Text("1:1")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ReaderPalette.accent)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset Atlas Zoom")
                    .help("Reset Atlas Zoom")
                }

                if let activeMatch {
                    Button {
                        ReaderHaptics.selection()
                        vm.focusWorkInAtlas(activeMatch)
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(vm.selectedMapWorkId == activeMatch.workId ? ReaderPalette.accent : ReaderPalette.label)
                            .frame(width: 30, height: 30)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Center on current book")
                    .help("Center on current book")
                }

                Button {
                    Task { await vm.refreshManifold() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(ReaderPalette.label)
                        .frame(width: 30, height: 30)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync Atlas")
                .help("Refresh Atlas (⌘R)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(ReaderPalette.background)

            // Lens Selector Strip
            Group {
                if isSnapshot {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .overlay(alignment: .leading) {
                            lensStripRow
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .clipped()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        lensStripRow
                    }
                }
            }
            .background(ReaderPalette.background)

            Divider()

            // Constellation Scatter Canvas
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Canvas { ctx, size in
                        let midX = size.width / 2 + vm.mapPan.width
                        let midY = size.height / 2 + vm.mapPan.height
                        let pad: CGFloat = 20
                        let scaleX = ((size.width / 2) - pad) * vm.mapZoom
                        let scaleY = ((size.height / 2) - pad) * vm.mapZoom

                        func point(for work: ManifoldReaderWork) -> CGPoint {
                            CGPoint(
                                x: midX + CGFloat(work.x) * scaleX,
                                y: midY - CGFloat(work.y) * scaleY
                            )
                        }

                        for frac in [0.45, 0.85] as [CGFloat] {
                            let rx = scaleX * frac
                            let ry = scaleY * frac
                            let ringRect = CGRect(x: midX - rx, y: midY - ry, width: rx * 2, height: ry * 2)
                            ctx.stroke(Path(ellipseIn: ringRect), with: .color(ReaderPalette.hairline.opacity(0.45)), lineWidth: 0.6)
                        }

                        var axes = Path()
                        axes.move(to: CGPoint(x: midX, y: pad))
                        axes.addLine(to: CGPoint(x: midX, y: size.height - pad))
                        axes.move(to: CGPoint(x: pad, y: midY))
                        axes.addLine(to: CGPoint(x: size.width - pad, y: midY))
                        ctx.stroke(axes, with: .color(ReaderPalette.hairline.opacity(0.75)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))

                        // Lens Sequence Trajectory through top 5 works
                        let topRanked = Array(ranked.prefix(5))
                        if topRanked.count >= 2 {
                            var lensPath = Path()
                            for (idx, rw) in topRanked.enumerated() {
                                let p = point(for: rw.work)
                                if idx == 0 { lensPath.move(to: p) } else { lensPath.addLine(to: p) }
                            }
                            ctx.stroke(
                                lensPath,
                                with: .color(ReaderPalette.accent.opacity(0.32)),
                                style: StrokeStyle(lineWidth: 1.15, dash: [3, 4])
                            )
                        }

                        let workById = Dictionary(uniqueKeysWithValues: works.map { ($0.workId, $0) })

                        if let selected {
                            let sp = point(for: selected)
                            for nb in selected.neighbours.prefix(5) {
                                if let target = workById[nb.workId] {
                                    let tp = point(for: target)
                                    var spoke = Path()
                                    spoke.move(to: sp)
                                    spoke.addLine(to: tp)
                                    ctx.stroke(spoke, with: .color(ReaderPalette.secondary.opacity(0.35)), lineWidth: 1)
                                }
                            }
                        }

                        for w in works {
                            let pt = point(for: w)
                            let isSel = selected?.workId == w.workId
                            let owned = vm.ownedBook(for: w)
                            let r: CGFloat = isSel ? 6 : 4
                            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)

                            if let owned {
                                let dotColor = owned.isOfflineCached ? ReaderPalette.cohortGreen : ReaderPalette.accent
                                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                            } else {
                                ctx.fill(Path(ellipseIn: rect), with: .color(ReaderPalette.tvAmber.opacity(0.24)))
                                ctx.stroke(Path(ellipseIn: rect), with: .color(ReaderPalette.tvAmber), lineWidth: 1.4)
                            }

                            if isSel {
                                let ring = CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20)
                                ctx.stroke(Path(ellipseIn: ring), with: .color(ReaderPalette.label), lineWidth: 1.5)
                            }
                        }

                        // Non-overlapping labels for selected work & up to 2 nearest neighbours
                        var placedBoxes: [CGRect] = []
                        func placeLabel(_ text: String, near nodePt: CGPoint, primary: Bool) {
                            let short = Self.shortCanvasTitle(text, maxChars: primary ? 24 : 18)
                            let font: Font = primary ? .system(size: 10, weight: .semibold) : .system(size: 9, weight: .medium)
                            let color = primary ? ReaderPalette.label : ReaderPalette.secondary
                            let resolved = ctx.resolve(Text(short).font(font).foregroundStyle(color))
                            let measured = resolved.measure(in: size)
                            let padX: CGFloat = primary ? 6 : 4
                            let padY: CGFloat = primary ? 2.5 : 1.5
                            let boxW = measured.width + padX * 2
                            let boxH = measured.height + padY * 2

                            let candidates: [CGPoint] = [
                                CGPoint(x: nodePt.x + 11, y: nodePt.y - boxH / 2),
                                CGPoint(x: nodePt.x - boxW - 11, y: nodePt.y - boxH / 2),
                                CGPoint(x: nodePt.x - boxW / 2, y: nodePt.y - boxH - 11),
                                CGPoint(x: nodePt.x - boxW / 2, y: nodePt.y + 11),
                            ]
                            for origin in candidates {
                                let box = CGRect(x: origin.x, y: origin.y, width: boxW, height: boxH)
                                guard box.minX >= 6, box.maxX <= size.width - 6, box.minY >= 6, box.maxY <= size.height - 24 else {
                                    continue
                                }
                                if placedBoxes.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(box) }) {
                                    continue
                                }
                                placedBoxes.append(box)
                                if primary {
                                    let bg = Path(roundedRect: box, cornerRadius: 5)
                                    ctx.fill(bg, with: .color(ReaderPalette.elevated.opacity(0.92)))
                                    ctx.stroke(bg, with: .color(ReaderPalette.hairline), lineWidth: 0.75)
                                }
                                ctx.draw(resolved, in: CGRect(x: box.minX + padX, y: box.minY + padY, width: measured.width, height: measured.height))
                                return
                            }
                        }

                        if let selected {
                            placeLabel(selected.title, near: point(for: selected), primary: true)
                            var shownNeighbors = 0
                            for nb in selected.neighbours where shownNeighbors < 2 {
                                if let target = workById[nb.workId] {
                                    placeLabel(target.title, near: point(for: target), primary: false)
                                    shownNeighbors += 1
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        let size = geo.size
                        let midX = size.width / 2 + vm.mapPan.width
                        let midY = size.height / 2 + vm.mapPan.height
                        let pad: CGFloat = 20
                        let scaleX = ((size.width / 2) - pad) * vm.mapZoom
                        let scaleY = ((size.height / 2) - pad) * vm.mapZoom
                        var bestWork: ManifoldReaderWork?
                        var bestDist = Double.greatestFiniteMagnitude
                        for w in works {
                            let cx = midX + CGFloat(w.x) * scaleX
                            let cy = midY - CGFloat(w.y) * scaleY
                            let d = hypot(Double(loc.x - cx), Double(loc.y - cy))
                            if d < bestDist && d <= 32 {
                                bestDist = d
                                bestWork = w
                            }
                        }
                        if let hit = bestWork {
                            ReaderHaptics.selection()
                            vm.selectedMapWorkId = hit.workId
                        }
                    }
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { val in
                                guard !isSnapshot else { return }
                                if vm.mapGestureStartZoom == nil {
                                    vm.mapGestureStartZoom = vm.mapZoom
                                }
                                let base = vm.mapGestureStartZoom ?? 1.0
                                vm.mapZoom = min(3.2, max(1.0, base * val.magnification))
                            }
                            .onEnded { _ in
                                vm.mapGestureStartZoom = nil
                                if vm.mapZoom <= 1.02 {
                                    vm.mapZoom = 1.0
                                    vm.mapPan = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { val in
                                guard !isSnapshot, vm.mapZoom > 1.02 else { return }
                                if vm.mapGestureStartPan == nil {
                                    vm.mapGestureStartPan = vm.mapPan
                                }
                                let start = vm.mapGestureStartPan ?? .zero
                                let maxX = geo.size.width * 0.45 * (vm.mapZoom - 1.0)
                                let maxY = geo.size.height * 0.45 * (vm.mapZoom - 1.0)
                                let nx = min(maxX, max(-maxX, start.width + val.translation.width))
                                let ny = min(maxY, max(-maxY, start.height + val.translation.height))
                                vm.mapPan = CGSize(width: nx, height: ny)
                            }
                            .onEnded { _ in
                                vm.mapGestureStartPan = nil
                            }
                    )

                    // Compact Self-Evident Color Legend
                    HStack(spacing: 10) {
                        legendDot(color: ReaderPalette.cohortGreen, label: "Offline", filled: true)
                        legendDot(color: ReaderPalette.accent, label: "Library", filled: true)
                        legendDot(color: ReaderPalette.tvAmber, label: "Discover", filled: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 5)
                }
            }
            .frame(height: 200)
            .background(ReaderPalette.background)

            Divider()

            ReaderScrollContainer {
                VStack(alignment: .leading, spacing: 14) {
                    if let selected {
                        let owned = vm.ownedBook(for: selected)
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                Task { await vm.openOrInspect(selected) }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    BookCoverView(
                                        book: owned ?? selected.toBookItem(),
                                        serverURL: vm.serverURL,
                                        width: 64,
                                        height: 96,
                                        isSnapshot: isSnapshot,
                                        reloadToken: vm.isServerConnected
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(selected.title)
                                            .font(.system(size: 15, weight: .semibold, design: .serif))
                                            .foregroundStyle(ReaderPalette.label)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)

                                        Text("\(selected.creator) · \(String(selected.year))")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(ReaderPalette.secondary)
                                            .lineLimit(1)

                                        if !selected.summary.isEmpty {
                                            Text(selected.summary)
                                                .font(.system(size: 12))
                                                .foregroundStyle(ReaderPalette.secondary)
                                                .lineLimit(2)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(owned != nil ? "Read" : (selected.isDirectlyDownloadable ? "Download" : "Inspect")) {
                                Task { await vm.openOrInspect(selected) }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(owned != nil ? ReaderPalette.accent : ReaderPalette.tvAmber, in: Capsule())
                            .foregroundStyle(.white)
                            .buttonStyle(.plain)
                        }
                        .padding(11)
                        .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 0.75))

                        let validResonances = Array(selected.resonances.filter(\.isValidEditorialResonance).prefix(3))
                        if !validResonances.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Across Film, Music & Study")
                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                    .foregroundStyle(ReaderPalette.label)

                                ForEach(validResonances) { res in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(ReaderPalette.domainColor(res.domain))
                                            .frame(width: 7, height: 7)
                                        Text(res.title)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(ReaderPalette.label)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(ReaderPalette.domainLabel(res.domain))
                                            .font(.system(size: 11))
                                            .foregroundStyle(ReaderPalette.secondary)
                                        Text(String(format: "%.2f", res.sim))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(ReaderPalette.secondary)
                                            .monospacedDigit()
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lens sequence")
                            .font(.system(size: 13, weight: .semibold, design: .serif))
                            .foregroundStyle(ReaderPalette.label)

                        ForEach(Array(ranked.prefix(6).enumerated()), id: \.element.id) { idx, row in
                            let owned = vm.ownedBook(for: row.work) != nil
                            Button {
                                ReaderHaptics.selection()
                                vm.selectedMapWorkId = row.work.workId
                            } label: {
                                HStack(spacing: 10) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(ReaderPalette.secondary)
                                        .frame(width: 14, alignment: .leading)
                                    Circle()
                                        .fill(owned ? ReaderPalette.accent : ReaderPalette.tvAmber)
                                        .frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.work.title)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(ReaderPalette.label)
                                            .lineLimit(1)
                                        Text(owned ? "\(row.work.creator) · In library" : row.work.creator)
                                            .font(.system(size: 11))
                                            .foregroundStyle(owned ? ReaderPalette.cohortGreen : ReaderPalette.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    InstrumentGauge(ratio: row.score, tint: ReaderPalette.accent)
                                        .frame(width: 44)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(ReaderPalette.background)
    }

    private func legendDot(color: Color, label: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(filled ? color : color.opacity(0.24))
                .overlay(Circle().strokeBorder(color, lineWidth: filled ? 0 : 1.1))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(ReaderPalette.secondary)
        }
    }

    private nonisolated static func shortCanvasTitle(_ raw: String, maxChars: Int) -> String {
        let head = raw.components(separatedBy: CharacterSet(charactersIn: ";:")).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        guard head.count > maxChars else { return head }
        return String(head.prefix(maxChars - 1)) + "…"
    }

    private var lensStripRow: some View {
        HStack(spacing: 6) {
            ForEach(vm.lenses) { lens in
                let isSelected = vm.selectedLensId == lens.id
                Button {
                    ReaderHaptics.selection()
                    vm.selectedLensId = lens.id
                } label: {
                    Text(lens.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : ReaderPalette.label)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            isSelected ? ReaderPalette.accent : ReaderPalette.surface,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
