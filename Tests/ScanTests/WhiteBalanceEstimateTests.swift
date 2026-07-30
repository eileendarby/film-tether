import XCTest
@testable import Scan

final class WhiteBalanceEstimateTests: XCTestCase {

    /// Encoded value that linearises to `v`, so tests can specify the light and
    /// let the code do the transfer function.
    private func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    // MARK: - Direction

    /// A neutral sample means the body is already right, so nothing should move.
    func testNeutralSampleLeavesTheTemperatureAlone() {
        let k = WhiteBalanceEstimate.kelvin(
            fromRed: 0.5, green: 0.5, blue: 0.5, currentKelvin: 5000)
        XCTAssertEqual(k, 5000)
    }

    /// Too blue means the body is assuming light warmer than it is, so the
    /// setting has to go **up** to warm the picture back.
    func testBlueSampleRaisesTheTemperature() {
        let k = WhiteBalanceEstimate.kelvin(
            fromRed: encode(0.2), green: encode(0.4), blue: encode(0.6),
            currentKelvin: 5000)!
        XCTAssertGreaterThan(k, 5000)
    }

    func testRedSampleLowersTheTemperature() {
        let k = WhiteBalanceEstimate.kelvin(
            fromRed: encode(0.6), green: encode(0.4), blue: encode(0.2),
            currentKelvin: 5000)!
        XCTAssertLessThan(k, 5000)
    }

    // MARK: - Magnitude

    /// The estimate has to match the model that was fitted to the body, or the
    /// measurement in `wb-probe` bought us nothing.
    func testEstimateMatchesTheMeasuredResponse() {
        let r = 0.30, b = 0.10
        let k = WhiteBalanceEstimate.kelvin(
            fromRed: encode(r), green: encode(0.2), blue: encode(b),
            currentKelvin: 5000)!
        let expected = 1.0 / (1.0 / 5000 + log(r / b) / WhiteBalanceEstimate.responseConstant)
        XCTAssertEqual(Double(k), expected, accuracy: Double(WhiteBalanceEstimate.stepKelvin))
    }

    /// The correction is *relative*, so the same cast seen from a different
    /// starting point must land somewhere different.
    func testTheSameCastFromADifferentStartLandsElsewhere() {
        let cast = (r: encode(0.2), g: encode(0.4), b: encode(0.6))
        let fromCool = WhiteBalanceEstimate.kelvin(
            fromRed: cast.r, green: cast.g, blue: cast.b, currentKelvin: 3000)!
        let fromWarm = WhiteBalanceEstimate.kelvin(
            fromRed: cast.r, green: cast.g, blue: cast.b, currentKelvin: 6000)!
        XCTAssertGreaterThan(fromWarm, fromCool)
    }

    /// Sampling in encoded space and forgetting to linearise would understate
    /// the correction badly — this pins that the transfer function is applied.
    func testLinearisationChangesTheAnswer() {
        let r = 0.30, b = 0.10
        let linearised = WhiteBalanceEstimate.kelvin(
            fromRed: encode(r), green: encode(0.2), blue: encode(b),
            currentKelvin: 5000)!
        // What we'd get feeding the encoded values straight into the log.
        let raw = 1.0 / (1.0 / 5000
            + log(encode(r) / encode(b)) / WhiteBalanceEstimate.responseConstant)
        XCTAssertGreaterThan(abs(Double(linearised) - raw), 200,
                             "skipping the transfer function should visibly understate the move")
    }

    // MARK: - Range

    func testResultIsAlwaysSomethingTheBodyAccepts() {
        for (r, g, b) in [(0.99, 0.5, 0.01), (0.01, 0.5, 0.99), (0.5, 0.5, 0.5)] {
            let k = WhiteBalanceEstimate.kelvin(
                fromRed: r, green: g, blue: b, currentKelvin: 5000)!
            XCTAssertGreaterThanOrEqual(k, WhiteBalanceEstimate.minKelvin)
            XCTAssertLessThanOrEqual(k, WhiteBalanceEstimate.maxKelvin)
            XCTAssertEqual(k % WhiteBalanceEstimate.stepKelvin, 0,
                           "\(k) is not on the body's 100 K step")
        }
    }

    func testSnapRoundsAndClamps() {
        XCTAssertEqual(WhiteBalanceEstimate.snap(5149), 5100)
        XCTAssertEqual(WhiteBalanceEstimate.snap(5150), 5200)
        XCTAssertEqual(WhiteBalanceEstimate.snap(100), WhiteBalanceEstimate.minKelvin)
        XCTAssertEqual(WhiteBalanceEstimate.snap(99_000), WhiteBalanceEstimate.maxKelvin)
        XCTAssertEqual(WhiteBalanceEstimate.snap(.nan), WhiteBalanceEstimate.minKelvin)
    }

    // MARK: - Refusals

    func testTooDarkASampleIsRefused() {
        XCTAssertNil(WhiteBalanceEstimate.kelvin(
            fromRed: 0.005, green: 0.005, blue: 0.005, currentKelvin: 5000))
    }

    func testAnUnknownCurrentTemperatureIsRefused() {
        XCTAssertNil(WhiteBalanceEstimate.kelvin(
            fromRed: 0.5, green: 0.4, blue: 0.3, currentKelvin: 0))
    }

    func testNonFiniteChannelsAreRefused() {
        XCTAssertNil(WhiteBalanceEstimate.kelvin(
            fromRed: .nan, green: 0.5, blue: 0.5, currentKelvin: 5000))
    }

    // MARK: - Tint

    /// The camera takes the blue/amber axis, so the host correction must leave
    /// it alone — otherwise both correct it and the result overshoots.
    func testTintGainsDoNotTouchTheBlueAmberAxis() {
        let g = WhiteBalanceEstimate.tintGains(red: 0.6, green: 0.3, blue: 0.2)!
        XCTAssertEqual(g.red, g.blue, accuracy: 1e-9,
                       "red and blue must move together, leaving the axis to the camera")
        XCTAssertNotEqual(g.green, g.red, accuracy: 1e-9)
    }

    func testGreenCastIsPulledDown() {
        // Green above the red/blue mean → its gain must be < 1.
        let g = WhiteBalanceEstimate.tintGains(red: 0.4, green: 0.8, blue: 0.4)!
        XCTAssertLessThan(g.green, 1.0)
        XCTAssertGreaterThan(g.red, 1.0)
    }

    func testMagentaCastIsPulledUp() {
        let g = WhiteBalanceEstimate.tintGains(red: 0.6, green: 0.2, blue: 0.6)!
        XCTAssertGreaterThan(g.green, 1.0)
    }

    /// Brightness must survive the correction — clicking the film base is a
    /// colour decision, not an exposure one.
    func testTintGainsPreserveOverallBrightness() {
        let g = WhiteBalanceEstimate.tintGains(red: 0.4, green: 0.8, blue: 0.4)!
        XCTAssertEqual((g.red + g.green + g.blue) / 3, 1.0, accuracy: 1e-9)
    }

    /// A pure blue/amber cast has no tint component, so there's nothing for the
    /// host to do and it should say so rather than applying a no-op.
    func testNoTintCastYieldsNoGains() {
        XCTAssertNil(WhiteBalanceEstimate.tintGains(red: 0.4, green: 0.4, blue: 0.4))
    }

    func testTintGainsRefuseADarkSample() {
        XCTAssertNil(WhiteBalanceEstimate.tintGains(red: 0.01, green: 0.005, blue: 0.01))
    }
}
