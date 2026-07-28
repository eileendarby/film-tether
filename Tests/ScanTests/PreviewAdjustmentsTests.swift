import XCTest
@testable import Scan

final class ChannelGainsTests: XCTestCase {

    func testNeutralSampleProducesIdentityGains() throws {
        let g = try XCTUnwrap(ChannelGains.neutralizing(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(g.red, 1, accuracy: 1e-9)
        XCTAssertEqual(g.green, 1, accuracy: 1e-9)
        XCTAssertEqual(g.blue, 1, accuracy: 1e-9)
        XCTAssertTrue(g.isIdentity)
    }

    /// The whole point of the feature: applying the gains to the colour they
    /// were derived from must land on neutral grey.
    func testGainsActuallyNeutraliseTheSampledColour() throws {
        // Something like an orange colour-negative base.
        let (r, gr, b) = (0.90, 0.50, 0.20)
        let g = try XCTUnwrap(ChannelGains.neutralizing(red: r, green: gr, blue: b))
        let corrected = (r * g.red, gr * g.green, b * g.blue)
        XCTAssertEqual(corrected.0, corrected.1, accuracy: 1e-9)
        XCTAssertEqual(corrected.1, corrected.2, accuracy: 1e-9)
    }

    /// Correcting shouldn't double as an exposure change — the neutral result
    /// should sit at the sample's own mean level.
    func testCorrectionPreservesTheSampledBrightness() throws {
        let (r, gr, b) = (0.90, 0.50, 0.20)
        let mean = (r + gr + b) / 3
        let g = try XCTUnwrap(ChannelGains.neutralizing(red: r, green: gr, blue: b))
        XCTAssertEqual(r * g.red, mean, accuracy: 1e-9)
    }

    func testAnExcessivelyDarkSampleIsRefused() {
        XCTAssertNil(ChannelGains.neutralizing(red: 0.001, green: 0.001, blue: 0.001))
        XCTAssertNil(ChannelGains.neutralizing(red: 0, green: 0, blue: 0))
    }

    /// A sample that's dark overall but has one usable channel is still worth
    /// correcting; only an all-dark sample is hopeless.
    func testASampleWithOneBrightChannelIsAccepted() {
        XCTAssertNotNil(ChannelGains.neutralizing(red: 0.4, green: 0.001, blue: 0.001))
    }

    func testGainsAreClampedToTheAllowedRange() throws {
        // green is vanishingly small next to red, which would divide out to a
        // gain in the hundreds without clamping.
        let g = try XCTUnwrap(ChannelGains.neutralizing(red: 0.9, green: 0.0001, blue: 0.9))
        XCTAssertLessThanOrEqual(g.green, ChannelGains.maxGain)
        XCTAssertGreaterThanOrEqual(g.red, ChannelGains.minGain)
        for v in [g.red, g.green, g.blue] {
            XCTAssertTrue(v.isFinite)
            XCTAssertGreaterThanOrEqual(v, ChannelGains.minGain)
            XCTAssertLessThanOrEqual(v, ChannelGains.maxGain)
        }
    }

    func testNonFiniteInputIsRefused() {
        XCTAssertNil(ChannelGains.neutralizing(red: .nan, green: 0.5, blue: 0.5))
        XCTAssertNil(ChannelGains.neutralizing(red: .infinity, green: 0.5, blue: 0.5))
    }

    func testGainsRoundTripThroughCodable() throws {
        let g = ChannelGains(red: 0.6, green: 1.0, blue: 2.4)
        let decoded = try JSONDecoder().decode(ChannelGains.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(decoded, g)
    }
}

final class PreviewAdjustmentsTests: XCTestCase {

    /// The 30 fps fast path: with nothing to do, the render step must be
    /// skippable so an unadjusted preview costs no decode/encode.
    func testDefaultsAreIdentity() {
        XCTAssertTrue(PreviewAdjustments.none.isIdentity)
        XCTAssertTrue(PreviewAdjustments(monochrome: false, whiteBalance: nil).isIdentity)
        XCTAssertTrue(PreviewAdjustments(monochrome: false, whiteBalance: .identity).isIdentity)
    }

    func testAnyActiveAdjustmentDefeatsTheFastPath() {
        XCTAssertFalse(PreviewAdjustments(monochrome: true).isIdentity)
        XCTAssertFalse(PreviewAdjustments(invert: true).isIdentity)
        XCTAssertFalse(
            PreviewAdjustments(whiteBalance: ChannelGains(red: 1.2, green: 1, blue: 0.8)).isIdentity
        )
    }

    func testAdjustmentsRoundTripThroughCodable() throws {
        let a = PreviewAdjustments(
            monochrome: true,
            invert: true,
            whiteBalance: ChannelGains(red: 0.6, green: 1.0, blue: 2.4)
        )
        let decoded = try JSONDecoder().decode(
            PreviewAdjustments.self, from: JSONEncoder().encode(a)
        )
        XCTAssertEqual(decoded, a)
    }
}
