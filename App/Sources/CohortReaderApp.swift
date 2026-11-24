import ReaderKit
import ReaderStorage
import SwiftUI

@main
struct CohortReaderApp: App {
    @State private var vm: ReaderViewModel

    init() {
        let store = Self.makePersistentStore()
        _vm = State(initialValue: ReaderViewModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ReaderRootView(vm: vm)
                .task {
                    await vm.bootstrap(loadSampleBook: true)
                }
                .onOpenURL { url in
                    Task {
                        if url.isFileURL {
                            await vm.importLocalFile(from: url)
                        }
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 760)
        #endif
    }

    private static func makePersistentStore() -> ReaderStore {
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dbDir = appSupport.appendingPathComponent("CohortReader", isDirectory: true)
            let cacheRoot = docs.appendingPathComponent("CohortReaderCache", isDirectory: true)
            do {
                try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                let dbURL = dbDir.appendingPathComponent("cohort-reader.sqlite")
                return try ReaderStore(dbPath: dbURL.path, cacheRoot: cacheRoot)
            } catch {
                // Fall back to in-memory store only if sandbox directories fail.
            }
        }
        return (try? ReaderStore(dbPath: ":memory:"))!
    }
}
