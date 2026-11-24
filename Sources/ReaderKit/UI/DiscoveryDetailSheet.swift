import Foundation
import ManifoldClient
import ReaderModel
import SwiftUI

/// Editorial book card for discovering works across Manifold, saving to Want to Read,
/// downloading open-access editions, or sourcing BYO titles externally.
public struct DiscoveryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel
    public let work: ManifoldReaderWork

    public init(vm: ReaderViewModel, work: ManifoldReaderWork) {
        self.vm = vm
        self.work = work
    }

    private var owned: BookItem? { vm.ownedBook(for: work) }
    private var isSaved: Bool { vm.wishlistIds.contains(work.workId) }
    private var isOpenAccess: Bool { work.epubURL != nil || work.openAccessURL != nil }
    private var workById: [String: ManifoldReaderWork] {
        Dictionary(uniqueKeysWithValues: vm.manifoldWorks.map { ($0.workId, $0) })
    }

    public var body: some View {
        if isSnapshot {
            sheetContent(includeTopClose: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ReaderPalette.background)
        } else {
            NavigationStack {
                ScrollView {
                    sheetContent(includeTopClose: false)
                }
                .background(ReaderPalette.background)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await vm.toggleWishlist(workId: work.workId) }
                        } label: {
                            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                .foregroundStyle(isSaved ? ReaderPalette.accent : ReaderPalette.label)
                        }
                        .accessibilityLabel(isSaved ? "Remove from Want to Read" : "Save to Want to Read")
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private func sheetContent(includeTopClose: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if includeTopClose {
                HStack {
                    Text(isOpenAccess ? "Open edition" : "Beyond your shelf")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderPalette.secondary)
                    Spacer()
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 14))
                        .foregroundStyle(isSaved ? ReaderPalette.accent : ReaderPalette.secondary)
                    Text("Close")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReaderPalette.accent)
                }
                Divider()
            }

            // Cover + Title + Hook Hero
            HStack(alignment: .top, spacing: 14) {
                BookCoverView(
                    book: work.toBookItem(),
                    serverURL: "",
                    width: 92,
                    height: 138,
                    isSnapshot: isSnapshot
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(work.title)
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundStyle(ReaderPalette.label)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(work.creator) · \(String(work.year))")
                        .font(.system(size: 13))
                        .foregroundStyle(ReaderPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: owned != nil ? "checkmark.circle.fill" : (isOpenAccess ? "arrow.down.circle" : "books.vertical"))
                            .font(.system(size: 11))
                            .foregroundStyle(owned != nil ? ReaderPalette.cohortGreen : (isOpenAccess ? ReaderPalette.accent : ReaderPalette.tvAmber))
                        Text(owned != nil ? "In your library" : (isOpenAccess ? "Open access" : "Source yourself (BYO)"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(owned != nil ? ReaderPalette.cohortGreen : (isOpenAccess ? ReaderPalette.accent : ReaderPalette.tvAmber))
                    }
                    .padding(.top, 2)

                    if let subj = work.subject, !subj.isEmpty {
                        Text(subj)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ReaderPalette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !work.summary.isEmpty {
                Text(work.summary)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            // Action Buttons
            HStack(spacing: 10) {
                if let owned {
                    Button {
                        dismiss()
                        Task { await vm.openBook(owned) }
                    } label: {
                        Label("Read now", systemImage: "book.pages")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(ReaderPalette.accent, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else if isOpenAccess {
                    Button {
                        Task { await vm.downloadDiscoveryWork(work) }
                    } label: {
                        Label("Download free edition", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(ReaderPalette.accent, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await vm.toggleWishlist(workId: work.workId) }
                    } label: {
                        Label(isSaved ? "Saved" : "Want to read", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isSaved ? ReaderPalette.accent : ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(isSaved ? .white : ReaderPalette.label)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSaved ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                        vm.isImporterPresented = true
                    } label: {
                        Label("Import file", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(ReaderPalette.label)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Find a copy externally when unowned
            if owned == nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Find a copy")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ReaderPalette.label)
                        Spacer()
                        Text(formattedCanonicalId)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ReaderPalette.secondary)
                    }

                    HStack(spacing: 8) {
                        ForEach(sourceLinks, id: \.label) { item in
                            if isSnapshot {
                                HStack(spacing: 4) {
                                    Text(item.label)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9.5))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ReaderPalette.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ReaderPalette.hairline, lineWidth: 1))
                            } else {
                                Link(destination: item.url) {
                                    HStack(spacing: 4) {
                                        Text(item.label)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9.5))
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ReaderPalette.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ReaderPalette.hairline, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
            }

            let neighbours = work.neighbours.prefix(4).compactMap { nb -> (ManifoldReaderWork, Double)? in
                guard let target = workById[nb.workId] else { return nil }
                return (target, nb.sim)
            }
            if !neighbours.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected works")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ReaderPalette.label)

                    ForEach(neighbours, id: \.0.workId) { pair in
                        let target = pair.0
                        let inLib = vm.ownedBook(for: target) != nil
                        Button {
                            vm.presentedDiscoveryWork = target
                        } label: {
                            HStack(spacing: 10) {
                                BookCoverView(book: target.toBookItem(), serverURL: "", width: 32, height: 48, isSnapshot: isSnapshot)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(ReaderPalette.label)
                                        .lineLimit(1)
                                    Text(inLib ? "\(target.creator) · In library" : target.creator)
                                        .font(.system(size: 11))
                                        .foregroundStyle(inLib ? ReaderPalette.cohortGreen : ReaderPalette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(String(format: "%.2f", pair.1))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !work.resonances.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Across Film, Music & Study")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ReaderPalette.label)

                    ForEach(work.resonances.prefix(3)) { res in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(ReaderPalette.domainColor(res.domain))
                                .frame(width: 7, height: 7)
                            Text(res.title)
                                .font(.system(size: 12.5))
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
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var formattedCanonicalId: String {
        if work.workId.hasPrefix("isbn:") {
            return "ISBN \(work.workId.dropFirst(5))"
        }
        return work.workId
    }

    private var sourceLinks: [(label: String, url: URL)] {
        let query = "\(work.title) \(work.creator)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var links: [(String, URL)] = []
        if work.workId.hasPrefix("isbn:") {
            let isbn = String(work.workId.dropFirst(5))
            if let ol = URL(string: "https://openlibrary.org/isbn/\(isbn)") {
                links.append(("Open Library", ol))
            }
            if let wc = URL(string: "https://search.worldcat.org/search?q=bn:\(isbn)") {
                links.append(("WorldCat", wc))
            }
            if let bs = URL(string: "https://bookshop.org/beta-search?keywords=\(isbn)") {
                links.append(("Bookshop", bs))
            }
        } else {
            if let ol = URL(string: "https://openlibrary.org/search?q=\(query)") {
                links.append(("Open Library", ol))
            }
            if let wc = URL(string: "https://search.worldcat.org/search?q=\(query)") {
                links.append(("WorldCat", wc))
            }
            if let oa = work.openAccessURL.flatMap(URL.init(string:)) {
                links.append(("Publisher", oa))
            }
        }
        return links
    }
}
