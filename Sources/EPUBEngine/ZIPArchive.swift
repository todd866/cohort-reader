import Foundation
import zlib

public enum ZipError: Error, Sendable, CustomStringConvertible {
    case invalidArchive(String)
    case unsafePath(String)
    case unsupportedMethod(UInt16)
    case limitExceeded(String)
    case compressionFailed(String)

    public var description: String {
        switch self {
        case .invalidArchive(let msg): return "Invalid ZIP archive: \(msg)"
        case .unsafePath(let path): return "Unsafe ZIP entry path: \(path)"
        case .unsupportedMethod(let method): return "Unsupported ZIP compression method: \(method)"
        case .limitExceeded(let msg): return "ZIP limit exceeded: \(msg)"
        case .compressionFailed(let msg): return "ZIP compression error: \(msg)"
        }
    }
}

public struct ZipLimits: Sendable {
    public var maxEntries: Int
    public var maxEntryBytes: Int
    public var maxTotalBytes: Int
    public var maxCompressionRatio: Double

    public static let `default` = ZipLimits(
        maxEntries: 50_000,
        maxEntryBytes: 256 * 1024 * 1024,
        maxTotalBytes: 512 * 1024 * 1024,
        maxCompressionRatio: 250
    )

    public init(maxEntries: Int, maxEntryBytes: Int, maxTotalBytes: Int, maxCompressionRatio: Double) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxCompressionRatio = maxCompressionRatio
    }
}

/// Clean-room MIT ZIP32/ZIP64 reader & writer using system `zlib`.
public enum ZIPArchive {
    public struct Entry: Sendable {
        public var path: String
        public var data: Data
        public var compress: Bool

        public init(path: String, data: Data, compress: Bool = true) {
            self.path = path
            self.data = data
            self.compress = compress
        }
    }

    public static func read(from url: URL, limits: ZipLimits = .default) throws -> [String: Data] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try read(from: data, limits: limits)
    }

    public static func read(from archiveData: Data, limits: ZipLimits = .default) throws -> [String: Data] {
        guard archiveData.count >= 22 else {
            throw ZipError.invalidArchive("Archive shorter than EOCD")
        }

        let eocdOffset = try findEOCD(in: archiveData)
        var cdOffset = UInt64(readUInt32(archiveData, at: eocdOffset + 16))
        var entryCount = UInt64(readUInt16(archiveData, at: eocdOffset + 10))

        if eocdOffset >= 20, readUInt32(archiveData, at: eocdOffset - 20) == 0x0706_4b50 {
            let z64Offset = Int(readUInt64(archiveData, at: eocdOffset - 12))
            if z64Offset >= 0 && z64Offset + 56 <= archiveData.count && readUInt32(archiveData, at: z64Offset) == 0x0606_4b50 {
                if entryCount == 0xFFFF { entryCount = readUInt64(archiveData, at: z64Offset + 32) }
                if cdOffset == 0xFFFF_FFFF { cdOffset = readUInt64(archiveData, at: z64Offset + 48) }
            }
        }

        guard entryCount <= UInt64(limits.maxEntries) else {
            throw ZipError.limitExceeded("Entry count \(entryCount) exceeds maximum")
        }

        var cursor = Int(cdOffset)
        var result: [String: Data] = [:]
        var totalDecoded = 0

        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= archiveData.count, readUInt32(archiveData, at: cursor) == 0x0201_4b50 else {
                throw ZipError.invalidArchive("Corrupt central directory header")
            }

            let flags = readUInt16(archiveData, at: cursor + 8)
            let method = readUInt16(archiveData, at: cursor + 10)
            let expectedCRC = readUInt32(archiveData, at: cursor + 16)
            var compressedSize = UInt64(readUInt32(archiveData, at: cursor + 20))
            var uncompressedSize = UInt64(readUInt32(archiveData, at: cursor + 24))
            let nameLen = Int(readUInt16(archiveData, at: cursor + 28))
            let extraLen = Int(readUInt16(archiveData, at: cursor + 30))
            let commentLen = Int(readUInt16(archiveData, at: cursor + 32))
            let externalAttrs = readUInt32(archiveData, at: cursor + 38)
            var localHeaderOffset = UInt64(readUInt32(archiveData, at: cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLen
            let nextRecord = extraStart + extraLen + commentLen
            guard nextRecord <= archiveData.count else {
                throw ZipError.invalidArchive("Central directory header truncated")
            }

            let nameData = archiveData[nameStart..<extraStart]
            guard let path = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) else {
                throw ZipError.invalidArchive("Unreadable entry path")
            }

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                parseZip64Extra(
                    archiveData[extraStart..<(extraStart + extraLen)],
                    uncompressedSize: &uncompressedSize,
                    compressedSize: &compressedSize,
                    localOffset: &localHeaderOffset
                )
            }

            cursor = nextRecord
            if path.hasSuffix("/") { continue }

            let unixMode = (externalAttrs >> 16) & 0xFFFF
            if (unixMode & 0o170000) == 0o120000 {
                throw ZipError.unsafePath(path)
            }
            if (flags & 0x0001) != 0 {
                throw ZipError.invalidArchive("Encrypted entry not supported: \(path)")
            }
            try validateSafePath(path)

            guard uncompressedSize <= UInt64(limits.maxEntryBytes) else {
                throw ZipError.limitExceeded("Entry \(path) exceeds limit")
            }
            if uncompressedSize > 0 {
                if compressedSize == 0 || Double(uncompressedSize) / Double(compressedSize) > limits.maxCompressionRatio {
                    throw ZipError.limitExceeded("Entry \(path) exceeds compression ratio")
                }
            }
            let decodedCount = Int(uncompressedSize)
            guard totalDecoded <= limits.maxTotalBytes - decodedCount else {
                throw ZipError.limitExceeded("Archive exceeds total byte budget")
            }
            totalDecoded += decodedCount

            let lfh = Int(localHeaderOffset)
            guard lfh + 30 <= archiveData.count, readUInt32(archiveData, at: lfh) == 0x0403_4b50 else {
                throw ZipError.invalidArchive("Missing local file header for \(path)")
            }
            let lfhNameLen = Int(readUInt16(archiveData, at: lfh + 26))
            let lfhExtraLen = Int(readUInt16(archiveData, at: lfh + 28))
            let dataStart = lfh + 30 + lfhNameLen + lfhExtraLen
            let dataEnd = dataStart + Int(compressedSize)
            guard dataEnd <= archiveData.count else {
                throw ZipError.invalidArchive("Truncated payload for \(path)")
            }

            let rawPayload = Data(archiveData[dataStart..<dataEnd])
            let decoded: Data
            switch method {
            case 0:
                decoded = rawPayload
            case 8:
                decoded = try inflateRaw(rawPayload, maxBytes: limits.maxEntryBytes)
            default:
                throw ZipError.unsupportedMethod(method)
            }

            guard decoded.count == decodedCount else {
                throw ZipError.invalidArchive("Size mismatch for \(path)")
            }
            guard crc32Checksum(decoded) == expectedCRC else {
                throw ZipError.invalidArchive("CRC32 mismatch for \(path)")
            }
            result[path] = decoded
        }

        return result
    }

    public static func write(_ entries: [Entry]) throws -> Data {
        var out = Data()
        struct Record {
            var pathData: Data
            var crc: UInt32
            var compressedSize: UInt32
            var uncompressedSize: UInt32
            var method: UInt16
            var localOffset: UInt32
        }
        var records: [Record] = []
        records.reserveCapacity(entries.count)

        for entry in entries {
            try validateSafePath(entry.path)
            let pathData = Data(entry.path.utf8)
            let crc = crc32Checksum(entry.data)
            let rawCount = UInt32(entry.data.count)
            let payload: Data
            let method: UInt16
            if entry.compress && !entry.data.isEmpty {
                payload = try deflateRaw(entry.data)
                method = 8
            } else {
                payload = entry.data
                method = 0
            }

            let offset = UInt32(out.count)
            appendUInt32(&out, 0x0403_4b50)
            appendUInt16(&out, 20)
            appendUInt16(&out, 0x0800) // UTF-8
            appendUInt16(&out, method)
            appendUInt16(&out, 0)
            appendUInt16(&out, 0)
            appendUInt32(&out, crc)
            appendUInt32(&out, UInt32(payload.count))
            appendUInt32(&out, rawCount)
            appendUInt16(&out, UInt16(pathData.count))
            appendUInt16(&out, 0)
            out.append(pathData)
            out.append(payload)

            records.append(Record(
                pathData: pathData,
                crc: crc,
                compressedSize: UInt32(payload.count),
                uncompressedSize: rawCount,
                method: method,
                localOffset: offset
            ))
        }

        let cdStart = UInt32(out.count)
        for rec in records {
            appendUInt32(&out, 0x0201_4b50)
            appendUInt16(&out, 20)
            appendUInt16(&out, 20)
            appendUInt16(&out, 0x0800)
            appendUInt16(&out, rec.method)
            appendUInt16(&out, 0)
            appendUInt16(&out, 0)
            appendUInt32(&out, rec.crc)
            appendUInt32(&out, rec.compressedSize)
            appendUInt32(&out, rec.uncompressedSize)
            appendUInt16(&out, UInt16(rec.pathData.count))
            appendUInt16(&out, 0)
            appendUInt16(&out, 0)
            appendUInt16(&out, 0)
            appendUInt16(&out, 0)
            appendUInt32(&out, 0)
            appendUInt32(&out, rec.localOffset)
            out.append(rec.pathData)
        }
        let cdSize = UInt32(out.count) - cdStart

        appendUInt32(&out, 0x0605_4b50)
        appendUInt16(&out, 0)
        appendUInt16(&out, 0)
        appendUInt16(&out, UInt16(records.count))
        appendUInt16(&out, UInt16(records.count))
        appendUInt32(&out, cdSize)
        appendUInt32(&out, cdStart)
        appendUInt16(&out, 0)
        return out
    }

    public static func validateSafePath(_ rawPath: String) throws {
        if rawPath.isEmpty || rawPath.hasPrefix("/") || rawPath.hasPrefix("\\") || rawPath.contains("\0") {
            throw ZipError.unsafePath(rawPath)
        }
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts where part == ".." || part == "." {
            throw ZipError.unsafePath(rawPath)
        }
        if rawPath.contains("\\") {
            throw ZipError.unsafePath(rawPath)
        }
    }

    private static func findEOCD(in data: Data) throws -> Int {
        let minOffset = max(0, data.count - 65557)
        var i = data.count - 22
        while i >= minOffset {
            if readUInt32(data, at: i) == 0x0605_4b50 {
                let commentLen = Int(readUInt16(data, at: i + 20))
                if i + 22 + commentLen == data.count {
                    return i
                }
            }
            i -= 1
        }
        throw ZipError.invalidArchive("End of central directory not found")
    }

    private static func parseZip64Extra(
        _ slice: Data.SubSequence,
        uncompressedSize: inout UInt64,
        compressedSize: inout UInt64,
        localOffset: inout UInt64
    ) {
        let bytes = Data(slice)
        var pos = 0
        while pos + 4 <= bytes.count {
            let tag = readUInt16(bytes, at: pos)
            let len = Int(readUInt16(bytes, at: pos + 2))
            pos += 4
            guard pos + len <= bytes.count else { break }
            if tag == 0x0001 {
                var f = pos
                if uncompressedSize == 0xFFFF_FFFF && f + 8 <= pos + len {
                    uncompressedSize = readUInt64(bytes, at: f)
                    f += 8
                }
                if compressedSize == 0xFFFF_FFFF && f + 8 <= pos + len {
                    compressedSize = readUInt64(bytes, at: f)
                    f += 8
                }
                if localOffset == 0xFFFF_FFFF && f + 8 <= pos + len {
                    localOffset = readUInt64(bytes, at: f)
                }
                break
            }
            pos += len
        }
    }

    private static func inflateRaw(_ input: Data, maxBytes: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let rc = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else {
            throw ZipError.compressionFailed("inflateInit2 failed: \(rc)")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try input.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)

            while true {
                let status = buffer.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    if output.count + produced > maxBytes {
                        throw ZipError.limitExceeded("Inflated size exceeds \(maxBytes) bytes")
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK {
                    throw ZipError.compressionFailed("inflate failed with code \(status)")
                }
                if produced == 0 && stream.avail_in == 0 {
                    throw ZipError.compressionFailed("Truncated deflate stream")
                }
            }
        }
        return output
    }

    private static func deflateRaw(_ input: Data) throws -> Data {
        var stream = z_stream()
        let rc = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard rc == Z_OK else {
            throw ZipError.compressionFailed("deflateInit2 failed: \(rc)")
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 32_768
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try input.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)

            while true {
                let status = buffer.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR {
                    throw ZipError.compressionFailed("deflate failed with code \(status)")
                }
            }
        }
        return output
    }

    private static func crc32Checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, base, uInt(data.count)))
        }
    }

    private static func readUInt16(_ d: Data, at offset: Int) -> UInt16 {
        UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8)
    }

    private static func readUInt32(_ d: Data, at offset: Int) -> UInt32 {
        UInt32(d[offset])
            | (UInt32(d[offset + 1]) << 8)
            | (UInt32(d[offset + 2]) << 16)
            | (UInt32(d[offset + 3]) << 24)
    }

    private static func readUInt64(_ d: Data, at offset: Int) -> UInt64 {
        UInt64(readUInt32(d, at: offset)) | (UInt64(readUInt32(d, at: offset + 4)) << 32)
    }

    private static func appendUInt16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
    }

    private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff))
        d.append(UInt8((v >> 24) & 0xff))
    }
}
