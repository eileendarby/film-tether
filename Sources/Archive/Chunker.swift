import Foundation
import CryptoKit

/// A file split into the blocks the upload endpoint wants, with the SHA-256
/// of each block and of the whole, produced in one pass over the bytes.
public struct ChunkedFile: Equatable, Sendable {
    public var url: URL
    public var bytes: Int
    public var chunkSize: Int
    public var sha256: String
    public var chunks: [String]

    public var chunkCount: Int { chunks.count }
}

public enum Chunker {
    /// The API's default; it caps blocks at 8 MB.
    public static let defaultChunkSize = 4 * 1024 * 1024
    public static let maxChunkSize = 8 * 1024 * 1024

    /// Read the file once, hashing each block and the running whole.
    public static func digest(fileAt url: URL, chunkSize: Int = defaultChunkSize) throws -> ChunkedFile {
        precondition(chunkSize > 0 && chunkSize <= maxChunkSize, "chunk size out of range")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var whole = SHA256()
        var chunks: [String] = []
        var total = 0
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            total += data.count
            whole.update(data: data)
            chunks.append(hex(SHA256.hash(data: data)))
            if data.count < chunkSize { break }
        }
        return ChunkedFile(url: url, bytes: total, chunkSize: chunkSize,
                           sha256: hex(whole.finalize()), chunks: chunks)
    }

    /// One block's bytes, for sending.
    public static func readChunk(fileAt url: URL, index: Int, chunkSize: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
        return try handle.read(upToCount: chunkSize) ?? Data()
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
