// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import AudioCtlCore

final class CLITests: XCTestCase {
    func testDefaultsToStatus() throws {
        let p = try parseArguments([])
        XCTAssertEqual(p.command, "status")
        XCTAssertTrue(p.args.isEmpty)
        XCTAssertFalse(p.json)
    }

    func testFlagsAreCollectedInAnyPosition() throws {
        let p = try parseArguments(["volume", "--json", "set", "-i", "40"])
        XCTAssertEqual(p.command, "volume")
        XCTAssertEqual(p.args, ["set", "40"])
        XCTAssertTrue(p.json)
        XCTAssertTrue(p.input)
    }

    func testDeviceFlagTakesTheNextArgument() throws {
        let p = try parseArguments(["mute", "toggle", "--device", "BlackHole 2ch"])
        XCTAssertEqual(p.device, "BlackHole 2ch")
        XCTAssertEqual(p.args, ["toggle"])
    }

    func testDeviceFlagWithoutValueIsUsageError() {
        assertUsage(try parseArguments(["mute", "--device"]))
    }

    /// The regression this suite exists for: a typo used to be swallowed as a
    /// positional argument and the command ran as if nothing was passed.
    func testUnknownFlagIsRejected() {
        assertUsage(try parseArguments(["list", "--verbose"]))
        assertUsage(try parseArguments(["list", "--jsno"]))
    }

    func testDoubleDashPassesLaterArgumentsThrough() throws {
        let p = try parseArguments(["info", "--", "--weird-device-name"])
        XCTAssertEqual(p.command, "info")
        XCTAssertEqual(p.args, ["--weird-device-name"])
    }

    func testHelpAndVersionShortCircuit() throws {
        XCTAssertEqual(try parseArguments(["--help"]).command, "help")
        XCTAssertEqual(try parseArguments(["list", "--version"]).command, "version")
    }

    func testScopeFlagsRejectedOnCommandsThatIgnoreThem() {
        assertUsage(try validateScopeFlags(parseArguments(["list", "--device", "x"])))
        assertUsage(try validateScopeFlags(parseArguments(["status", "--input"])))
    }

    func testScopeFlagsAcceptedOnScopedCommands() throws {
        try validateScopeFlags(parseArguments(["volume", "get", "--input"]))
        try validateScopeFlags(parseArguments(["samplerate", "get", "--device", "x"]))
        try validateScopeFlags(parseArguments(["mute", "toggle", "-i"]))
    }

    // MARK: -

    private func assertUsage<T>(_ expr: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) { error in
            guard let e = error as? CLIError else {
                return XCTFail("expected CLIError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(e.exitCode, 2, "expected a usage error", file: file, line: line)
        }
    }
}
