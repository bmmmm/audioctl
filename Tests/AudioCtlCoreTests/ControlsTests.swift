// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import XCTest
@testable import AudioCtlCore

final class VolumeParsingTests: XCTestCase {
    func testAcceptsWholeRange() throws {
        XCTAssertEqual(try parsePercent("0"), 0)
        XCTAssertEqual(try parsePercent("40"), 40)
        XCTAssertEqual(try parsePercent("100"), 100)
        XCTAssertEqual(try parsePercent("12.5"), 12.5)
    }

    /// The bug this guards: `min(1, .nan)` returns 1 in Swift, so "nan" used to
    /// clamp to full volume and exit 0 — a failed shell expression blasting the
    /// speakers at 100 %.
    func testRejectsNonFiniteInput() {
        XCTAssertThrowsError(try parsePercent("nan"))
        XCTAssertThrowsError(try parsePercent("inf"))
        XCTAssertThrowsError(try parsePercent("-inf"))
    }

    func testRejectsOutOfRangeAndGarbage() {
        XCTAssertThrowsError(try parsePercent("101"))
        XCTAssertThrowsError(try parsePercent("-1"))
        XCTAssertThrowsError(try parsePercent(""))
        XCTAssertThrowsError(try parsePercent("loud"))
    }

    func testClampVolumeMapsNonFiniteToSilenceNotFullScale() {
        XCTAssertEqual(clampVolume(.nan), 0)
        XCTAssertEqual(clampVolume(.infinity), 0)
        XCTAssertEqual(clampVolume(1.5), 1)
        XCTAssertEqual(clampVolume(-0.5), 0)
        XCTAssertEqual(clampVolume(0.4), 0.4)
    }
}

final class SampleRateTests: XCTestCase {
    func testDegenerateRangesBecomeDiscreteRates() {
        let ranges = [44100.0, 48000.0, 96000.0].map { AudioValueRange(mMinimum: $0, mMaximum: $0) }
        XCTAssertEqual(expandSampleRateRanges(ranges), [44100, 48000, 96000])
    }

    func testContinuousRangeContributesBothEndpoints() {
        let ranges = [AudioValueRange(mMinimum: 8000, mMaximum: 96000)]
        XCTAssertEqual(expandSampleRateRanges(ranges), [8000, 96000])
    }

    func testResultIsSortedAndDeduplicated() {
        let ranges = [
            AudioValueRange(mMinimum: 48000, mMaximum: 48000),
            AudioValueRange(mMinimum: 44100, mMaximum: 44100),
            AudioValueRange(mMinimum: 48000, mMaximum: 48000),
        ]
        XCTAssertEqual(expandSampleRateRanges(ranges), [44100, 48000])
    }

    func testEmptyInput() {
        XCTAssertEqual(expandSampleRateRanges([]), [])
    }
}

final class FormatTests: XCTestCase {
    func testUnavailableValuesRenderAsDash() {
        XCTAssertEqual(fmtRate(nil), "—")
        XCTAssertEqual(fmtVol(nil), "—")
        XCTAssertEqual(fmtMute(nil), "—")
    }

    func testValueFormatting() {
        XCTAssertEqual(fmtRate(48000), "48000 Hz")
        XCTAssertEqual(fmtVol(0.695), "70%")
        XCTAssertEqual(fmtMute(true), "on")
        XCTAssertEqual(fmtMute(false), "off")
    }

    /// Device names are the argument `set` takes back, so padding must never truncate.
    func testPaddingNeverTruncates() {
        let long = "A Very Long Audio Device Name That Exceeds The Column"
        XCTAssertTrue("short".padded(30).hasPrefix("short"))
        XCTAssertEqual("short".padded(30).count, 30)
        XCTAssertTrue(long.padded(30).hasPrefix(long))
    }
}
