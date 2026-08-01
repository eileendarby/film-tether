import XCTest
import CoreGraphics
@testable import Scan

final class FilmSizeTests: XCTestCase {

    private let catalog = FilmSize.seedCatalog

    // MARK: - Catalogue integrity

    /// The IDs are the website database's, so a renumbering would silently
    /// mislabel every scan already recorded.
    func testCatalogMatchesTheDatabaseIdsAndNames() {
        let expected: [(Int, String)] = [
            (1, "unknown"), (2, "120mm Rollei"), (3, "4x5"), (4, "35mm"),
            (5, "35mm slide"), (6, "8x10"), (7, "11x14"), (8, "6x9"),
            (9, "5x7"), (10, "3.25x4.25 (80mm x 105mm)"), (11, "2.25x3.25"),
        ]
        XCTAssertEqual(catalog.count, expected.count)
        for (size, want) in zip(catalog, expected) {
            XCTAssertEqual(size.id, want.0)
            XCTAssertEqual(size.name, want.1)
        }
    }

    func testOnlyUnknownLacksDimensions() {
        for size in catalog {
            XCTAssertEqual(size.isUnknown, size.id == 1, "\(size.name)")
        }
    }

    func testAspectRatioIsOrientationIndependent() {
        let portrait = FilmSize(id: 99, name: "t", widthMM: 24, heightMM: 36)
        let landscape = FilmSize(id: 99, name: "t", widthMM: 36, heightMM: 24)
        XCTAssertEqual(portrait.aspectRatio!, landscape.aspectRatio!, accuracy: 1e-9)
        XCTAssertEqual(portrait.aspectRatio!, 1.5, accuracy: 1e-9)
    }

    // MARK: - The ambiguity this catalogue contains

    /// Documents the central constraint: these pairs are indistinguishable by
    /// shape alone, so any UI that shows a single auto-detected answer without a
    /// scale is guessing between them.
    func testFormatsThatShareAnAspectRatio() throws {
        func ratio(_ id: Int) throws -> Double {
            try XCTUnwrap(catalog.first { $0.id == id }?.aspectRatio)
        }
        XCTAssertEqual(try ratio(3), try ratio(6), accuracy: 1e-9, "4x5 vs 8x10")
        XCTAssertEqual(try ratio(4), try ratio(8), accuracy: 1e-9, "35mm vs 6x9")
    }

    /// Stronger than shared aspect ratio: these pairs are the same physical
    /// frame, so no amount of measurement will ever separate them and the UI
    /// must let the operator pick.
    func testSomeFormatsAreGeometricallyIdentical() throws {
        for group in FilmSize.indistinguishableGroups {
            let sizes = group.compactMap { id in catalog.first { $0.id == id } }
            XCTAssertEqual(sizes.count, group.count)
            let diagonals = sizes.compactMap(\.diagonalMM)
            let spread = (diagonals.max()! - diagonals.min()!) / diagonals.min()!
            XCTAssertLessThan(spread, 0.01,
                              "\(sizes.map(\.name)) should be within 1% in size")
            let ratios = sizes.compactMap(\.aspectRatio)
            let ratioSpread = (ratios.max()! - ratios.min()!) / ratios.min()!
            XCTAssertLessThan(ratioSpread, 0.01,
                              "\(sizes.map(\.name)) should be within 1% in shape")
        }
    }

    /// 6x9 and 2.25x3.25 are the same format named two ways, and land within a
    /// half percent on size — but their nominal shapes differ by ~4%, so they
    /// are confusable rather than identical. Both should show up as candidates
    /// for a crop between the two ratios.
    func testSixByNineAndTwoAndAQuarterAreBothOfferedForAnInBetweenCrop() throws {
        let sixNine = try XCTUnwrap(catalog.first { $0.id == 8 })
        let twoQuarter = try XCTUnwrap(catalog.first { $0.id == 11 })
        let sizeSpread = abs(sixNine.diagonalMM! - twoQuarter.diagonalMM!) / sixNine.diagonalMM!
        XCTAssertLessThan(sizeSpread, 0.01, "same overall size")
        XCTAssertGreaterThan(
            abs(sixNine.aspectRatio! - twoQuarter.aspectRatio!) / sixNine.aspectRatio!,
            0.02, "but distinguishable shapes"
        )
        let between = (sixNine.aspectRatio! + twoQuarter.aspectRatio!) / 2
        let crop = CGSize(width: 1000, height: 1000 * between)
        let ids = Set(FilmSizeMatcher.candidates(forCropSize: crop, in: catalog).map(\.size.id))
        XCTAssertTrue(ids.isSuperset(of: [8, 11]))
    }

    func testWithoutScaleAmbiguousFormatsBothSurvive() {
        // A 3:2 crop: 35mm and 6x9 are both perfectly consistent with it.
        let matches = FilmSizeMatcher.candidates(
            forCropSize: CGSize(width: 1000, height: 1500), in: catalog
        )
        let ids = Set(matches.map(\.size.id))
        XCTAssertTrue(ids.contains(4), "35mm should be a candidate")
        XCTAssertTrue(ids.contains(8), "6x9 should be a candidate")
    }

    // MARK: - Scale-aware matching

    /// With a scale, absolute size separates the formats that shape can't.
    func testScaleSeparates35mmFrom6x9() throws {
        // Crop 1000x1500 px. At 0.036 mm/px that's 36x54mm — 35mm-ish, not 6x9.
        let small = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 1000, height: 1500),
            in: catalog, mmPerPixel: 24.0 / 1000.0
        )
        XCTAssertEqual(small.id, 4, "expected 35mm, got \(small.name)")

        // Same shape, but each pixel is worth more, so the negative is 56x84mm.
        let large = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 1000, height: 1500),
            in: catalog, mmPerPixel: 56.0 / 1000.0
        )
        XCTAssertEqual(large.id, 8, "expected 6x9, got \(large.name)")
    }

    func testScaleSeparates4x5From8x10() throws {
        let fourByFive = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 960, height: 1200),
            in: catalog, mmPerPixel: 0.1
        )
        XCTAssertEqual(fourByFive.id, 3, "expected 4x5, got \(fourByFive.name)")

        let eightByTen = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 960, height: 1200),
            in: catalog, mmPerPixel: 194.0 / 960.0
        )
        XCTAssertEqual(eightByTen.id, 6, "expected 8x10, got \(eightByTen.name)")
    }

    func testSquareCropMatchesRollei() {
        let match = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 1200, height: 1200), in: catalog
        )
        XCTAssertEqual(match.id, 2)
    }

    func testAWildlyOffShapeFallsBackToUnknown() {
        // 5:1 panorama matches nothing in the catalogue.
        let match = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 500, height: 2500), in: catalog
        )
        XCTAssertTrue(match.isUnknown)
    }

    func testDegenerateCropYieldsNoCandidates() {
        XCTAssertTrue(FilmSizeMatcher.candidates(forCropSize: .zero, in: catalog).isEmpty)
        XCTAssertTrue(
            FilmSizeMatcher.candidates(
                forCropSize: CGSize(width: 100, height: 0), in: catalog
            ).isEmpty
        )
    }

    func testUnknownIsNeverOfferedAsACandidate() {
        let matches = FilmSizeMatcher.candidates(
            forCropSize: CGSize(width: 1000, height: 1500), in: catalog
        )
        XCTAssertFalse(matches.contains { $0.size.isUnknown })
    }

    // MARK: - Calibration

    func testCalibrationRecoversTheScaleUsedToBuildTheCrop() throws {
        let thirtyFive = try XCTUnwrap(catalog.first { $0.id == 4 })
        // A 35mm frame photographed at 1000 px across its 24mm edge.
        let crop = CGSize(width: 1000, height: 1500)
        let scale = try XCTUnwrap(
            FilmSizeMatcher.mmPerPixel(cropSize: crop, isSize: thirtyFive)
        )
        XCTAssertEqual(scale, 24.0 / 1000.0, accuracy: 1e-6)
    }

    /// Calibrate on one negative, then identify a different format shot on the
    /// same rig — the workflow the feature depends on.
    func testCalibratingOn35mmThenIdentifying6x9() throws {
        let thirtyFive = try XCTUnwrap(catalog.first { $0.id == 4 })
        let scale = try XCTUnwrap(FilmSizeMatcher.mmPerPixel(
            cropSize: CGSize(width: 1000, height: 1500), isSize: thirtyFive
        ))
        // Same rig, a 6x9 negative now fills proportionally more of the frame.
        let sixByNine = CGSize(width: 56.0 / scale, height: 84.0 / scale)
        let match = FilmSizeMatcher.bestMatch(
            forCropSize: sixByNine, in: catalog, mmPerPixel: scale
        )
        XCTAssertEqual(match.id, 8, "expected 6x9, got \(match.name)")
    }

    func testCalibrationRefusesUnknown() {
        XCTAssertNil(FilmSizeMatcher.mmPerPixel(
            cropSize: CGSize(width: 100, height: 100), isSize: FilmSize.unknown
        ))
    }

    func testCatalogRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(catalog)
        XCTAssertEqual(try JSONDecoder().decode([FilmSize].self, from: data), catalog)
    }
}
