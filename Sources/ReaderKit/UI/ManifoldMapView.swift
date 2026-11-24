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

        VStack(spacing: 0) {
            // Clean Editorial Top Bar
            HStack(spacing: 8) {
                Text("Atlas")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                Spacer(minLength: 4)
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
                Canvas { ctx, size in
                    let midX = size.width / 2
                    let midY = size.height / 2
                    let pad: CGFloat = 18
                    let scaleX = (size.width / 2) - pad
                    let scaleY = (size.height / 2) - pad

                    var axes = Path()
                    axes.move(to: CGPoint(x: midX, y: pad))
                    axes.addLine(to: CGPoint(x: midX, y: size.height - pad))
                    axes.move(to: CGPoint(x: pad, y: midY))
                    axes.addLine(to: CGPoint(x: size.width - pad, y: midY))
                    ctx.stroke(axes, with: .color(ReaderPalette.hairline.opacity(0.8)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))

                    let workById = Dictionary(uniqueKeysWithValues: works.map { ($0.workId, $0) })

                    if let selected {
                        let sx = midX + CGFloat(selected.x) * scaleX
                        let sy = midY - CGFloat(selected.y) * scaleY
                        for nb in selected.neighbours.prefix(5) {
                            if let target = workById[nb.workId] {
                                let tx = midX + CGFloat(target.x) * scaleX
                                let ty = midY - CGFloat(target.y) * scaleY
                                var spoke = Path()
                                spoke.move(to: CGPoint(x: sx, y: sy))
                                spoke.addLine(to: CGPoint(x: tx, y: ty))
                                ctx.stroke(spoke, with: .color(ReaderPalette.secondary.opacity(0.35)), lineWidth: 1)
                            }
                        }
                    }

                    for w in works {
                        let cx = midX + CGFloat(w.x) * scaleX
                        let cy = midY - CGFloat(w.y) * scaleY
                        let isSel = selected?.workId == w.workId
                        let owned = vm.ownedBook(for: w)
                        let r: CGFloat = isSel ? 6 : 4
                        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

                        if let owned {
                            let dotColor = owned.isOfflineCached ? ReaderPalette.cohortGreen : ReaderPalette.accent
                            ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                        } else {
                            ctx.fill(Path(ellipseIn: rect), with: .color(ReaderPalette.tvAmber.opacity(0.24)))
                            ctx.stroke(Path(ellipseIn: rect), with: .color(ReaderPalette.tvAmber), lineWidth: 1.4)
                        }

                        if isSel {
                            let ring = CGRect(x: cx - 10, y: cy - 10, width: 20, height: 20)
                            ctx.stroke(Path(ellipseIn: ring), with: .color(ReaderPalette.label), lineWidth: 1.5)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    let size = geo.size
                    let midX = size.width / 2
                    let midY = size.height / 2
                    let pad: CGFloat = 18
                    let scaleX = (size.width / 2) - pad
                    let scaleY = (size.height / 2) - pad
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
                        vm.selectedMapWorkId = hit.workId
                    }
                }
            }
            .frame(height: 184)
            .background(ReaderPalette.background)

            Divider()

            ReaderScrollContainer {
                VStack(alignment: .leading, spacing: 14) {
                    if let selected {
                        let owned = vm.ownedBook(for: selected)
                        HStack(alignment: .top, spacing: 12) {
                            BookCoverView(
                                book: owned ?? selected.toBookItem(),
                                serverURL: vm.serverURL,
                                width: 52,
                                height: 78,
                                isSnapshot: isSnapshot,
                                reloadToken: vm.isServerConnected
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selected.title)
                                            .font(.system(size: 14.5, weight: .semibold, design: .serif))
                                            .foregroundStyle(ReaderPalette.label)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("\(selected.creator) · \(String(selected.year))")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(ReaderPalette.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Button(owned != nil ? "Read" : ((selected.epubURL != nil || selected.openAccessURL != nil) ? "Get" : "Find")) {
                                        Task { await vm.openOrInspect(selected) }
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(owned != nil ? ReaderPalette.accent : ReaderPalette.tvAmber, in: Capsule())
                                    .foregroundStyle(.white)
                                    .buttonStyle(.plain)
                                }

                                if !selected.summary.isEmpty {
                                    Text(selected.summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(ReaderPalette.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(11)
                        .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 0.75))

                        if !selected.resonances.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Across Film, Music & Study")
                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                    .foregroundStyle(ReaderPalette.label)

                                ForEach(selected.resonances.prefix(3)) { res in
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

    private var lensStripRow: some View {
        HStack(spacing: 6) {
            ForEach(vm.lenses) { lens in
                let isSelected = vm.selectedLensId == lens.id
                Button {
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
