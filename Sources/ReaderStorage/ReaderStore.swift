import Foundation
import ReaderModel
import SQLite3

public enum StorageError: Error, Sendable, CustomStringConvertible {
    case sqliteFailure(String)
    case ioFailure(String)

    public var description: String {
        switch self {
        case .sqliteFailure(let msg): return "SQLite error: \(msg)"
        case .ioFailure(let msg): return "Storage I/O error: \(msg)"
        }
    }
}

/// Actor-isolated local-first WAL SQLite3 + FTS5 store, offline cache manager, and sync outbox.
public actor ReaderStore {
    private nonisolated(unsafe) var db: OpaquePointer?
    private let cacheRoot: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(dbPath: String, cacheRoot: URL? = nil) throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if let provided = cacheRoot {
            self.cacheRoot = provided
        } else if dbPath == ":memory:" {
            self.cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("cohort-reader-mem-\(UUID().uuidString)", isDirectory: true)
        } else {
            self.cacheRoot = URL(fileURLWithPath: dbPath)
                .deletingLastPathComponent()
                .appendingPathComponent("cache", isDirectory: true)
        }

        try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw StorageError.sqliteFailure(msg)
        }
        self.db = handle

        try Self.exec(handle, "PRAGMA journal_mode=WAL;")
        try Self.exec(handle, "PRAGMA synchronous=NORMAL;")
        try Self.exec(handle, "PRAGMA foreign_keys=ON;")
        try Self.createSchema(handle)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private static func createSchema(_ db: OpaquePointer?) throws {
        try Self.exec(db, """
        CREATE TABLE IF NOT EXISTS books (
            id TEXT PRIMARY KEY,
            canonical_id TEXT,
            title TEXT NOT NULL,
            author TEXT NOT NULL,
            year INTEGER,
            format TEXT NOT NULL,
            source TEXT NOT NULL,
            genre TEXT NOT NULL,
            subgenre TEXT NOT NULL,
            summary TEXT NOT NULL,
            shelf_json TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            is_offline INTEGER NOT NULL,
            local_path TEXT,
            open_access_url TEXT,
            epub_url TEXT,
            has_cover INTEGER NOT NULL,
            notes_version TEXT,
            point_x REAL,
            point_y REAL,
            last_opened_ts REAL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS books_fts USING fts5(
            book_id UNINDEXED,
            title,
            author,
            genre,
            summary
        );

        CREATE TABLE IF NOT EXISTS locators (
            book_id TEXT PRIMARY KEY,
            spine INTEGER NOT NULL,
            fraction REAL NOT NULL,
            word_offset INTEGER,
            page_index INTEGER,
            spine_count INTEGER,
            overall_progress REAL,
            updated_ts REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            started_ts REAL NOT NULL,
            duration_sec INTEGER NOT NULL,
            start_fraction REAL NOT NULL,
            end_fraction REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS margin_notes (
            book_id TEXT NOT NULL,
            note_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            PRIMARY KEY (book_id, note_id)
        );

        CREATE TABLE IF NOT EXISTS highlights (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            canonical_id TEXT,
            book_title TEXT NOT NULL,
            spine INTEGER NOT NULL,
            quote TEXT NOT NULL,
            note TEXT NOT NULL,
            sent_to_cohort INTEGER NOT NULL,
            created_ts REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS deleted_highlights (
            id TEXT PRIMARY KEY,
            deleted_ts REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS pending_sync_outbox (
            id TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL,
            created_ts REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS manifold_shards (
            prefix TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL,
            fetched_ts REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS wishlist (
            work_id TEXT PRIMARY KEY,
            created_ts REAL NOT NULL
        );
        """)
        try? Self.exec(db, "ALTER TABLE locators ADD COLUMN spine_count INTEGER;")
        try? Self.exec(db, "ALTER TABLE locators ADD COLUMN overall_progress REAL;")
    }

    // MARK: - Books & FTS5

    public func upsertBooks(_ items: [BookItem]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            for item in items {
                try upsertSingleBook(item)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func upsertSingleBook(_ item: BookItem) throws {
        let shelfJSON = String(data: (try? encoder.encode(item.shelfNames)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO books (
            id, canonical_id, title, author, year, format, source, genre, subgenre, summary,
            shelf_json, bytes, is_offline, local_path, open_access_url, epub_url, has_cover,
            notes_version, point_x, point_y, last_opened_ts
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            canonical_id = COALESCE(excluded.canonical_id, books.canonical_id),
            title = excluded.title,
            author = excluded.author,
            year = COALESCE(excluded.year, books.year),
            format = excluded.format,
            source = CASE WHEN books.local_path IS NOT NULL THEN books.source ELSE excluded.source END,
            genre = excluded.genre,
            subgenre = excluded.subgenre,
            summary = CASE WHEN excluded.summary != '' THEN excluded.summary ELSE books.summary END,
            shelf_json = excluded.shelf_json,
            bytes = CASE WHEN excluded.bytes > 0 THEN excluded.bytes ELSE books.bytes END,
            is_offline = MAX(books.is_offline, excluded.is_offline),
            local_path = COALESCE(books.local_path, excluded.local_path),
            open_access_url = COALESCE(excluded.open_access_url, books.open_access_url),
            epub_url = COALESCE(excluded.epub_url, books.epub_url),
            has_cover = MAX(books.has_cover, excluded.has_cover),
            notes_version = COALESCE(excluded.notes_version, books.notes_version),
            point_x = COALESCE(excluded.point_x, books.point_x),
            point_y = COALESCE(excluded.point_y, books.point_y),
            last_opened_ts = COALESCE(excluded.last_opened_ts, books.last_opened_ts);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, item.id)
        bindOptionalText(stmt, 2, item.canonicalId)
        bindText(stmt, 3, item.title)
        bindText(stmt, 4, item.author)
        bindOptionalInt(stmt, 5, item.year)
        bindText(stmt, 6, item.format.rawValue)
        bindText(stmt, 7, item.source.rawValue)
        bindText(stmt, 8, item.genre)
        bindText(stmt, 9, item.subgenre)
        bindText(stmt, 10, item.summary)
        bindText(stmt, 11, shelfJSON)
        sqlite3_bind_int64(stmt, 12, item.bytes)
        sqlite3_bind_int(stmt, 13, item.isOfflineCached ? 1 : 0)
        bindOptionalText(stmt, 14, item.localFilePath)
        bindOptionalText(stmt, 15, item.openAccessURL)
        bindOptionalText(stmt, 16, item.epubURL)
        sqlite3_bind_int(stmt, 17, item.hasServerCover ? 1 : 0)
        bindOptionalText(stmt, 18, item.notesVersion)
        bindOptionalDouble(stmt, 19, item.point?.x)
        bindOptionalDouble(stmt, 20, item.point?.y)
        bindOptionalDouble(stmt, 21, item.lastOpenedAt?.timeIntervalSince1970)
        try stepDone(stmt)

        // Maintain FTS row atomically
        let del = try prepare("DELETE FROM books_fts WHERE book_id = ?;")
        defer { sqlite3_finalize(del) }
        bindText(del, 1, item.id)
        try stepDone(del)

        let ins = try prepare("INSERT INTO books_fts (book_id, title, author, genre, summary) VALUES (?, ?, ?, ?, ?);")
        defer { sqlite3_finalize(ins) }
        bindText(ins, 1, item.id)
        bindText(ins, 2, item.title)
        bindText(ins, 3, item.author)
        bindText(ins, 4, "\(item.genre) \(item.subgenre)")
        bindText(ins, 5, item.summary)
        try stepDone(ins)

        if let loc = item.locator {
            try mergeLocatorInternal(bookId: item.id, remote: loc)
        }
    }

    public func listBooks() throws -> [BookItem] {
        let sql = """
        SELECT b.id, b.canonical_id, b.title, b.author, b.year, b.format, b.source, b.genre, b.subgenre,
               b.summary, b.shelf_json, b.bytes, b.is_offline, b.local_path, b.open_access_url, b.epub_url,
               b.has_cover, b.notes_version, b.point_x, b.point_y, b.last_opened_ts,
               l.spine, l.fraction, l.word_offset, l.page_index, l.updated_ts,
               l.spine_count, l.overall_progress
        FROM books b
        LEFT JOIN locators l ON l.book_id = b.id
        ORDER BY
            CASE WHEN (l.spine > 0 OR l.fraction > 0 OR COALESCE(l.overall_progress, 0) > 0) AND COALESCE(l.overall_progress, l.fraction, 0) < 0.98 THEN 0 ELSE 1 END ASC,
            COALESCE(l.updated_ts, b.last_opened_ts, 0) DESC,
            b.is_offline DESC,
            CASE b.format WHEN 'epub' THEN 0 WHEN 'pdf' THEN 1 ELSE 2 END ASC,
            b.title COLLATE NOCASE ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [BookItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(decodeBookRow(stmt))
        }
        return out
    }

    public func searchBooks(query: String, limit: Int = 40) throws -> [BookItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return try listBooks() }
        let tokens = clean
            .split { $0.isWhitespace }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return try listBooks() }
        let ftsQuery = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")

        let sql = """
        SELECT b.id, b.canonical_id, b.title, b.author, b.year, b.format, b.source, b.genre, b.subgenre,
               b.summary, b.shelf_json, b.bytes, b.is_offline, b.local_path, b.open_access_url, b.epub_url,
               b.has_cover, b.notes_version, b.point_x, b.point_y, b.last_opened_ts,
               l.spine, l.fraction, l.word_offset, l.page_index, l.updated_ts,
               l.spine_count, l.overall_progress
        FROM books_fts f
        JOIN books b ON b.id = f.book_id
        LEFT JOIN locators l ON l.book_id = b.id
        WHERE books_fts MATCH ?
        ORDER BY bm25(books_fts) ASC
        LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, ftsQuery)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [BookItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(decodeBookRow(stmt))
        }
        return out
    }

    // MARK: - Locators, Sessions & Sync Outbox

    @discardableResult
    public func saveLocator(bookId: String, locator: ReadingLocator, enqueueSync: Bool = true, readingSeconds: Int = 0, canonicalId: String? = nil) throws -> ReadingLocator {
        try exec("BEGIN IMMEDIATE;")
        do {
            let merged = try mergeLocatorInternal(bookId: bookId, remote: locator)
            let upd = try prepare("UPDATE books SET last_opened_ts = MAX(COALESCE(last_opened_ts, 0), ?) WHERE id = ?;")
            defer { sqlite3_finalize(upd) }
            sqlite3_bind_double(upd, 1, merged.updatedAt.timeIntervalSince1970)
            bindText(upd, 2, bookId)
            try stepDone(upd)

            if enqueueSync {
                let evt = PendingProgressEvent(
                    bookId: bookId,
                    canonicalId: canonicalId,
                    spine: merged.spine,
                    fraction: merged.fraction,
                    wordOffset: merged.wordOffset,
                    pageIndex: merged.pageIndex,
                    spineCount: merged.spineCount,
                    overallProgress: merged.overallProgress,
                    updatedAt: merged.updatedAt,
                    readingSeconds: readingSeconds
                )
                let data = try encoder.encode(evt)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                let ins = try prepare("INSERT INTO pending_sync_outbox (id, payload_json, created_ts) VALUES (?, ?, ?);")
                defer { sqlite3_finalize(ins) }
                bindText(ins, 1, evt.id)
                bindText(ins, 2, json)
                sqlite3_bind_double(ins, 3, evt.updatedAt.timeIntervalSince1970)
                try stepDone(ins)
            }
            try exec("COMMIT;")
            return merged
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    private func mergeLocatorInternal(bookId: String, remote: ReadingLocator) throws -> ReadingLocator {
        let sel = try prepare("SELECT spine, fraction, word_offset, page_index, updated_ts, spine_count, overall_progress FROM locators WHERE book_id = ?;")
        defer { sqlite3_finalize(sel) }
        bindText(sel, 1, bookId)
        var existing: ReadingLocator?
        if sqlite3_step(sel) == SQLITE_ROW {
            existing = ReadingLocator(
                spine: Int(sqlite3_column_int(sel, 0)),
                fraction: sqlite3_column_double(sel, 1),
                wordOffset: sqlite3_column_type(sel, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(sel, 2)),
                pageIndex: sqlite3_column_type(sel, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(sel, 3)),
                spineCount: sqlite3_column_type(sel, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(sel, 5)),
                overallProgress: sqlite3_column_type(sel, 6) == SQLITE_NULL ? nil : sqlite3_column_double(sel, 6),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(sel, 4))
            )
        }
        let chosen = ReadingLocator.adoptIfNewer(local: existing, remote: remote) ?? remote
        let up = try prepare("""
        INSERT INTO locators (book_id, spine, fraction, word_offset, page_index, updated_ts, spine_count, overall_progress)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            spine = excluded.spine,
            fraction = excluded.fraction,
            word_offset = excluded.word_offset,
            page_index = excluded.page_index,
            updated_ts = excluded.updated_ts,
            spine_count = COALESCE(excluded.spine_count, locators.spine_count),
            overall_progress = excluded.overall_progress;
        """)
        defer { sqlite3_finalize(up) }
        bindText(up, 1, bookId)
        sqlite3_bind_int(up, 2, Int32(chosen.spine))
        sqlite3_bind_double(up, 3, chosen.fraction)
        bindOptionalInt(up, 4, chosen.wordOffset)
        bindOptionalInt(up, 5, chosen.pageIndex)
        sqlite3_bind_double(up, 6, chosen.updatedAt.timeIntervalSince1970)
        bindOptionalInt(up, 7, chosen.spineCount)
        bindOptionalDouble(up, 8, chosen.overallProgress)
        try stepDone(up)
        return chosen
    }

    public func pendingSyncEvents() throws -> [PendingProgressEvent] {
        let stmt = try prepare("SELECT payload_json FROM pending_sync_outbox ORDER BY created_ts ASC;")
        defer { sqlite3_finalize(stmt) }
        var out: [PendingProgressEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0),
               let data = String(cString: c).data(using: .utf8),
               let evt = try? decoder.decode(PendingProgressEvent.self, from: data) {
                out.append(evt)
            }
        }
        return out
    }

    public func markSyncEventsDelivered(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for id in ids {
                let del = try prepare("DELETE FROM pending_sync_outbox WHERE id = ?;")
                defer { sqlite3_finalize(del) }
                bindText(del, 1, id)
                try stepDone(del)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Margin Notes & Highlights

    public func saveMarginNotes(bookId: String, notes: [MarginNote]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            let del = try prepare("DELETE FROM margin_notes WHERE book_id = ?;")
            defer { sqlite3_finalize(del) }
            bindText(del, 1, bookId)
            try stepDone(del)

            for note in notes {
                let data = try encoder.encode(note)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                let ins = try prepare("INSERT INTO margin_notes (book_id, note_id, payload_json) VALUES (?, ?, ?);")
                defer { sqlite3_finalize(ins) }
                bindText(ins, 1, bookId)
                bindText(ins, 2, note.id)
                bindText(ins, 3, json)
                try stepDone(ins)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func loadMarginNotes(bookId: String) throws -> [MarginNote] {
        let stmt = try prepare("SELECT payload_json FROM margin_notes WHERE book_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, bookId)
        var out: [MarginNote] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0),
               let data = String(cString: c).data(using: .utf8),
               let note = try? decoder.decode(MarginNote.self, from: data) {
                out.append(note)
            }
        }
        return out
    }

    public func saveHighlight(_ highlight: ReadingHighlight) throws {
        let stmt = try prepare("""
        INSERT INTO highlights (id, book_id, canonical_id, book_title, spine, quote, note, sent_to_cohort, created_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            note = excluded.note,
            sent_to_cohort = excluded.sent_to_cohort;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, highlight.id)
        bindText(stmt, 2, highlight.bookId)
        bindOptionalText(stmt, 3, highlight.canonicalId)
        bindText(stmt, 4, highlight.bookTitle)
        sqlite3_bind_int(stmt, 5, Int32(highlight.spine))
        bindText(stmt, 6, highlight.quote)
        bindText(stmt, 7, highlight.note)
        sqlite3_bind_int(stmt, 8, highlight.sentToCohort ? 1 : 0)
        sqlite3_bind_double(stmt, 9, highlight.createdAt.timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func listHighlights(bookId: String? = nil) throws -> [ReadingHighlight] {
        let sql = bookId == nil
            ? "SELECT id, book_id, canonical_id, book_title, spine, quote, note, sent_to_cohort, created_ts FROM highlights ORDER BY created_ts DESC;"
            : "SELECT id, book_id, canonical_id, book_title, spine, quote, note, sent_to_cohort, created_ts FROM highlights WHERE book_id = ? ORDER BY created_ts DESC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let bookId { bindText(stmt, 1, bookId) }
        var out: [ReadingHighlight] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ReadingHighlight(
                id: columnText(stmt, 0),
                bookId: columnText(stmt, 1),
                canonicalId: columnOptionalText(stmt, 2),
                bookTitle: columnText(stmt, 3),
                spine: Int(sqlite3_column_int(stmt, 4)),
                quote: columnText(stmt, 5),
                note: columnText(stmt, 6),
                sentToCohort: sqlite3_column_int(stmt, 7) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            ))
        }
        return out
    }

    public func deleteHighlight(id: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            let stmt = try prepare("DELETE FROM highlights WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            try stepDone(stmt)

            let tomb = try prepare("""
            INSERT INTO deleted_highlights (id, deleted_ts) VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET deleted_ts = excluded.deleted_ts;
            """)
            defer { sqlite3_finalize(tomb) }
            bindText(tomb, 1, id)
            sqlite3_bind_double(tomb, 2, Date().timeIntervalSince1970)
            try stepDone(tomb)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func listAllHighlights() throws -> [ReadingHighlight] {
        try listHighlights(bookId: nil)
    }

    public func listDeletedHighlightIds() throws -> [String] {
        let stmt = try prepare("SELECT id FROM deleted_highlights;")
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(columnText(stmt, 0))
        }
        return out
    }

    public func mergeRemoteHighlights(_ items: [ReadingHighlight], deletedIds: [String]) throws {
        let deletedSet = Set(deletedIds)
        try exec("BEGIN IMMEDIATE;")
        do {
            for did in deletedIds {
                let del = try prepare("DELETE FROM highlights WHERE id = ?;")
                defer { sqlite3_finalize(del) }
                bindText(del, 1, did)
                try stepDone(del)

                let tomb = try prepare("""
                INSERT INTO deleted_highlights (id, deleted_ts) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET deleted_ts = MAX(deleted_ts, excluded.deleted_ts);
                """)
                defer { sqlite3_finalize(tomb) }
                bindText(tomb, 1, did)
                sqlite3_bind_double(tomb, 2, Date().timeIntervalSince1970)
                try stepDone(tomb)
            }

            let localDeleted = Set(try listDeletedHighlightIds())
            for h in items {
                if deletedSet.contains(h.id) || localDeleted.contains(h.id) {
                    continue
                }
                let ins = try prepare("""
                INSERT INTO highlights (id, book_id, canonical_id, book_title, spine, quote, note, sent_to_cohort, created_ts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    note = excluded.note,
                    sent_to_cohort = MAX(highlights.sent_to_cohort, excluded.sent_to_cohort);
                """)
                defer { sqlite3_finalize(ins) }
                bindText(ins, 1, h.id)
                bindText(ins, 2, h.bookId)
                bindOptionalText(ins, 3, h.canonicalId)
                bindText(ins, 4, h.bookTitle)
                sqlite3_bind_int(ins, 5, Int32(h.spine))
                bindText(ins, 6, h.quote)
                bindText(ins, 7, h.note)
                sqlite3_bind_int(ins, 8, h.sentToCohort ? 1 : 0)
                sqlite3_bind_double(ins, 9, h.createdAt.timeIntervalSince1970)
                try stepDone(ins)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Offline File Cache (Excluded from iCloud Device Backup)

    public func cachedFileURL(bookId: String, format: BookFormat) -> URL {
        let safeId = bookId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
        let ext = format == .pdf ? "pdf" : "epub"
        return cacheRoot.appendingPathComponent("books", isDirectory: true).appendingPathComponent("\(safeId).\(ext)")
    }

    public func storeOfflineBookData(_ data: Data, bookId: String, format: BookFormat) throws -> URL {
        let dest = cachedFileURL(bookId: bookId, format: format)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDest = dest
        try? mutableDest.setResourceValues(values)

        let upd = try prepare("UPDATE books SET is_offline = 1, local_path = ?, bytes = ? WHERE id = ?;")
        defer { sqlite3_finalize(upd) }
        bindText(upd, 1, dest.path)
        sqlite3_bind_int64(upd, 2, Int64(data.count))
        bindText(upd, 3, bookId)
        try stepDone(upd)
        return dest
    }

    public func evictOfflineBook(bookId: String) throws {
        let sel = try prepare("SELECT local_path FROM books WHERE id = ?;")
        defer { sqlite3_finalize(sel) }
        bindText(sel, 1, bookId)
        var path: String?
        if sqlite3_step(sel) == SQLITE_ROW {
            path = columnOptionalText(sel, 0)
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let upd = try prepare("UPDATE books SET is_offline = 0, local_path = NULL WHERE id = ?;")
        defer { sqlite3_finalize(upd) }
        bindText(upd, 1, bookId)
        try stepDone(upd)
    }

    /// Removes cached files and offline flags for remote/open-access editions while keeping user-imported files intact.
    public func evictAllCachedRemoteBooks() throws {
        let sel = try prepare("SELECT local_path FROM books WHERE is_offline = 1 AND source != ?;")
        defer { sqlite3_finalize(sel) }
        bindText(sel, 1, BookSource.localImport.rawValue)
        var paths: [String] = []
        while sqlite3_step(sel) == SQLITE_ROW {
            if let path = columnOptionalText(sel, 0) {
                paths.append(path)
            }
        }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let upd = try prepare("UPDATE books SET is_offline = 0, local_path = NULL WHERE is_offline = 1 AND source != ?;")
        defer { sqlite3_finalize(upd) }
        bindText(upd, 1, BookSource.localImport.rawValue)
        try stepDone(upd)
    }

    public func cachedBookBytes() -> Int64 {
        let booksDir = cacheRoot.appendingPathComponent("books", isDirectory: true)
        guard let enumFiles = FileManager.default.enumerator(at: booksDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumFiles {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    public func saveShardCache(prefix: String, jsonData: Data) throws {
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        let stmt = try prepare("""
        INSERT INTO manifold_shards (prefix, payload_json, fetched_ts) VALUES (?, ?, ?)
        ON CONFLICT(prefix) DO UPDATE SET payload_json = excluded.payload_json, fetched_ts = excluded.fetched_ts;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, prefix.lowercased())
        bindText(stmt, 2, json)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func loadShardCache(prefix: String) throws -> Data? {
        let stmt = try prepare("SELECT payload_json FROM manifold_shards WHERE prefix = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, prefix.lowercased())
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0).data(using: .utf8)
    }

    // MARK: - Discovery Wishlist

    public func listWishlistIds() throws -> Set<String> {
        let stmt = try prepare("SELECT work_id FROM wishlist;")
        defer { sqlite3_finalize(stmt) }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let wid = columnText(stmt, 0)
            if !wid.isEmpty { out.insert(wid) }
        }
        return out
    }

    public func setWishlisted(workId: String, saved: Bool) throws {
        if saved {
            let stmt = try prepare("INSERT OR REPLACE INTO wishlist (work_id, created_ts) VALUES (?, ?);")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, workId)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            try stepDone(stmt)
        } else {
            let stmt = try prepare("DELETE FROM wishlist WHERE work_id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, workId)
            try stepDone(stmt)
        }
    }

    // MARK: - SQLite Helpers

    private func exec(_ sql: String) throws {
        try Self.exec(db, sql)
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errPtr) != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "exec error"
            sqlite3_free(errPtr)
            throw StorageError.sqliteFailure(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "prepare error"
            throw StorageError.sqliteFailure(msg)
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "step error"
            throw StorageError.sqliteFailure(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, idx, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value {
            bindText(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, idx, Int32(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    private func columnOptionalText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return columnText(stmt, idx)
    }

    private func decodeBookRow(_ stmt: OpaquePointer?) -> BookItem {
        let shelfStr = columnText(stmt, 10)
        let shelves = (try? decoder.decode([String].self, from: Data(shelfStr.utf8))) ?? []
        let px = sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 18)
        let py = sqlite3_column_type(stmt, 19) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 19)
        let point = (px != nil && py != nil) ? MapPoint(x: px!, y: py!) : nil
        let lastOpened = sqlite3_column_type(stmt, 20) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 20))

        var locator: ReadingLocator?
        if sqlite3_column_type(stmt, 21) != SQLITE_NULL {
            locator = ReadingLocator(
                spine: Int(sqlite3_column_int(stmt, 21)),
                fraction: sqlite3_column_double(stmt, 22),
                wordOffset: sqlite3_column_type(stmt, 23) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 23)),
                pageIndex: sqlite3_column_type(stmt, 24) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 24)),
                spineCount: sqlite3_column_type(stmt, 26) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 26)),
                overallProgress: sqlite3_column_type(stmt, 27) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 27),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 25))
            )
        }

        return BookItem(
            id: columnText(stmt, 0),
            canonicalId: columnOptionalText(stmt, 1),
            title: columnText(stmt, 2),
            author: columnText(stmt, 3),
            year: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4)),
            format: BookFormat(rawValue: columnText(stmt, 5)) ?? .epub,
            source: BookSource(rawValue: columnText(stmt, 6)) ?? .showcase,
            genre: columnText(stmt, 7),
            subgenre: columnText(stmt, 8),
            summary: columnText(stmt, 9),
            shelfNames: shelves,
            bytes: sqlite3_column_int64(stmt, 11),
            isOfflineCached: sqlite3_column_int(stmt, 12) != 0,
            localFilePath: columnOptionalText(stmt, 13),
            openAccessURL: columnOptionalText(stmt, 14),
            epubURL: columnOptionalText(stmt, 15),
            hasServerCover: sqlite3_column_int(stmt, 16) != 0,
            notesVersion: columnOptionalText(stmt, 17),
            locator: locator,
            point: point,
            lastOpenedAt: lastOpened
        )
    }
}

public enum CohortHandoff {
    public static func makeDraftURL(for draft: CohortCardDraft) -> URL? {
        var comps = URLComponents()
        comps.scheme = "cohort"
        comps.host = "draft"
        var items = [
            URLQueryItem(name: "source", value: draft.sourceTitle),
            URLQueryItem(name: "quote", value: String(draft.quote.prefix(600))),
            URLQueryItem(name: "prompt", value: draft.promptHint),
            URLQueryItem(name: "tags", value: draft.tags.joined(separator: ",")),
        ]
        if let cid = draft.canonicalId {
            items.append(URLQueryItem(name: "canonicalId", value: cid))
        }
        comps.queryItems = items
        return comps.url
    }

    public static func writeDropFile(for draft: CohortCardDraft, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        let file = directory.appendingPathComponent("cohort-draft-\(UUID().uuidString.prefix(8)).json")
        try data.write(to: file, options: .atomic)
        return file
    }
}
