import ManifoldClient
import ReaderModel
import SwiftUI

public struct ShelfView: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel
    public var onImportTap: () -> Void

    private var filterOptions: [String] {
        var list = ["All", "Reading", "Offline", "For You"]
        if !vm.wishlistIds.isEmpty {
            list.append("Saved")
        }
        let reserved: Set<String> = ["All", "Reading", "Reading Now", "Downloaded", "Offline", "For You", "Saved", "General", "Library", "Paper", "Showcase", "Open Showcase"]
        for s in vm.shelves where !s.title.isEmpty && !reserved.contains(s.title) && !list.contains(s.title) {
            list.append(s.title)
        }
        for fixed in ["Books", "Papers"] where !list.contains(fixed) {
            list.append(fixed)
        }
        return Array(list.prefix(9))
    }

    public init(vm: ReaderViewModel, onImportTap: @escaping () -> Void) {
        self.vm = vm
        self.onImportTap = onImportTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Single Clean Instrument Top Bar
            HStack(spacing: 8) {
                Text("Library")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)

                Spacer(minLength: 4)

                Button(action: onImportTap) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ReaderPalette.label)
                        .frame(width: 30, height: 30)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Import EPUB or PDF")

                if isSnapshot {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(vm.shelfSortOrder == .recent ? ReaderPalette.label : ReaderPalette.accent)
                        .frame(width: 30, height: 30)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                } else {
                    Menu {
                        ForEach(ShelfSortOrder.allCases, id: \.self) { order in
                            Button {
                                ReaderHaptics.selection()
                                vm.shelfSortOrder = order
                                vm.savePreferences()
                            } label: {
                                if vm.shelfSortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(vm.shelfSortOrder == .recent ? ReaderPalette.label : ReaderPalette.accent)
                            .frame(width: 30, height: 30)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Sort library")
                }

                Button {
                    ReaderHaptics.selection()
                    vm.shelfUsesListLayout.toggle()
                    vm.savePreferences()
                } label: {
                    Image(systemName: vm.shelfUsesListLayout ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(ReaderPalette.label)
                        .frame(width: 30, height: 30)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.shelfUsesListLayout ? "Show cover grid" : "Show list")

                Button {
                    vm.activeSheet = .settings
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(ReaderPalette.label)
                            .frame(width: 30, height: 30)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.hairline, lineWidth: 0.75))
                        if vm.isServerConnected {
                            Circle()
                                .fill(ReaderPalette.cohortGreen)
                                .frame(width: 7, height: 7)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(ReaderPalette.background)

            // Filter Strip
            Group {
                if isSnapshot {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .overlay(alignment: .leading) {
                            filterChipsRow
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .clipped()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        filterChipsRow
                    }
                }
            }
            .background(ReaderPalette.background)

            Divider()

            GeometryReader { geo in
                let cols = gridColumns(for: geo.size.width)
                ReaderScrollContainer {
                    if vm.activeShelfFilter == "For You" {
                        discoveryGridContent(colCount: cols, totalWidth: geo.size.width)
                    } else if vm.activeShelfFilter == "Saved" {
                        savedGridContent(colCount: cols, totalWidth: geo.size.width)
                    } else {
                        libraryContent(colCount: cols, totalWidth: geo.size.width)
                    }
                }
                .refreshable {
                    await vm.syncServerCatalog()
                }
            }
        }
        .background(ReaderPalette.background)
    }

    private var filterChipsRow: some View {
        HStack(spacing: 6) {
            ForEach(filterOptions, id: \.self) { option in
                let selected = vm.activeShelfFilter == option
                Button {
                    ReaderHaptics.selection()
                    vm.activeShelfFilter = option
                } label: {
                    Text(option)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : ReaderPalette.label)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            selected ? ReaderPalette.accent : ReaderPalette.surface,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(selected ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func gridColumns(for width: CGFloat) -> Int {
        if width <= 0 { return 3 }
        return min(6, max(3, Int((width - 16) / 155)))
    }

    private func cardWidth(for totalWidth: CGFloat, colCount: Int) -> CGFloat? {
        guard totalWidth > 40, colCount > 0 else { return nil }
        let gaps = CGFloat(colCount - 1) * 12 + 28
        return max(80, (totalWidth - gaps) / CGFloat(colCount))
    }

    private func libraryContent(colCount: Int, totalWidth: CGFloat) -> some View {
        let items = vm.filteredShelfBooks
        let hero = vm.activeShelfFilter == "All" ? vm.continueReadingBook : nil
        let gridItems = hero == nil ? items : items.filter { $0.id != hero?.id }
        let discovery = Array(vm.recommendedDiscoveryWorks.prefix(8))
        let w = cardWidth(for: totalWidth, colCount: colCount)
        let splitCount = totalWidth > 700 ? colCount : colCount * 2
        let hasEarlyDiscovery = vm.activeShelfFilter == "All" && !discovery.isEmpty && !vm.shelfUsesListLayout
        let headGrid = hasEarlyDiscovery ? Array(gridItems.prefix(splitCount)) : gridItems
        let tailGrid = hasEarlyDiscovery && gridItems.count > splitCount ? Array(gridItems.dropFirst(splitCount)) : []

        return VStack(alignment: .leading, spacing: 18) {
            if let hero {
                HeroContinueCard(
                    book: hero,
                    serverURL: vm.serverURL,
                    isSnapshot: isSnapshot,
                    isServerConnected: vm.isServerConnected,
                    hasAtlasMatch: vm.manifoldWork(for: hero) != nil,
                    onResume: {
                        ReaderHaptics.light()
                        Task { await vm.openBook(hero) }
                    },
                    onToggleOffline: {
                        Task {
                            if hero.isOfflineCached {
                                await vm.evictOfflineBook(hero)
                            } else {
                                await vm.downloadForOffline(hero)
                            }
                        }
                    },
                    onShowInAtlas: {
                        vm.focusBookInAtlas(hero)
                    }
                )
                .padding(.horizontal, 14)
            }

            if vm.shelfUsesListLayout {
                LazyVStack(spacing: 0) {
                    ForEach(items) { book in
                        BookShelfListRow(
                            book: book,
                            serverURL: vm.serverURL,
                            isSnapshot: isSnapshot,
                            isServerConnected: vm.isServerConnected,
                            isBusy: vm.isBusyBookId == book.id,
                            hasAtlasMatch: vm.manifoldWork(for: book) != nil,
                            onOpen: { Task { await vm.openBook(book) } },
                            onToggleOffline: {
                                Task {
                                    if book.isOfflineCached {
                                        await vm.evictOfflineBook(book)
                                    } else {
                                        await vm.downloadForOffline(book)
                                    }
                                }
                            },
                            onShowInAtlas: {
                                vm.focusBookInAtlas(book)
                            }
                        )
                        Divider().padding(.leading, 78)
                    }
                }
            } else {
                coverGrid(books: headGrid, colCount: colCount, coverWidth: w)
                    .padding(.horizontal, 14)
            }

            if vm.activeShelfFilter == "All", !discovery.isEmpty {
                beyondShelfRailSection(works: discovery)
            }

            if !tailGrid.isEmpty {
                coverGrid(books: tailGrid, colCount: colCount, coverWidth: w)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 14)
    }

    private func beyondShelfRailSection(works: [ManifoldReaderWork]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Beyond your shelf")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                Spacer()
                Button("See all") {
                    ReaderHaptics.selection()
                    vm.activeShelfFilter = "For You"
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ReaderPalette.accent)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)

            Group {
                if isSnapshot {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 158)
                        .overlay(alignment: .topLeading) {
                            discoveryRailRow(works: works)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .clipped()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        discoveryRailRow(works: works)
                    }
                }
            }
        }
    }

    private func savedGridContent(colCount: Int, totalWidth: CGFloat) -> some View {
        let discoverySaved = vm.wishlistedDiscoveryWorks.filter { vm.ownedBook(for: $0) == nil }
        let ownedSaved = vm.filteredShelfBooks
        let w = cardWidth(for: totalWidth, colCount: colCount)

        return VStack(alignment: .leading, spacing: 16) {
            if ownedSaved.isEmpty && discoverySaved.isEmpty {
                Text("Bookmark titles from Beyond your shelf to track copies to find or read next.")
                    .font(.system(size: 13))
                    .foregroundStyle(ReaderPalette.secondary)
                    .padding(.horizontal, 14)
            } else {
                if !ownedSaved.isEmpty {
                    coverGrid(books: ownedSaved, colCount: colCount, coverWidth: w)
                        .padding(.horizontal, 14)
                }
                if !discoverySaved.isEmpty {
                    let rows = chunked(discoverySaved, size: colCount)
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(row) { work in
                                    DiscoveryGridCard(
                                        work: work,
                                        coverWidth: w,
                                        isSaved: true,
                                        isSnapshot: isSnapshot,
                                        onTap: { Task { await vm.openOrInspect(work) } }
                                    )
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                if row.count < colCount {
                                    ForEach(0..<(colCount - row.count), id: \.self) { _ in
                                        Color.clear.frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func discoveryGridContent(colCount: Int, totalWidth: CGFloat) -> some View {
        let works = vm.recommendedDiscoveryWorks
        let rows = chunked(works, size: colCount)
        let w = cardWidth(for: totalWidth, colCount: colCount)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Beyond your shelf")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                Spacer()
                Text("\(works.count) curated")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ReaderPalette.secondary)
            }
            .padding(.horizontal, 14)

            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row) { work in
                            DiscoveryGridCard(
                                work: work,
                                coverWidth: w,
                                isSaved: vm.wishlistIds.contains(work.workId),
                                isSnapshot: isSnapshot,
                                onTap: { Task { await vm.openOrInspect(work) } }
                            )
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if row.count < colCount {
                            ForEach(0..<(colCount - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 14)
    }

    private func coverGrid(books: [BookItem], colCount: Int, coverWidth: CGFloat?) -> some View {
        let rows = chunked(books, size: colCount)

        return LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { book in
                        BookGridCard(
                            book: book,
                            serverURL: vm.serverURL,
                            coverWidth: coverWidth,
                            isSnapshot: isSnapshot,
                            isServerConnected: vm.isServerConnected,
                            isBusy: vm.isBusyBookId == book.id,
                            hasAtlasMatch: vm.manifoldWork(for: book) != nil,
                            onOpen: { Task { await vm.openBook(book) } },
                            onToggleOffline: {
                                Task {
                                    if book.isOfflineCached {
                                        await vm.evictOfflineBook(book)
                                    } else {
                                        await vm.downloadForOffline(book)
                                    }
                                }
                            },
                            onShowInAtlas: {
                                vm.focusBookInAtlas(book)
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if row.count < colCount {
                        ForEach(0..<(colCount - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func discoveryRailRow(works: [ManifoldReaderWork]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(works) { work in
                DiscoveryRailCard(
                    work: work,
                    isSaved: vm.wishlistIds.contains(work.workId),
                    isSnapshot: isSnapshot,
                    onTap: { Task { await vm.openOrInspect(work) } }
                )
            }
        }
        .padding(.horizontal, 14)
    }

    private func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}

private struct HeroContinueCard: View {
    let book: BookItem
    let serverURL: String
    let isSnapshot: Bool
    let isServerConnected: Bool
    let hasAtlasMatch: Bool
    let onResume: () -> Void
    let onToggleOffline: () -> Void
    let onShowInAtlas: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 14) {
                BookCoverView(
                    book: book,
                    serverURL: serverURL,
                    width: 78,
                    height: 117,
                    isSnapshot: isSnapshot,
                    reloadToken: isServerConnected
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    if !book.author.isEmpty && book.author.caseInsensitiveCompare("Unknown") != .orderedSame {
                        Text(book.author)
                            .font(.system(size: 12.5))
                            .foregroundStyle(ReaderPalette.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    HStack(spacing: 8) {
                        InstrumentGauge(ratio: Double(max(book.progressPercent, 3)) / 100.0, tint: ReaderPalette.accent)
                            .frame(maxWidth: 96)
                        if book.progressPercent > 0 {
                            Text("\(book.progressPercent)%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ReaderPalette.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        Text("Resume")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(ReaderPalette.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ReaderPalette.hairline, lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onResume) {
                Label("Open", systemImage: "book.pages")
            }
            Button(action: onToggleOffline) {
                Label(
                    book.isOfflineCached ? "Remove offline copy" : "Download offline",
                    systemImage: book.isOfflineCached ? "trash" : "arrow.down.circle"
                )
            }
            if hasAtlasMatch {
                Button(action: onShowInAtlas) {
                    Label("Show in Atlas", systemImage: "sparkles")
                }
            }
        }
    }
}

private struct BookGridCard: View {
    let book: BookItem
    let serverURL: String
    let coverWidth: CGFloat?
    let isSnapshot: Bool
    let isServerConnected: Bool
    let isBusy: Bool
    let hasAtlasMatch: Bool
    let onOpen: () -> Void
    let onToggleOffline: () -> Void
    let onShowInAtlas: () -> Void

    private var cache = AssetImageCache.shared

    private var quietAuthor: String {
        let a = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty && a.caseInsensitiveCompare("Unknown") != .orderedSame {
            return a.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? a
        }
        if !book.genre.isEmpty && book.genre != "Library" { return book.genre }
        return book.format.label
    }

    var body: some View {
        let hasRealArt = !isSnapshot && cache.hasImage(forBookId: book.id)

        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    BookCoverView(
                        book: book,
                        serverURL: serverURL,
                        width: coverWidth,
                        height: coverWidth.map { ($0 * 1.48).rounded() },
                        isSnapshot: isSnapshot,
                        reloadToken: isServerConnected
                    )

                    if book.progressPercent > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.28))
                                Rectangle()
                                    .fill(ReaderPalette.accent)
                                    .frame(width: max(4, geo.size.width * CGFloat(book.progressPercent) / 100.0))
                            }
                        }
                        .frame(height: 3)
                        .clipShape(Capsule())
                        .padding(.horizontal, 5)
                        .padding(.bottom, 5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(5)
                            .background(ReaderPalette.elevated.opacity(0.9), in: Circle())
                            .padding(4)
                    } else if book.isOfflineCached {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(ReaderPalette.cohortGreen)
                            .background(Circle().fill(ReaderPalette.elevated))
                            .padding(5)
                    }
                }

                if hasRealArt {
                    Text(book.title.components(separatedBy: " — ").first ?? book.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReaderPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text(quietAuthor)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ReaderPalette.secondary)
                        .lineLimit(1)
                } else {
                    Text(quietAuthor)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReaderPalette.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onOpen) {
                Label("Open", systemImage: "book.pages")
            }
            Button(action: onToggleOffline) {
                Label(
                    book.isOfflineCached ? "Remove offline copy" : "Download offline",
                    systemImage: book.isOfflineCached ? "trash" : "arrow.down.circle"
                )
            }
            if hasAtlasMatch {
                Button(action: onShowInAtlas) {
                    Label("Show in Atlas", systemImage: "sparkles")
                }
            }
        }
    }
}

private struct DiscoveryRailCard: View {
    let work: ManifoldReaderWork
    let isSaved: Bool
    let isSnapshot: Bool
    let onTap: () -> Void

    private var cache = AssetImageCache.shared

    private var badgeText: String {
        if isSaved { return "Saved" }
        return (work.epubURL != nil || work.openAccessURL != nil) ? "Free" : "BYO"
    }

    private var shortCreator: String {
        work.creator.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? work.creator
    }

    var body: some View {
        let workBook = work.toBookItem()
        let hasRealArt = !isSnapshot && cache.hasImage(forBookId: workBook.id)

        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                BookCoverView(
                    book: workBook,
                    serverURL: "",
                    width: 86,
                    height: 128,
                    isSnapshot: isSnapshot
                )
                .overlay(alignment: .bottomTrailing) {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            (isSaved ? ReaderPalette.accent : Color.black.opacity(0.62)),
                            in: Capsule()
                        )
                        .padding(5)
                }

                if hasRealArt {
                    Text(work.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ReaderPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(width: 86, alignment: .leading)
                }

                Text(shortCreator)
                    .font(.system(size: hasRealArt ? 10 : 10.5, weight: hasRealArt ? .regular : .medium))
                    .foregroundStyle(ReaderPalette.secondary)
                    .lineLimit(1)
                    .frame(width: 86, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoveryGridCard: View {
    let work: ManifoldReaderWork
    let coverWidth: CGFloat?
    let isSaved: Bool
    let isSnapshot: Bool
    let onTap: () -> Void

    private var cache = AssetImageCache.shared

    private var badgeText: String {
        if isSaved { return "Saved" }
        return (work.epubURL != nil || work.openAccessURL != nil) ? "Free" : "BYO"
    }

    private var shortCreator: String {
        work.creator.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? work.creator
    }

    var body: some View {
        let workBook = work.toBookItem()
        let hasRealArt = !isSnapshot && cache.hasImage(forBookId: workBook.id)

        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                BookCoverView(
                    book: workBook,
                    serverURL: "",
                    width: coverWidth,
                    height: coverWidth.map { ($0 * 1.48).rounded() },
                    isSnapshot: isSnapshot
                )
                .overlay(alignment: .bottomTrailing) {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (isSaved ? ReaderPalette.accent : Color.black.opacity(0.62)),
                            in: Capsule()
                        )
                        .padding(5)
                }

                if hasRealArt {
                    Text(work.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReaderPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text(shortCreator)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ReaderPalette.secondary)
                        .lineLimit(1)
                } else {
                    Text(shortCreator)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReaderPalette.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BookShelfListRow: View {
    let book: BookItem
    let serverURL: String
    let isSnapshot: Bool
    let isServerConnected: Bool
    let isBusy: Bool
    let hasAtlasMatch: Bool
    let onOpen: () -> Void
    let onToggleOffline: () -> Void
    let onShowInAtlas: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 12) {
                    BookCoverView(
                        book: book,
                        serverURL: serverURL,
                        width: 44,
                        height: 66,
                        isSnapshot: isSnapshot,
                        reloadToken: isServerConnected
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ReaderPalette.label)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(book.shortCitation)
                            .font(.system(size: 12))
                            .foregroundStyle(ReaderPalette.secondary)
                            .lineLimit(1)

                        if book.progressPercent > 0 {
                            HStack(spacing: 6) {
                                InstrumentGauge(ratio: Double(book.progressPercent) / 100.0, tint: ReaderPalette.accent)
                                    .frame(maxWidth: 100)
                                Text("\(book.progressPercent)%")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleOffline) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: book.isOfflineCached ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(book.isOfflineCached ? ReaderPalette.cohortGreen : ReaderPalette.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(book.isOfflineCached ? "Remove download" : "Download")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ReaderPalette.background)
        .contextMenu {
            Button(action: onOpen) {
                Label("Open", systemImage: "book.pages")
            }
            Button(action: onToggleOffline) {
                Label(
                    book.isOfflineCached ? "Remove offline copy" : "Download offline",
                    systemImage: book.isOfflineCached ? "trash" : "arrow.down.circle"
                )
            }
            if hasAtlasMatch {
                Button(action: onShowInAtlas) {
                    Label("Show in Atlas", systemImage: "sparkles")
                }
            }
        }
    }
}
