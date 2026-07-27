// SPDX-License-Identifier: GPL-3.0-or-later
// Hotkey bindings: what a combo does, how a combo is written, and where the
// user's own bindings are stored. Pure logic — no CoreAudio, no launchd — so it
// is exercised directly by the tests.

import Carbon.HIToolbox
import Foundation

// -- actions -----------------------------------------------------------------

enum HotkeyAction: String, CaseIterable, Codable {
    case outputNext = "output-next"
    case outputPrev = "output-prev"
    case inputNext = "input-next"
    case inputPrev = "input-prev"
    case muteToggle = "mute-toggle"
    case inputMuteToggle = "input-mute-toggle"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"

    var summary: String {
        switch self {
        case .outputNext: return "next output device"
        case .outputPrev: return "previous output device"
        case .inputNext: return "next input device"
        case .inputPrev: return "previous input device"
        case .muteToggle: return "toggle output mute"
        case .inputMuteToggle: return "toggle input (microphone) mute"
        case .volumeUp: return "output volume +\(VOLUME_STEP_PERCENT)%"
        case .volumeDown: return "output volume -\(VOLUME_STEP_PERCENT)%"
        }
    }
}

let VOLUME_STEP_PERCENT = 5

// -- key combinations --------------------------------------------------------

/// A parsed combo: Carbon modifier mask plus virtual key code.
struct KeyCombo: Equatable {
    let mods: UInt32
    let keyCode: Int

    /// Canonical lowercase spelling, e.g. `ctrl+opt+,` — this is what is written
    /// to the config file, so re-reading a written binding yields the same combo.
    var canonical: String {
        var parts: [String] = []
        if mods & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if mods & UInt32(optionKey) != 0 { parts.append("opt") }
        if mods & UInt32(shiftKey) != 0 { parts.append("shift") }
        if mods & UInt32(cmdKey) != 0 { parts.append("cmd") }
        parts.append(keyName(keyCode) ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// How the combo is shown to the user, e.g. `Ctrl+Opt+,`.
    var display: String {
        canonical.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.count > 1 ? $0.prefix(1).uppercased() + $0.dropFirst() : String($0) }
            .joined(separator: "+")
    }

    static func parse(_ text: String) throws -> KeyCombo {
        let raw = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { throw CLIError.usage("empty key combination") }
        // A trailing "+" means the key itself is "+": "ctrl+opt++" → tokens drop to
        // the modifiers and the key falls back to plus.
        var tokens = raw.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        var keyToken = raw.hasSuffix("+") ? "+" : (tokens.popLast() ?? "")

        var mods: UInt32 = 0
        for t in tokens {
            switch t {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            case "cmd", "command", "meta": mods |= UInt32(cmdKey)
            default:
                throw CLIError.usage(
                    "unknown modifier \"\(t)\" in \"\(text)\" — use ctrl, opt, shift or cmd")
            }
        }
        if keyToken == "" { keyToken = "+" }
        guard let code = keyCodeNamed(keyToken) else {
            throw CLIError.usage("unknown key \"\(keyToken)\" in \"\(text)\" "
                + "— see `audioctl hotkeys keys` for the accepted names")
        }
        guard mods != 0 else {
            throw CLIError.usage(
                "\"\(text)\" has no modifier — a bare key would swallow that key system-wide")
        }
        return KeyCombo(mods: mods, keyCode: code)
    }
}

/// Accepted key names → virtual key code. Punctuation is spelled both literally
/// (",") and by name ("comma") so both `--bind "ctrl+opt+,"` and a quoting-averse
/// shell work.
let KEY_CODES: [String: Int] = {
    var m: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return, "escape": kVK_Escape,
        "delete": kVK_Delete, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "left": kVK_LeftArrow, "right": kVK_RightArrow,
    ]
    let named: [String: Int] = [
        "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "dot": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "plus": kVK_ANSI_Equal,
        "+": kVK_ANSI_Equal, "grave": kVK_ANSI_Grave, "esc": kVK_Escape, "enter": kVK_Return,
    ]
    m.merge(named) { a, _ in a }
    for n in 1...12 {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                     kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        m["f\(n)"] = codes[n - 1]
    }
    return m
}()

func keyCodeNamed(_ name: String) -> Int? { KEY_CODES[name] }

/// Preferred spelling for a key code — the literal form where one exists, so a
/// binding round-trips to the same text the user typed.
func keyName(_ code: Int) -> String? {
    let preferred = KEY_CODES.filter { $0.value == code }.map(\.key).sorted {
        // shortest first ("," before "comma"), alphabetical as tiebreak
        $0.count != $1.count ? $0.count < $1.count : $0 < $1
    }
    return preferred.first
}

// -- bindings and their persistence ------------------------------------------

struct Binding: Codable, Equatable {
    let keys: String
    let action: HotkeyAction

    var combo: KeyCombo { (try? KeyCombo.parse(keys)) ?? KeyCombo(mods: 0, keyCode: -1) }
}

struct HotkeyConfig: Codable, Equatable {
    var bindings: [Binding]

    static let defaults = HotkeyConfig(bindings: [
        Binding(keys: "ctrl+opt+,", action: .outputPrev),
        Binding(keys: "ctrl+opt+.", action: .outputNext),
    ])

    /// Validate every combo up front so a typo surfaces at `bind`/`status` time
    /// rather than as a hotkey that silently never fires.
    func validated() throws -> HotkeyConfig {
        var seen: [String: HotkeyAction] = [:]
        for b in bindings {
            let combo = try KeyCombo.parse(b.keys)
            if let other = seen[combo.canonical] {
                throw CLIError.runtime(
                    "\(combo.display) is bound twice (\(other.rawValue) and \(b.action.rawValue))")
            }
            seen[combo.canonical] = b.action
        }
        return self
    }

    static func decode(_ data: Data) throws -> HotkeyConfig {
        do {
            return try JSONDecoder().decode(HotkeyConfig.self, from: data)
        } catch {
            throw CLIError.runtime("\(configPath()) is not a valid hotkey config: \(explain(error))\n"
                + "  expected: {\"bindings\": [{\"keys\": \"ctrl+opt+,\", \"action\": \"output-prev\"}]}\n"
                + "  restore the defaults with: audioctl hotkeys reset")
        }
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// One readable sentence out of a DecodingError, instead of dumping the whole
/// nested Swift error at the user.
func explain(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return error.localizedDescription }
    func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
    }
    switch e {
    case .dataCorrupted(let ctx):
        return path(ctx).isEmpty ? ctx.debugDescription : "\(path(ctx)): \(ctx.debugDescription)"
    case .keyNotFound(let key, let ctx):
        return "missing \"\(key.stringValue)\"\(path(ctx).isEmpty ? "" : " in \(path(ctx))")"
    case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
        return "\(path(ctx).isEmpty ? "value" : path(ctx)): \(ctx.debugDescription)"
    @unknown default:
        return error.localizedDescription
    }
}

func configPath() -> String {
    if let dir = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !dir.isEmpty {
        return (dir as NSString).appendingPathComponent("audioctl/hotkeys.json")
    }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".config/audioctl/hotkeys.json")
}

/// The bindings actually in effect. A missing config means defaults; an
/// unreadable or malformed one is an error, never a silent fallback to defaults —
/// that would report a working setup while the user's own bindings are ignored.
func loadHotkeyConfig() throws -> HotkeyConfig {
    let path = configPath()
    guard FileManager.default.fileExists(atPath: path) else { return HotkeyConfig.defaults }
    guard let data = FileManager.default.contents(atPath: path) else {
        throw CLIError.runtime("cannot read \(path)")
    }
    return try HotkeyConfig.decode(data).validated()
}

func saveHotkeyConfig(_ config: HotkeyConfig) throws {
    let path = configPath()
    do {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try config.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        throw CLIError.runtime("cannot write \(path): \(error)")
    }
}
