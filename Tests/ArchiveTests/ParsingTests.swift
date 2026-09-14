import XCTest
@testable import Archive

final class ShowCodeTests: XCTestCase {
    func testCanonicalForm() {
        let c = ShowCode.parse("T00316")
        XCTAssertEqual(c, ShowCode(category: "T", number: 316))
        XCTAssertEqual(c?.id, "T00316")
    }

    func testLooseForms() {
        for text in ["t316", "T-316", "T 316", "t_0316", " T00316 "] {
            XCTAssertEqual(ShowCode.parse(text)?.id, "T00316", text)
        }
    }

    func testSuffix() {
        XCTAssertEqual(ShowCode.parse("T00316A")?.id, "T00316A")
        XCTAssertEqual(ShowCode.parse("t316 a")?.suffix, "A")
    }

    func testRejects() {
        for text in ["", "316", "T", "TT316", "T316AB", "T3161234", "T-", "T316A1"] {
            XCTAssertNil(ShowCode.parse(text), text)
        }
    }
}

final class NumberRangeTests: XCTestCase {
    func testNumberRuns() {
        XCTAssertEqual(NumberRange.parse("1-4"), NumberRange(first: 1, last: 4))
        XCTAssertEqual(NumberRange.parse("12"), NumberRange(first: 12, last: 12))
        XCTAssertEqual(NumberRange.parse(" 0001 - 0120 "), NumberRange(first: 1, last: 120))
        XCTAssertEqual(NumberRange.parse("12A-14A"), NumberRange(first: 12, last: 14, suffix: "A"))
        XCTAssertEqual(NumberRange.parse("12a"), NumberRange(first: 12, last: 12, suffix: "A"))
    }

    func testSuffixRuns() {
        let r = NumberRange.parse("12A-12C")
        XCTAssertEqual(r, NumberRange(number: 12, firstSuffix: "A", lastSuffix: "C"))
        XCTAssertEqual(r?.count, 3)
        XCTAssertEqual((0..<3).map { r!.label(at: $0) }, ["12A", "12B", "12C"])
        XCTAssertEqual(r?.description, "12A-12C")
        XCTAssertEqual(NumberRange.parse("7b-7b")?.count, 1)
    }

    func testRejects() {
        XCTAssertNil(NumberRange.parse("12A-14B"), "number and suffix can't both vary")
        XCTAssertNil(NumberRange.parse("12C-12A"), "backwards suffixes")
        XCTAssertNil(NumberRange.parse("4-1"), "backwards")
        XCTAssertNil(NumberRange.parse("1-2-3"))
        XCTAssertNil(NumberRange.parse(""))
        XCTAssertNil(NumberRange.parse("A-B"))
        XCTAssertNil(NumberRange.parse("12-12A"), "one end suffixed, the other not")
    }

    func testLabels() {
        let r = NumberRange(first: 12, last: 14, suffix: "A")!
        XCTAssertEqual(r.firstLabel, "12A")
        XCTAssertEqual(r.lastLabel, "14A")
        XCTAssertEqual(r.description, "12A-14A")
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.paddedLabel(at: 1), "0013A")
        XCTAssertEqual(NumberRange(first: 7, last: 7)!.description, "7")
    }

    func testIndexOfTypedLabel() {
        let numbers = NumberRange(first: 30, last: 40)!
        XCTAssertEqual(numbers.index(of: "34"), 4)
        XCTAssertEqual(numbers.index(of: "0034"), 4)
        XCTAssertEqual(numbers.index(of: " 40 "), 10)
        XCTAssertNil(numbers.index(of: "41"))
        XCTAssertNil(numbers.index(of: "34A"))
        XCTAssertNil(numbers.index(of: ""))

        let suffixes = NumberRange(number: 12, firstSuffix: "A", lastSuffix: "D")!
        XCTAssertEqual(suffixes.index(of: "12C"), 2)
        XCTAssertEqual(suffixes.index(of: "0012c"), 2)
        XCTAssertEqual(suffixes.index(of: "B"), 1, "a bare letter is enough in a suffix run")
        XCTAssertNil(suffixes.index(of: "12E"))
        XCTAssertNil(suffixes.index(of: "13B"))
    }

    func testNormalizeAndPad() {
        XCTAssertEqual(NumberRange.normalize("0012A"), "12A")
        XCTAssertEqual(NumberRange.normalize("0001"), "1")
        XCTAssertEqual(NumberRange.normalize("12a"), "12A")
        XCTAssertEqual(NumberRange.pad("12A"), "0012A")
        XCTAssertEqual(NumberRange.pad("7"), "0007")
    }

    func testCodableRoundTrip() throws {
        for r in [NumberRange(first: 1, last: 4)!, NumberRange(number: 12, firstSuffix: "A", lastSuffix: "C")!] {
            let data = try JSONEncoder().encode(r)
            XCTAssertEqual(try JSONDecoder().decode(NumberRange.self, from: data), r)
        }
    }
}

final class ScanRunTests: XCTestCase {
    private func makeRun() -> ScanRun {
        ScanRun(show: "T00316", type: "N", roll: "a", format: 2,
                range: NumberRange(first: 1, last: 3)!,
                assetIDs: ["0001": "T00316_NA0001_00", "2": "T00316_NA0002_00", "0003": "T00316_NA0003_00"])
    }

    func testAdvanceAndSkip() {
        var r = makeRun()
        XCTAssertEqual(r.roll, "A", "roll is upper-cased")
        XCTAssertEqual(r.currentLabel, "1")
        XCTAssertEqual(r.currentPadded, "0001")
        XCTAssertEqual(r.currentAssetID, "T00316_NA0001_00", "ids are keyed by normalized label, however they arrived")
        r.markScanned()
        XCTAssertEqual(r.currentLabel, "2")
        XCTAssertEqual(r.currentAssetID, "T00316_NA0002_00")
        r.skip()
        XCTAssertEqual(r.currentLabel, "3")
        XCTAssertEqual(r.skipped, ["2"])
        XCTAssertEqual(r.scanned, ["1"])
        XCTAssertFalse(r.isFinished)
        r.markScanned()
        XCTAssertTrue(r.isFinished)
        XCTAssertNil(r.currentAssetID)
        XCTAssertNil(r.currentPadded)
        XCTAssertEqual(r.remaining, 0)
        // Nothing happens past the end.
        r.markScanned(); r.skip()
        XCTAssertEqual(r.scanned, ["1", "3"])
        XCTAssertEqual(r.skipped, ["2"])
    }

    func testSuffixRunSteps() {
        var r = ScanRun(show: "T00316", type: "N", roll: nil, format: 4,
                        range: NumberRange(number: 12, firstSuffix: "A", lastSuffix: "C")!,
                        assetIDs: ["12A": "x_A", "12B": "x_B", "12C": "x_C"])
        XCTAssertEqual(r.currentPadded, "0012A")
        r.markScanned()
        XCTAssertEqual(r.currentAssetID, "x_B")
        XCTAssertTrue(r.jump(toLabel: "c"))
        XCTAssertEqual(r.currentAssetID, "x_C")
        r.markScanned()
        XCTAssertTrue(r.isFinished)
        XCTAssertEqual(r.summary, "T00316 · N · 12A-12C")
    }

    func testJumpAndBack() {
        var r = makeRun()
        XCTAssertTrue(r.jump(toLabel: "3"))
        XCTAssertEqual(r.currentLabel, "3")
        XCTAssertFalse(r.jump(toLabel: "9"), "not in the run")
        XCTAssertEqual(r.currentLabel, "3")
        r.jump(to: 99)
        XCTAssertEqual(r.position, 2, "out of range is ignored")
        r.back()
        XCTAssertEqual(r.currentLabel, "2")
        r.jump(to: 0); r.back()
        XCTAssertEqual(r.currentLabel, "1", "can't go before the first")
    }

    func testCodableRoundTrip() throws {
        var r = makeRun()
        r.markScanned()
        r.secondaryAssetIDs["1"] = "T00316_NA0001_01"
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ScanRun.self, from: data)
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.assetID(for: "0002"), "T00316_NA0002_00")
        XCTAssertEqual(back.secondaryAssetIDs["1"], "T00316_NA0001_01")
    }

    func testSummary() {
        XCTAssertEqual(makeRun().summary, "T00316 · N · roll A · 1-3")
    }
}
