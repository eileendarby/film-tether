import XCTest
@testable import Archive

final class ClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testBaseURLParsing() throws {
        XCTAssertEqual(try ArchiveClient.parseBaseURL(" 127.0.0.1:5050/api/v1 ").absoluteString, "https://127.0.0.1:5050/api/v1")
        XCTAssertEqual(try ArchiveClient.parseBaseURL("http://127.0.0.1:5050/api/v1").absoluteString, "http://127.0.0.1:5050/api/v1")
        XCTAssertThrowsError(try ArchiveClient.parseBaseURL(""))
        XCTAssertThrowsError(try ArchiveClient.parseBaseURL("ftp://x/api"))
    }

    /// The client starts with only a refresh token; the first authenticated
    /// call refreshes, then a 401 mid-session refreshes again and retries once.
    func testRefreshOn401ThenRetry() async throws {
        var accessTokens = ["A1", "A2"]
        var served: [String] = []
        MockURLProtocol.handler = { req, body in
            let path = Mock.path(req)
            if path == "/auth/refresh" {
                let token = accessTokens.removeFirst()
                XCTAssertEqual(Mock.jsonObject(body)["refresh_token"] as? String, "refresh-1")
                return (200, Mock.json(#"{ "access_token": "\#(token)", "expires_in": 900, "session": 1 }"#))
            }
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            served.append(auth)
            if auth == "Bearer A1" {
                return (401, Mock.json(#"{ "error": "Token expired" }"#))
            }
            return (200, Mock.json(#"{ "show": "T00316", "total": 0, "types": [] }"#))
        }
        let client = Mock.client()
        let inv = try await client.inventory(show: "T00316")
        XCTAssertEqual(inv.show, "T00316")
        XCTAssertEqual(served, ["Bearer A1", "Bearer A2"], "one 401, one retry with the new token")
        XCTAssertTrue(accessTokens.isEmpty, "both refreshes were used")
    }

    func testRefusedRefreshSignsOut() async {
        MockURLProtocol.handler = { req, _ in
            (401, Mock.json(#"{ "error": "Invalid credentials" }"#))
        }
        let client = Mock.client()
        do {
            _ = try await client.inventory(show: "T00316")
            XCTFail("expected unauthenticated")
        } catch let e as ArchiveError {
            XCTAssertEqual(e, .unauthenticated)
        } catch {
            XCTFail("\(error)")
        }
        let signedIn = await client.isSignedIn
        XCTAssertFalse(signedIn, "a refused refresh is a revoked device: stop, don't loop")
    }

    func testNoRefreshTokenIsUnauthenticatedWithoutANetworkCall() async {
        MockURLProtocol.handler = { _, _ in XCTFail("no request expected"); return (500, Data()) }
        let client = Mock.client(refreshToken: nil)
        do {
            _ = try await client.inventory(show: "T00316")
            XCTFail()
        } catch let e as ArchiveError {
            XCTAssertEqual(e, .unauthenticated)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testErrorShape() async {
        MockURLProtocol.handler = { req, _ in
            if Mock.path(req) == "/auth/refresh" {
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            }
            return (404, Mock.json(#"{ "error": "No such show: T99999" }"#))
        }
        do {
            _ = try await Mock.client().show(id: "T99999")
            XCTFail()
        } catch let e as ArchiveError {
            XCTAssertEqual(e, .http(status: 404, message: "No such show: T99999"))
            XCTAssertEqual(e.errorDescription, "No such show: T99999 (HTTP 404)")
        } catch { XCTFail("\(error)") }
    }

    func testLoginStoresTokensAndSendsDevice() async throws {
        MockURLProtocol.handler = { req, body in
            switch Mock.path(req) {
            case "/auth/code":
                XCTAssertEqual(Mock.jsonObject(body)["login"] as? String, "scanner")
                XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
                return (200, Mock.json(#"{ "expires_in": 600, "sent": true }"#))
            case "/auth/login":
                let o = Mock.jsonObject(body)
                XCTAssertEqual(o["code"] as? String, "197458")
                XCTAssertEqual(o["device"] as? String, "station 2")
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900, "refresh_token": "R", "session": 7, "device": "station 2" }"#))
            case "/shows/T00316":
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer A")
                return (200, Mock.json(#"{ "id": "T00316" }"#))
            default:
                return (404, Mock.json(#"{ "error": "nope" }"#))
            }
        }
        let client = Mock.client(refreshToken: nil)
        let code = try await client.requestCode(login: "scanner", password: "pw")
        XCTAssertTrue(code.sent)
        let login = try await client.login(login: "scanner", password: "pw", code: "197458", device: "station 2")
        XCTAssertEqual(login.session, 7)
        let stored = await client.refreshToken
        XCTAssertEqual(stored, "R")
        // The access token from login is used directly; no refresh round-trip.
        _ = try await client.show(id: "T00316")
        XCTAssertFalse(MockURLProtocol.requests.contains { Mock.path($0.0) == "/auth/refresh" })
    }

    func testRegisterAssetsBody() async throws {
        MockURLProtocol.handler = { req, body in
            switch Mock.path(req) {
            case "/auth/refresh":
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            case "/shows/T00316/assets":
                XCTAssertEqual(req.httpMethod, "POST")
                let o = Mock.jsonObject(body)
                XCTAssertEqual(o["type"] as? String, "N")
                XCTAssertEqual(o["roll"] as? String, "A")
                XCTAssertEqual(o["first"] as? String, "1")
                XCTAssertEqual(o["last"] as? String, "4")
                XCTAssertEqual(o["format"] as? Int, 2)
                XCTAssertNil(o["number"] ?? nil, "absent, not null, for a range")
                return (201, Mock.json(#"{ "show": "T00316", "count": 4, "assets": [ { "assetid": "T00316_NA0001_00", "number": "0001" } ] }"#))
            default:
                return (404, Mock.json(#"{ "error": "nope" }"#))
            }
        }
        let batch = try await Mock.client().registerAssets(show: "T00316", type: "N", roll: "A", first: "1", last: "4", format: 2)
        XCTAssertEqual(batch.assets.first?.assetid, "T00316_NA0001_00")
    }

    func testSearchQueryAndPaging() async throws {
        MockURLProtocol.handler = { req, _ in
            if Mock.path(req) == "/auth/refresh" {
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            }
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertTrue(q.contains(URLQueryItem(name: "q", value: "iceman")))
            XCTAssertTrue(q.contains(URLQueryItem(name: "perpage", value: "25")))
            return (200, Mock.json(#"{ "total": 0, "page": 1, "perpage": 25, "shows": [] }"#))
        }
        let page = try await Mock.client().searchShows(query: "iceman")
        XCTAssertEqual(page.total, 0)
    }

    func testImageBytesAndNotMadeYet() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        MockURLProtocol.handler = { req, _ in
            switch Mock.path(req) {
            case "/auth/refresh":
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            case "/shows/T00316/assets/NA0001/images/thumbnail":
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer A")
                return (200, png)
            case "/shows/T00316/assets/NA0002/images/thumbnail":
                return (404, Mock.json(#"{ "error": "The thumbnail of T00316_NA0002_00 has not been made yet" }"#))
            default:
                return (404, Mock.json(#"{ "error": "nope" }"#))
            }
        }
        let client = Mock.client()
        let bytes = try await client.image(show: "T00316", asset: "NA0001", kind: "thumbnail")
        XCTAssertEqual(bytes, png, "bytes come back untouched, not decoded as JSON")
        do {
            _ = try await client.image(show: "T00316", asset: "NA0002", kind: "thumbnail")
            XCTFail()
        } catch let e as ArchiveError {
            XCTAssertEqual(e, .http(status: 404, message: "The thumbnail of T00316_NA0002_00 has not been made yet"))
        }
    }

    func testAllAssetsFollowsPages() async throws {
        MockURLProtocol.handler = { req, _ in
            if Mock.path(req) == "/auth/refresh" {
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            }
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let page = Int(q.first { $0.name == "page" }?.value ?? "1")!
            XCTAssertEqual(q.first { $0.name == "type" }?.value, "N")
            let assets = page == 1
                ? #"[ { "assetid": "a", "number": "0001" }, { "assetid": "b", "number": "0002" } ]"#
                : #"[ { "assetid": "c", "number": "0003" } ]"#
            return (200, Mock.json(#"{ "total": 3, "page": \#(page), "perpage": 2, "assets": \#(assets) }"#))
        }
        let all = try await Mock.client().allAssets(show: "T00316", type: "N")
        XCTAssertEqual(all.map(\.assetid), ["a", "b", "c"])
    }
}
