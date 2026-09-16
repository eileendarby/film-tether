import XCTest
@testable import Archive

final class CaptureAttributesTests: XCTestCase {
    private func sample() -> CaptureAttributes {
        CaptureAttributes(
            rotate: 90, flop: true,
            crop: .init(x: 1364, y: 0, width: 5464, height: 5464, straighten: -0.35,
                        normalized: .init(x: 0.1665, y: 0, width: 0.667, height: 1),
                        format: 2, source: "auto", reference: .init(width: 8192, height: 5464)),
            whiteBalance: .init(kelvin: 5200, gains: .init(red: 1, green: 0.912, blue: 1.087),
                                sampled: .init(x: 210, y: 4980)),
            film: .init(negative: true, monochrome: false),
            camera: .init(body: "Canon EOS R5", lens: nil, iso: "100", shutter: "1/125", aperture: "8",
                          imageFormat: "RAW + L"),
            software: .init(name: "Film Tether", version: "0.3.0", build: "c6e3ca6")
        )
    }

    /// The wire shape is the one in the API document, snake_case included.
    func testEncodesAsTheDocumentedShape() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(sample())
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["rotate"] as? Int, 90)
        XCTAssertEqual(o["flop"] as? Bool, true)
        let crop = try XCTUnwrap(o["crop"] as? [String: Any])
        XCTAssertEqual(crop["space"] as? String, "file")
        XCTAssertEqual(crop["straighten"] as? Double, -0.35)
        XCTAssertEqual((crop["normalized"] as? [String: Any])?["width"] as? Double, 0.667)
        XCTAssertEqual(crop["format"] as? Int, 2)
        XCTAssertEqual((crop["reference"] as? [String: Any])?["width"] as? Int, 8192, "the raster the box was measured against")
        let wb = try XCTUnwrap(o["white_balance"] as? [String: Any], "snake_case on the wire")
        XCTAssertEqual((wb["gains"] as? [String: Any])?["green"] as? Double, 0.912)
        XCTAssertEqual((wb["sampled"] as? [String: Any])?["y"] as? Int, 4980)
        XCTAssertEqual((o["film"] as? [String: Any])?["monochrome"] as? Bool, false)
        XCTAssertEqual((o["film"] as? [String: Any])?["negative"] as? Bool, true)
        let camera = try XCTUnwrap(o["camera"] as? [String: Any])
        XCTAssertEqual(camera["image_format"] as? String, "RAW + L")
        XCTAssertNil(camera["lens"] ?? nil, "a nil is omitted, not sent as null")
        XCTAssertEqual((o["software"] as? [String: Any])?["build"] as? String, "c6e3ca6")
    }

    func testRoundTrip() throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let back = try decoder.decode(CaptureAttributes.self, from: try encoder.encode(sample()))
        XCTAssertEqual(back, sample())
    }

    func testValidationPutsRightWhatTheArchiveWouldRefuse() {
        var a = sample()
        a.rotate = 45
        a.crop?.straighten = 60
        a.crop?.normalized = .init(x: 0.9, y: -0.01, width: 0.2, height: 1.02)
        let v = a.validated()
        XCTAssertEqual(v.rotate, 0, "not a quarter turn: dropped to 0 rather than refused")
        XCTAssertEqual(v.crop?.straighten, 45)
        let n = v.crop!.normalized
        XCTAssertEqual(n.height, 1)
        XCTAssertEqual(n.y, 0)
        XCTAssertEqual(n.width, 0.2)
        XCTAssertEqual(n.x, 0.8, accuracy: 1e-9, "pulled back inside, same size")
    }

    func testStraighteningInset() {
        XCTAssertEqual(CaptureAttributes.straighteningInset(halfWidth: 2732, degrees: 0), 0)
        XCTAssertEqual(CaptureAttributes.straighteningInset(halfWidth: 2732, degrees: -0.35), 17, "ceil(2732 × sin 0.35°)")
        XCTAssertEqual(CaptureAttributes.straighteningInset(halfWidth: 2732, degrees: 0.35), 17, "sign doesn't matter")
        XCTAssertEqual(CaptureAttributes.straighteningInset(halfWidth: 100, degrees: 30), 50)
    }

    /// The interface's label is what's sent, unless the files say otherwise.
    func testImageFormatAgreesWithTheFiles() {
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "RAW", fileExtensions: ["CR3"]), "RAW")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "RAW + L", fileExtensions: ["CR3", "JPG"]), "RAW + L")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "cRAW + M", fileExtensions: ["CR3", "JPG"]), "cRAW + M")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "RAW + L", fileExtensions: ["CR3"]), "RAW",
                       "the label promised a JPEG that never came: the files win")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "RAW", fileExtensions: ["CR3", "JPG"]), "RAW + JPEG")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "Large Fine JPEG", fileExtensions: ["JPG"]), "Large Fine JPEG")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "RAW", fileExtensions: ["JPG"]), "JPEG")
        XCTAssertEqual(CaptureAttributes.imageFormat(interface: "—", fileExtensions: []), "—")
    }

    func testValidationLeavesAGoodOneAlone() {
        XCTAssertEqual(sample().validated(), sample())
    }

    func testAnEmptyBoxIsNoCrop() {
        var a = sample()
        a.crop?.normalized = .init(x: 0.5, y: 0.5, width: 0, height: 0.3)
        XCTAssertNil(a.validated().crop)
    }

    /// Attributes ride along in the transfer registration, under `attributes`.
    func testSentWithTheUpload() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.handler = { req, body in
            switch Mock.path(req) {
            case "/auth/refresh":
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            case "/uploads":
                let o = Mock.jsonObject(body)
                XCTAssertEqual(o["assetid"] as? String, "T00316_NA0001_00")
                let attrs = o["attributes"] as? [String: Any]
                XCTAssertEqual(attrs?["rotate"] as? Int, 90)
                XCTAssertEqual((attrs?["crop"] as? [String: Any])?["source"] as? String, "auto")
                return (201, Mock.json(#"{ "id": 5, "state": "sending", "outstanding": [0], "outstanding_total": 1, "chunks": 1 }"#))
            default:
                return (404, Mock.json(#"{ "error": "nope" }"#))
            }
        }
        let file = ChunkedFile(url: URL(fileURLWithPath: "/x.cr3"), bytes: 10, chunkSize: 1024,
                               sha256: String(repeating: "a", count: 64), chunks: [String(repeating: "b", count: 64)])
        let u = try await Mock.client().createUpload(assetID: "T00316_NA0001_00", filename: "x.cr3", file: file,
                                                     attributes: sample())
        XCTAssertEqual(u.id, 5)
    }

    func testNoAttributesMeansNoKey() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.handler = { req, body in
            if Mock.path(req) == "/auth/refresh" {
                return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
            }
            XCTAssertNil(Mock.jsonObject(body)["attributes"] ?? nil, "absent, so the archive doesn't see an empty object and refuse it")
            return (201, Mock.json(#"{ "id": 6, "state": "sending", "outstanding": [0], "outstanding_total": 1, "chunks": 1 }"#))
        }
        let file = ChunkedFile(url: URL(fileURLWithPath: "/x.cr3"), bytes: 10, chunkSize: 1024,
                               sha256: String(repeating: "a", count: 64), chunks: [String(repeating: "b", count: 64)])
        _ = try await Mock.client().createUpload(assetID: "T00316_NA0001_00", filename: "x.cr3", file: file)
    }
}
