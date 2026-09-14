import XCTest
@testable import Archive

/// The samples in the API document, decoded as the client decodes them.
final class ModelDecodingTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func testShow() throws {
        let json = """
        {
          "id": "T00316", "category": "T", "number": "00316", "name": "The Iceman Cometh",
          "photographer": 1,
          "date": { "year": 1946, "month": 10, "day": 9 },
          "notes": { "public": "Martin Beck Theatre", "private": null, "qc": null },
          "flags": { "have_negatives": false, "is_publicshow": true },
          "ibdb": { "shows": "", "productions": "", "venues": "" }
        }
        """
        let show = try decoder.decode(ArchiveShow.self, from: Data(json.utf8))
        XCTAssertEqual(show.id, "T00316")
        XCTAssertEqual(show.number, "00316", "kept as text: that form is the identifier")
        XCTAssertEqual(show.date?.year, 1946)
        XCTAssertEqual(show.notes?.public, "Martin Beck Theatre")
        XCTAssertNil(show.notes?.private)
        XCTAssertEqual(show.displayName, "The Iceman Cometh (1946)")
    }

    func testShowPageAndUnnamedShow() throws {
        let json = #"{ "total": 1, "page": 1, "perpage": 2, "shows": [ { "id": "T00316", "name": null, "date": null } ] }"#
        let page = try decoder.decode(ShowPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.shows.first?.displayName, "T00316")
    }

    func testInventory() throws {
        let json = """
        {
          "show": "T00316", "total": 5,
          "types": [
            { "type": "N", "name": "Negative", "total": 5, "ranges": [
                { "format": "120mm Rollei", "roll": "A", "range": "1-4" },
                { "format": "120mm Rollei", "roll": "B", "range": "12" } ] },
            { "type": "G", "name": "Glass Negative", "total": 0, "ranges": [] },
            { "type": "P", "name": "Print", "total": 0, "ranges": [] }
          ]
        }
        """
        let inv = try decoder.decode(ArchiveInventory.self, from: Data(json.utf8))
        XCTAssertEqual(inv.types.count, 3)
        XCTAssertEqual(inv.types[0].ranges[1], InventoryRange(format: "120mm Rollei", roll: "B", range: "12"))
        XCTAssertEqual(inv.types[1].displayName, "Glass Negative")
        XCTAssertEqual(NumberRange.parse(inv.types[0].ranges[0].range), NumberRange(first: 1, last: 4))
    }

    func testAsset() throws {
        let json = """
        {
          "assetid": "T00316_NA0001_00", "show": "T00316", "type": "N", "roll": "A",
          "number": "0001", "version": "00", "canonical": true, "kind": null, "caption": null,
          "format": 2, "scanner": null, "copies": 1, "rotate": null,
          "image": { "width": null, "height": null, "bitdepth": null, "colordepth": null, "filesize": null, "extension": null },
          "flags": { "is_missing": false, "is_publicasset": false, "rescan": false }
        }
        """
        let a = try decoder.decode(ArchiveAsset.self, from: Data(json.utf8))
        XCTAssertEqual(a.assetid, "T00316_NA0001_00")
        XCTAssertEqual(a.number, "0001")
        XCTAssertEqual(a.numberValue, 1)
        XCTAssertEqual(a.version, "00", "the string, not the number 0")
        XCTAssertEqual(a.format, 2)
        XCTAssertEqual(a.canonical, true)
    }

    func testAssetSuffixNumber() throws {
        let a = try decoder.decode(ArchiveAsset.self, from: Data(#"{ "assetid": "x", "number": "0012A" }"#.utf8))
        XCTAssertEqual(a.numberValue, 12)
    }

    func testUploadRegistered() throws {
        let json = """
        {
          "id": 1, "assetid": "T00316_NA0001_00", "filename": "scan_0001.tif", "state": "sending",
          "bytes": 3000, "chunk_size": 1024, "chunks": 3, "received": 0, "percent": 0,
          "outstanding": [0, 1, 2], "outstanding_total": 3,
          "created": 1789368134, "updated": 1789368134, "completed": null, "abandoned": null,
          "error": null, "rendered": null, "render_error": null
        }
        """
        let u = try decoder.decode(ArchiveUpload.self, from: Data(json.utf8))
        XCTAssertEqual(u.id, 1)
        XCTAssertEqual(u.chunkSize, 1024)
        XCTAssertEqual(u.outstanding, [0, 1, 2])
        XCTAssertEqual(u.remaining, 3)
        XCTAssertFalse(u.isComplete)
        XCTAssertFalse(u.isRendered)
    }

    func testUploadCompleteAndRendered() throws {
        let json = """
        { "id": 1, "state": "complete", "received": 3, "percent": 100, "outstanding": [],
          "outstanding_total": 0, "completed": 1789368134, "stored": "/x/y.tif", "rendered": 1789368200, "render_error": null }
        """
        let u = try decoder.decode(ArchiveUpload.self, from: Data(json.utf8))
        XCTAssertTrue(u.isComplete)
        XCTAssertEqual(u.remaining, 0)
        XCTAssertTrue(u.isRendered)
        XCTAssertEqual(u.rendered?.raw, "1789368200")
    }

    func testOutstandingCapIsNotTheCount() throws {
        let json = #"{ "id": 9, "state": "sending", "outstanding": [0, 1], "outstanding_total": 60 }"#
        let u = try decoder.decode(ArchiveUpload.self, from: Data(json.utf8))
        XCTAssertEqual(u.remaining, 60)
    }

    func testLoginAndRefresh() throws {
        let login = try decoder.decode(LoginResponse.self, from: Data("""
        { "access_token": "v1.1.x", "expires_in": 900, "refresh_token": "r", "session": 1, "device": "scanning station 2" }
        """.utf8))
        XCTAssertEqual(login.refreshToken, "r")
        let refresh = try decoder.decode(RefreshResponse.self, from: Data(#"{ "access_token": "v1.1.y", "expires_in": 900, "session": 1 }"#.utf8))
        XCTAssertEqual(refresh.accessToken, "v1.1.y")
        let code = try decoder.decode(CodeResponse.self, from: Data(#"{ "expires_in": 600, "sent": true }"#.utf8))
        XCTAssertTrue(code.sent)
    }

    func testAlreadyRegisteredParsing() {
        let e = ArchiveError.http(status: 409, message: "Already registered: T00316_NA0002_00, T00316_NA0003_00")
        XCTAssertEqual(e.alreadyRegisteredAssetIDs, ["T00316_NA0002_00", "T00316_NA0003_00"])
        XCTAssertNil(ArchiveError.http(status: 409, message: "Show T00316 already exists").alreadyRegisteredAssetIDs)
    }
}
