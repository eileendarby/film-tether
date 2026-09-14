import Foundation
import XCTest
@testable import Archive

/// Answers every request from a handler, recording what was asked.
///
/// `URLProtocol` hands over the body as a stream rather than `httpBody`, so
/// `body(of:)` drains it — without that every POST looks empty.
final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest, Data?) throws -> (Int, Data)

    static let lock = NSLock()
    private static var _handler: Handler?
    private static var _requests: [(URLRequest, Data?)] = []

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var requests: [(URLRequest, Data?)] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requests = []
    }

    static func body(of request: URLRequest) -> Data? {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.lock.lock()
        Self._requests.append((request, body))
        let handler = Self._handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

enum Mock {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func client(refreshToken: String? = "refresh-1") -> ArchiveClient {
        ArchiveClient(baseURL: URL(string: "http://127.0.0.1:5050/api/v1")!,
                      refreshToken: refreshToken, urlSession: session())
    }

    static func json(_ s: String) -> Data { Data(s.utf8) }

    static func path(_ r: URLRequest) -> String {
        r.url!.path.replacingOccurrences(of: "/api/v1", with: "")
    }

    static func jsonObject(_ data: Data?) -> [String: Any] {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }
}
