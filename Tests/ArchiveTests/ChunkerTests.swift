import XCTest
import CryptoKit
@testable import Archive

final class ChunkerTests: XCTestCase {
    private func tempFile(bytes: Int) throws -> (URL, Data) {
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8((i * 31 + 7) & 0xff) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-\(UUID().uuidString).bin")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, data)
    }

    private func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testSplitsAndHashesInOnePass() throws {
        let (url, data) = try tempFile(bytes: 10_000)
        let file = try Chunker.digest(fileAt: url, chunkSize: 4096)
        XCTAssertEqual(file.bytes, 10_000)
        XCTAssertEqual(file.chunkCount, 3, "4096 + 4096 + 1808")
        XCTAssertEqual(file.sha256, hex(SHA256.hash(data: data)))
        XCTAssertEqual(file.chunks[0], hex(SHA256.hash(data: data[0..<4096])))
        XCTAssertEqual(file.chunks[1], hex(SHA256.hash(data: data[4096..<8192])))
        XCTAssertEqual(file.chunks[2], hex(SHA256.hash(data: data[8192..<10_000])))
    }

    func testExactMultipleHasNoEmptyTrailingChunk() throws {
        let (url, _) = try tempFile(bytes: 8192)
        let file = try Chunker.digest(fileAt: url, chunkSize: 4096)
        XCTAssertEqual(file.chunkCount, 2)
    }

    func testReadChunkMatchesDigest() throws {
        let (url, data) = try tempFile(bytes: 10_000)
        let last = try Chunker.readChunk(fileAt: url, index: 2, chunkSize: 4096)
        XCTAssertEqual(last, data[8192..<10_000])
        XCTAssertEqual(hex(SHA256.hash(data: last)), try Chunker.digest(fileAt: url, chunkSize: 4096).chunks[2])
    }

    func testEmptyFile() throws {
        let (url, _) = try tempFile(bytes: 0)
        let file = try Chunker.digest(fileAt: url, chunkSize: 4096)
        XCTAssertEqual(file.bytes, 0)
        XCTAssertEqual(file.chunkCount, 0)
    }
}
