import ManifoldClient
import ReaderModel
import SwiftUI

public struct SearchLibraryView: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    @Bindable public var vm: ReaderViewModel

    private var suggestedTopics: [String] {
        let excluded: Set<String> = ["All", "Reading", "Reading Now", "Downloaded", "Offline", "General", "Library", "Paper", "Showcase", "Open Showcase", "Imported"]
        if vm.hasRealLibrary {
            var topics: [String] = []
            for s in vm.shelves where !s.title.isEmpty && !excluded.contains(s.title) && !topics.contains(s.title) {
                topics.append(s.title)
            }
            let genreCounts = Dictionary(grouping: vm.books.map(\.genre).filter { !$0.isEmpty && !excluded.contains($0) }) { $0 }
            for (g, _) in genreCounts.sorted(by: { $0.value.count > $1.value.count }) where !topics.contains(g) {
                topics.append(g)
            }
            if !topics.isEmpty {
                return Array(topics.prefix(7))
            }
        }
        return ["Statecraft", "Neuroscience", "Systems", "History", "Literature", "Biology"]
    }

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
        if q.isEmpty {
            return vm.hasRealLibrary ? [] : Array(pool.prefix(12))
        }
        return pool.filter {
            $0.title.lowercased().contains(q)
                || $0.creator.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || ($0.subject?.lowercased().contains(q) ?? false)
                || $0.workId.lowercased().contains(q)
        }
    }

    private func conciseAuthors(_ raw: String) -> String {
        let parts = raw
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return raw }
        return parts.count > 1 ? "\(first) et al." : first
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
                        #if os(macOS)
                        if vm.searchQuery.isEmpty {
                            KeycapBadge("/")
                        }
                        #endif
                    } else {
                        InlineCommandTextField(
                            placeholder: "Search library and discoveries",
                            text: vm.searchQuery,
                            fontSize: 13.5,
                            focusToken: vm.searchFocusToken,
                            onTextChange: {
                                vm.searchQuery = $0
                                vm.selectedSearchIndex = nil
                            },
                            onMoveUp: { vm.moveSearchSelection(delta: -1) },
                            onMoveDown: { vm.moveSearchSelection(delta: 1) },
                            onSubmit: {
                                if vm.selectedSearchIndex != nil {
                                    _ = vm.openSelectedSearchItem()
                                } else {
                                    Task { await vm.runSearch() }
                                }
                            }
                        )
                        #if os(macOS)
                        if vm.searchQuery.isEmpty {
                            KeycapBadge("/")
                        }
                        #endif
                        if !vm.searchQuery.isEmpty {
                            Button {
                                vm.searchQuery = ""
                                vm.serverSearchResults = []
                                vm.selectedSearchIndex = nil
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
                        ReaderHaptics.selection()
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

            if vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestedTopics, id: \.self) { topic in
                            Button {
                                ReaderHaptics.selection()
                                vm.searchQuery = topic
                            } label: {
                                Text(topic)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(ReaderPalette.elevated, in: Capsule())
                                    .overlay(Capsule().stroke(ReaderPalette.hairline, lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .background(ReaderPalette.background)
            }

            Divider()

            ReaderScrollContainer {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleResults.enumerated()), id: \.element.id) { idx, book in
                        let isRowSelected = !isSnapshot && vm.selectedSearchIndex == idx
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
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                    Text(conciseAuthors(book.author))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(ReaderPalette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if let year = book.year, year > 0 {
                                    Text(String(year))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(ReaderPalette.secondary)
                                        .monospacedDigit()
                                }
                                if book.isOfflineCached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ReaderPalette.cohortGreen)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isRowSelected ? ReaderPalette.accent.opacity(0.10) : Color.clear)
                            .overlay(alignment: .leading) {
                                if isRowSelected {
                                    Rectangle().fill(ReaderPalette.accent).frame(width: 3)
                                }
                            }
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

                        ForEach(Array(discoveries.enumerated()), id: \.element.workId) { dIdx, work in
                            let globalIdx = visibleResults.count + dIdx
                            let isRowSelected = !isSnapshot && vm.selectedSearchIndex == globalIdx
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
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                        Text(conciseAuthors(work.creator))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(ReaderPalette.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    if work.year > 0 {
                                        Text(String(work.year))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(ReaderPalette.secondary)
                                            .monospacedDigit()
                                    }
                                    if work.isDirectlyDownloadable {
                                        Text("Open")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(ReaderPalette.accent)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(ReaderPalette.surface, in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(isRowSelected ? ReaderPalette.accent.opacity(0.10) : Color.clear)
                                .overlay(alignment: .leading) {
                                    if isRowSelected {
                                        Rectangle().fill(ReaderPalette.accent).frame(width: 3)
                                    }
                                }
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

    private var budgetUsageRatio: Double {
        if vm.autoDownloadBudgetMB <= 0 {
            let total = max(1, vm.books.count)
            let cached = vm.books.filter(\.isOfflineCached).count
            return min(max(Double(cached) / Double(total), 0), 1)
        }
        let budget = Double(max(1, vm.autoDownloadBudgetMB)) * 1024 * 1024
        return min(max(Double(vm.offlineBytes) / budget, 0), 1)
    }

    private var budgetLabel: String {
        if vm.autoDownloadBudgetMB <= 0 { return "All" }
        if vm.autoDownloadBudgetMB >= 1024 && vm.autoDownloadBudgetMB % 1024 == 0 {
            return "\(vm.autoDownloadBudgetMB / 1024) GB"
        }
        return "\(vm.autoDownloadBudgetMB) MB"
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
                        Toggle("Auto-download offline library", isOn: $vm.autoDownloadEnabled)
                        Picker("Storage budget", selection: $vm.autoDownloadBudgetMB) {
                            Text("500 MB").tag(500)
                            Text("1 GB").tag(1024)
                            Text("2 GB").tag(2048)
                            Text("4 GB").tag(4096)
                            Text("All (Unlimited)").tag(0)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Cached offline")
                                Spacer()
                                let cachedCount = vm.books.filter(\.isOfflineCached).count
                                Text("\(cachedCount)/\(vm.books.count) · \(formatBytes(vm.offlineBytes)) / \(budgetLabel)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .monospacedDigit()
                            }
                            InstrumentGauge(ratio: budgetUsageRatio, tint: ReaderPalette.cohortGreen)
                        }
                        if let activeTitle = vm.autoDownloadActiveTitle {
                            LabeledContent("Downloading", value: activeTitle)
                        }
                        if vm.pendingOutboxCount > 0 {
                            LabeledContent("Pending progress sync", value: "\(vm.pendingOutboxCount)")
                        }
                        Button("Download likely reads now") {
                            vm.triggerManualPrefetch()
                        }
                        .disabled(!vm.isServerConnected || vm.autoDownloadActiveTitle != nil)

                        Button("Clear offline cache", role: .destructive) {
                            Task { await vm.clearOfflineCache() }
                        }
                        .disabled(vm.offlineBytes == 0)
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

                    #if os(macOS)
                    Section("Local Library Mirror (Mac SSD)") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.localLibraryMirrorPath.isEmpty ? "Not linked" : URL(fileURLWithPath: vm.localLibraryMirrorPath).lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                Text(vm.localLibraryMirrorPath.isEmpty ? "Link a local folder to open owned files directly from SSD" : vm.localLibraryMirrorPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(ReaderPalette.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(vm.localLibraryMirrorPath.isEmpty ? "Choose…" : "Change…") {
                                vm.chooseLocalLibraryMirrorWithPanel()
                            }
                            if !vm.localLibraryMirrorPath.isEmpty {
                                Button("Clear", role: .destructive) {
                                    vm.clearLocalLibraryMirror()
                                }
                            }
                        }
                    }
                    #endif

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
                settingsFieldRow("Auto-download offline library", value: vm.autoDownloadEnabled ? "On" : "Off", isPlaceholder: false)
                Divider()
                settingsFieldRow("Storage budget", value: budgetLabel, isPlaceholder: false)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    let cachedCount = vm.books.filter(\.isOfflineCached).count
                    settingsFieldRow("Cached offline", value: "\(cachedCount)/\(vm.books.count) · \(formatBytes(vm.offlineBytes)) / \(budgetLabel)", isPlaceholder: false)
                    InstrumentGauge(ratio: budgetUsageRatio, tint: ReaderPalette.cohortGreen)
                }
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
