// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon.HIToolbox
import XCTest
@testable import AudioCtlCore

final class KeyComboTests: XCTestCase {
    func testParsesModifiersAndKey() throws {
        let c = try KeyCombo.parse("ctrl+opt+,")
        XCTAssertEqual(c.keyCode, kVK_ANSI_Comma)
        XCTAssertEqual(c.mods, UInt32(controlKey | optionKey))
    }

    func testModifierAliases() throws {
        XCTAssertEqual(try KeyCombo.parse("control+option+m"), try KeyCombo.parse("ctrl+alt+m"))
        XCTAssertEqual(try KeyCombo.parse("cmd+shift+f1"), try KeyCombo.parse("command+shift+f1"))
    }

    func testKeyNameAliases() throws {
        XCTAssertEqual(try KeyCombo.parse("ctrl+opt+comma"), try KeyCombo.parse("ctrl+opt+,"))
        XCTAssertEqual(try KeyCombo.parse("ctrl+opt+period"), try KeyCombo.parse("ctrl+opt+."))
    }

    func testCaseAndWhitespaceInsensitive() throws {
        XCTAssertEqual(try KeyCombo.parse("  CTRL+Opt+M  "), try KeyCombo.parse("ctrl+opt+m"))
    }

    /// "+" as the bound key: the trailing separator must not be read as an empty key.
    func testPlusAsKey() throws {
        XCTAssertEqual(try KeyCombo.parse("ctrl+opt++"), try KeyCombo.parse("ctrl+opt+plus"))
    }

    func testCanonicalRoundTrips() throws {
        for text in ["ctrl+opt+,", "cmd+shift+f5", "ctrl+opt+m", "opt+space"] {
            let once = try KeyCombo.parse(text)
            let twice = try KeyCombo.parse(once.canonical)
            XCTAssertEqual(once, twice, "\(text) did not round-trip via \(once.canonical)")
        }
    }

    /// Modifiers are normalised to the order macOS itself uses, ⌃⌥⇧⌘, whatever
    /// order they were typed in — so one combo has exactly one spelling on disk.
    func testCanonicalOrdersModifiersConsistently() throws {
        XCTAssertEqual(try KeyCombo.parse("opt+ctrl+m").canonical, "ctrl+opt+m")
        XCTAssertEqual(try KeyCombo.parse("cmd+shift+ctrl+a").canonical, "ctrl+shift+cmd+a")
    }

    func testDisplayCapitalisesModifiersOnly() throws {
        XCTAssertEqual(try KeyCombo.parse("ctrl+opt+,").display, "Ctrl+Opt+,")
        XCTAssertEqual(try KeyCombo.parse("cmd+shift+f5").display, "Shift+Cmd+F5")
    }

    func testRejectsUnknownModifierAndKey() {
        XCTAssertThrowsError(try KeyCombo.parse("hyper+m"))
        XCTAssertThrowsError(try KeyCombo.parse("ctrl+opt+nosuchkey"))
        XCTAssertThrowsError(try KeyCombo.parse(""))
    }

    /// A bare key would swallow that key for every app on the system.
    func testRejectsComboWithoutModifier() {
        XCTAssertThrowsError(try KeyCombo.parse("m"))
        XCTAssertThrowsError(try KeyCombo.parse("f5"))
    }
}

final class HotkeyConfigTests: XCTestCase {
    func testDefaultsAreValid() throws {
        XCTAssertNoThrow(try HotkeyConfig.defaults.validated())
        XCTAssertEqual(HotkeyConfig.defaults.bindings.count, 2)
    }

    func testEncodeDecodeRoundTrip() throws {
        let config = HotkeyConfig(bindings: [
            Binding(keys: "ctrl+opt+m", action: .muteToggle),
            Binding(keys: "cmd+shift+f5", action: .volumeUp),
        ])
        XCTAssertEqual(try HotkeyConfig.decode(config.encoded()), config)
    }

    func testDecodeRejectsMalformedJSON() {
        XCTAssertThrowsError(try HotkeyConfig.decode(Data("{ not json".utf8)))
        XCTAssertThrowsError(try HotkeyConfig.decode(Data(#"{"bindings":[{"keys":"ctrl+opt+m"}]}"#.utf8)))
    }

    func testDecodeRejectsUnknownAction() {
        XCTAssertThrowsError(
            try HotkeyConfig.decode(Data(#"{"bindings":[{"keys":"ctrl+opt+m","action":"explode"}]}"#.utf8)))
    }

    func testValidationRejectsUnparsableCombo() {
        let config = HotkeyConfig(bindings: [Binding(keys: "ctrl+opt+nope", action: .muteToggle)])
        XCTAssertThrowsError(try config.validated())
    }

    /// Two actions on one combo would leave the second silently dead.
    func testValidationRejectsDuplicateCombo() {
        let config = HotkeyConfig(bindings: [
            Binding(keys: "ctrl+opt+m", action: .muteToggle),
            Binding(keys: "opt+ctrl+m", action: .volumeUp),  // same combo, different spelling
        ])
        XCTAssertThrowsError(try config.validated())
    }

    func testEveryActionHasASummary() {
        for action in HotkeyAction.allCases {
            XCTAssertFalse(action.summary.isEmpty, "\(action.rawValue) has no description")
            XCTAssertEqual(HotkeyAction(rawValue: action.rawValue), action)
        }
    }

    func testConfigPathHonoursXDGConfigHome() {
        // documents the contract; the environment is not mutated here
        XCTAssertTrue(configPath().hasSuffix("audioctl/hotkeys.json"))
    }
}
