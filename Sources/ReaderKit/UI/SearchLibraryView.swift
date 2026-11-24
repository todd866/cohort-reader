import ManifoldClient
import ReaderModel
import SwiftUI

public struct SearchLibraryView: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    private var visibleResults: [BookItem] {
        let base: [BookItem]
        let q = vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            base = vm.books
        } else if !vm.serverSearchResults.isEmpty {
            base = vm.serverSearchResults
        } else {
            base = vm.books.filter {
                $0.title.lowercased().contains(q)
                    || $0.author.lowercased().contains(q)
                    || $0.genre.lowercased().contains(q)
                    || ($0.canonicalId?.lowercased().contains(q) ?? false)
                    || $0.summary.lowercased().contains(q)
            }
        }

        switch vm.searchScope {
        case .all: return base
        case .books: return base.filter { $0.format == .epub || ($0.canonicalId?.hasPrefix("isbn:") ?? false) || ($0.canonicalId?.hasPrefix("gutenberg:") ?? false) }
        case .papers: return base.filter { $0.format == .article || ($0.canonicalId?.hasPrefix("doi:") ?? false) || ($0.canonicalId?.hasPrefix("pmid:") ?? false) || ($0.canonicalId?.hasPrefix("arxiv:") ?? false) }
        case .offline: return base.filter(\.isOfflineCached)
        }
    }

    private var beyondShelfResults: [ManifoldReaderWork] {
        let q = vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = vm.recommendedDiscoveryWorks
        guard !q.isEmpty else { return Array(pool.prefix(12)) }
        return pool.filter {
            $0.title.lowercased().contains(q)
                || $0.creator.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || ($0.subject?.lowercased().contains(q) ?? false)
                || $0.workId.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(ReaderPalette.secondary)
                    if isSnapshot {
                        Text(vm.searchQuery.isEmpty ? "Search library and discoveries" : vm.searchQuery)
                            .font(.system(size: 13.5))
                            .foregroundStyle(vm.searchQuery.isEmpty ? ReaderPalette.secondary : ReaderPalette.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Search library and discoveries", text: $vm.searchQuery)
                            .font(.system(size: 13.5))
                            .onSubmit { Task { await vm.runSearch() } }
                        if !vm.searchQuery.isEmpty {
                            Button {
                                vm.searchQuery = ""
                                vm.serverSearchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(ReaderPalette.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderPalette.hairline, lineWidth: 0.75))

                if vm.isSearchingServer {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ReaderPalette.background)
            .task(id: vm.searchQuery) {
                guard !isSnapshot else { return }
                let q = vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if q.isEmpty {
                    vm.serverSearchResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(260))
                if !Task.isCancelled {
                    await vm.runSearch()
                }
            }

            HStack(spacing: 6) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    let sel = vm.searchScope == scope
                    Button {
                        vm.searchScope = scope
                    } label: {
                        Text(scope.rawValue)
                            .font(.system(size: 12, weight: sel ? .semibold : .medium))
                            .foregroundStyle(sel ? .white : ReaderPalette.label)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(sel ? ReaderPalette.accent : ReaderPalette.surface, in: Capsule())
                            .overlay(Capsule().stroke(sel ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(visibleResults.count + beyondShelfResults.count)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(ReaderPalette.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .background(ReaderPalette.background)

            Divider()

            ReaderScrollContainer {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleResults) { book in
                        Button {
                            Task { await vm.openBook(book) }
                        } label: {
                            HStack(alignment: .center, spacing: 11) {
                                BookCoverView(
                                    book: book,
                                    serverURL: vm.serverURL,
                                    width: 34,
                                    height: 50,
                                    isSnapshot: isSnapshot,
                                    reloadToken: vm.isServerConnected
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(ReaderPalette.label)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(book.shortCitation)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(ReaderPalette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if book.isOfflineCached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ReaderPalette.cohortGreen)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 59)
                    }

                    let discoveries = beyondShelfResults
                    if !discoveries.isEmpty {
                        Text("Beyond your shelf")
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .foregroundStyle(ReaderPalette.label)
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        ForEach(discoveries) { work in
                            Button {
                                Task { await vm.openOrInspect(work) }
                            } label: {
                                HStack(alignment: .center, spacing: 11) {
                                    BookCoverView(book: work.toBookItem(), serverURL: "", width: 34, height: 50, isSnapshot: isSnapshot)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(work.title)
                                            .font(.system(size: 13.5, weight: .semibold))
                                            .foregroundStyle(ReaderPalette.label)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text("\(work.creator) · \(String(work.year))")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(ReaderPalette.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Text((work.epubURL != nil || work.openAccessURL != nil) ? "Free" : "BYO")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle((work.epubURL != nil || work.openAccessURL != nil) ? ReaderPalette.accent : ReaderPalette.tvAmber)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(ReaderPalette.surface, in: Capsule())
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 59)
                        }
                    }
                }
            }
        }
        .background(ReaderPalette.background)
    }
}

public struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    public init(vm: ReaderViewModel) {
        self.vm = vm
    }

    public var body: some View {
        if isSnapshot {
            snapshotSettingsBody
        } else {
            NavigationStack {
                Form {
                    Section("Home Library Server") {
                        TextField("https://your-mac.ts.net:8445", text: $vm.serverURL)
                            .autocorrectionDisabled()
                        SecureField("Passphrase (optional on Tailscale)", text: $vm.serverPassphrase)
                        HStack {
                            Button("Connect & Sync") {
                                Task { await vm.connectHomeServer() }
                            }
                            Spacer()
                            Text(vm.serverStatusMessage)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(vm.isServerConnected ? ReaderPalette.cohortGreen : ReaderPalette.secondary)
                        }
                    }

                    Section("Offline Downloads") {
                        Toggle("Auto-download likely reads", isOn: $vm.autoDownloadEnabled)
                        Picker("Storage budget", selection: $vm.autoDownloadBudgetMB) {
                            Text("150 MB").tag(150)
                            Text("350 MB").tag(350)
                            Text("750 MB").tag(750)
                        }
                        LabeledContent("Cached offline", value: formatBytes(vm.offlineBytes))
                        if let activeTitle = vm.autoDownloadActiveTitle {
                            LabeledContent("Downloading", value: activeTitle)
                        }
                        if vm.pendingOutboxCount > 0 {
                            LabeledContent("Pending progress sync", value: "\(vm.pendingOutboxCount)")
                        }
                    }

                    Section("Manifold Public Hub") {
                        TextField("https://manifold-chi.vercel.app", text: $vm.manifoldHubURL)
                            .autocorrectionDisabled()
                        HStack {
                            Button("Sync Lenses & Atlas") {
                                Task { await vm.refreshManifold() }
                            }
                            Spacer()
                            Text("\(vm.manifoldWorks.count) works · \(vm.lenses.count) lenses")
                                .font(.system(size: 11.5))
                                .foregroundStyle(ReaderPalette.secondary)
                        }
                    }

                    if let msg = vm.lastHandoffMessage {
                        Section("Cohort") {
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundStyle(ReaderPalette.secondary)
                        }
                    }
                }
                .onChange(of: vm.autoDownloadEnabled) { _, _ in vm.savePreferences() }
                .onChange(of: vm.autoDownloadBudgetMB) { _, _ in vm.savePreferences() }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private var snapshotSettingsBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(ReaderPalette.label)
                Spacer()
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ReaderPalette.accent)
            }

            Divider()

            settingsCard("Home Library Server") {
                settingsFieldRow("Server", value: vm.serverURL.isEmpty ? "Tailscale HTTPS" : vm.serverURL, isPlaceholder: vm.serverURL.isEmpty)
                Divider()
                settingsFieldRow("Passphrase", value: vm.serverPassphrase.isEmpty ? "Optional on Tailscale" : "Saved in Keychain", isPlaceholder: vm.serverPassphrase.isEmpty)
                Divider()
                HStack {
                    Text("Connect & Sync")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ReaderPalette.accent)
                    Spacer()
                    Text(vm.serverStatusMessage)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(vm.isServerConnected ? ReaderPalette.cohortGreen : ReaderPalette.secondary)
                }
            }

            settingsCard("Offline Downloads") {
                settingsFieldRow("Auto-download likely reads", value: vm.autoDownloadEnabled ? "On" : "Off", isPlaceholder: false)
                Divider()
                settingsFieldRow("Storage budget", value: "\(vm.autoDownloadBudgetMB) MB", isPlaceholder: false)
                Divider()
                settingsFieldRow("Cached offline", value: formatBytes(vm.offlineBytes), isPlaceholder: false)
            }

            settingsCard("Manifold Public Hub") {
                settingsFieldRow("Hub", value: vm.manifoldHubURL, isPlaceholder: false)
                Divider()
                settingsFieldRow("Catalog", value: "\(vm.manifoldWorks.count) works · \(vm.lenses.count) lenses", isPlaceholder: false)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderPalette.background)
    }

    private func settingsCard<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ReaderPalette.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReaderPalette.hairline, lineWidth: 0.75))
        }
    }

    private func settingsFieldRow(_ label: String, value: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(ReaderPalette.label)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(isPlaceholder ? ReaderPalette.secondary : ReaderPalette.label)
                .lineLimit(1)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(max(1, bytes / 1024)) KB"
    }
}
