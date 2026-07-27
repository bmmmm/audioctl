// SPDX-License-Identifier: GPL-3.0-or-later
// One function per user-facing command.

import CoreAudio
import Foundation

func cmdList(_ mode: String, json: Bool) throws {
    guard ["out", "in", "all"].contains(mode) else {
        throw CLIError.usage("unknown list mode \"\(mode)\" — use out, in or all")
    }
    let defOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let defIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let devices = sortedDevices().filter { d in
        switch mode {
        case "out": return selectable(d, OUT)
        case "in": return selectable(d, IN)
        default: return selectable(d, OUT) || selectable(d, IN)
        }
    }
    if json {
        try printJSON(devices.map(deviceJSON))
        return
    }
    for d in devices {
        let outSel = selectable(d, OUT), inSel = selectable(d, IN)
        let out = channelCount(d, OUT), inp = channelCount(d, IN)
        let dir = outSel && inSel ? "i/o" : outSel ? "out" : "in "
        let marker = (d == defOut && outSel) || (d == defIn && inSel) ? "*" : " "
        let ch = out > 0 && inp > 0 ? "\(out)o/\(inp)i" : "\(max(out, inp))ch"
        print("\(marker) [\(dir)] \(deviceName(d).padded(30)) "
            + "\(transportType(d).padded(11)) \(ch.padded(7)) \(fmtRate(sampleRate(d)))")
    }
}

func cmdInfo(_ ref: String, json: Bool) throws {
    let d = try resolveDevice(ref, scope: nil)
    if json { try printJSON(deviceJSON(d)); return }
    print("name:        \(deviceName(d))")
    print("uid:         \(deviceUID(d))")
    print("transport:   \(transportType(d))")
    print("channels:    \(channelCount(d, OUT)) out / \(channelCount(d, IN)) in")
    print("sample rate: \(fmtRate(sampleRate(d)))")
    let rates = availableSampleRates(d)
    if !rates.isEmpty { print("  available: \(rates.map { String(format: "%.0f", $0) }.joined(separator: ", "))") }
    print("out volume:  \(fmtVol(volume(d, OUT)))  mute: \(fmtMute(muted(d, OUT)))")
    print("in  volume:  \(fmtVol(volume(d, IN)))  mute: \(fmtMute(muted(d, IN)))")
    print("state:       \(isAlive(d) ? "alive" : "dead")\(isRunning(d) ? ", running" : "")")
    var roles: [String] = []
    if d == defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) { roles.append("default output") }
    if d == defaultDevice(kAudioHardwarePropertyDefaultInputDevice) { roles.append("default input") }
    if d == defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) { roles.append("default system") }
    if !roles.isEmpty { print("default:     \(roles.joined(separator: ", "))") }
}

/// output/input/system default-device get/set/list/cycle.
func cmdDefault(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                label: String, args: [String], json: Bool) throws {
    let sub = args.first ?? "get"
    switch sub {
    case "get":
        let name = deviceName(defaultDevice(selector))
        if json { try printJSON(["device": name]) } else { print(name) }
    case "list":
        try cmdList(scope == IN ? "in" : "out", json: json)
    case "set":
        guard args.count > 1 else { throw CLIError.usage("usage: audioctl \(label) set \"<name|uid>\"") }
        let d = try resolveDevice(args[1], scope: scope)
        guard setDefaultDevice(selector, d) else { throw CLIError.runtime("failed to set \(label) device") }
        print("\(label) -> \(deviceName(d))")
    case "next", "prev":
        guard let name = cycleDefault(selector, scope, forward: sub == "next") else {
            throw CLIError.runtime("no \(label) devices to cycle")
        }
        print("\(label) -> \(name)")
    default:
        throw CLIError.usage("usage: audioctl \(label) [get | list | set \"<name|uid>\" | next | prev]")
    }
}

func resolveTarget(input: Bool, device: String?) throws -> (AudioObjectID, AudioObjectPropertyScope) {
    let scope = input ? IN : OUT
    if let ref = device { return (try resolveDevice(ref, scope: scope), scope) }
    let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    let d = defaultDevice(sel)
    guard d != 0 else {
        throw CLIError.runtime("no default \(input ? "input" : "output") device is set")
    }
    return (d, scope)
}

/// Parse a 0..100 percentage. Rejects NaN and infinity, which a plain clamp would
/// turn into full volume.
func parsePercent(_ text: String) throws -> Double {
    guard let v = Double(text), v.isFinite else {
        throw CLIError.usage("\"\(text)\" is not a number between 0 and 100")
    }
    guard v >= 0, v <= 100 else {
        throw CLIError.usage("volume \(text) is out of range — use 0 to 100")
    }
    return v
}

// The argument check runs before the device is resolved, so a bad invocation is
// a usage error (exit 2) regardless of what hardware happens to be attached.
func cmdVolume(args: [String], input: Bool, device: String?, json: Bool) throws {
    let sub = args.first ?? "get"
    var target: Double?
    switch sub {
    case "get": break
    case "set":
        guard args.count > 1 else { throw CLIError.usage("usage: audioctl volume set <0-100>") }
        target = try parsePercent(args[1])
    default:
        throw CLIError.usage("usage: audioctl volume [get | set <0-100>] [--input] [--device \"<name|uid>\"]")
    }

    let (d, scope) = try resolveTarget(input: input, device: device)
    switch sub {
    case "get":
        guard let v = volume(d, scope) else {
            throw CLIError.runtime("\(deviceName(d)) has no volume control")
        }
        if json { try printJSON(["device": deviceName(d), "volume": Int((v * 100).rounded())]) }
        else { print(Int((v * 100).rounded())) }
    default:
        let pct = target!
        guard setVolume(d, scope, Float(pct / 100.0)) else {
            throw CLIError.runtime("\(deviceName(d)) volume is not settable")
        }
        // echo what was actually applied, read back from the device
        let applied = volume(d, scope).map { Int(($0 * 100).rounded()) } ?? Int(pct.rounded())
        print("\(deviceName(d)) volume -> \(applied)%")
    }
}

func cmdMute(args: [String], input: Bool, device: String?, json: Bool) throws {
    let sub = args.first ?? "get"
    guard ["get", "on", "off", "toggle"].contains(sub) else {
        throw CLIError.usage("usage: audioctl mute [get | on | off | toggle] [--input] [--device \"<name|uid>\"]")
    }
    let (d, scope) = try resolveTarget(input: input, device: device)
    switch sub {
    case "get":
        guard let m = muted(d, scope) else { throw CLIError.runtime("\(deviceName(d)) has no mute control") }
        if json { try printJSON(["device": deviceName(d), "muted": m]) } else { print(m ? "on" : "off") }
    default:
        let want = sub == "toggle" ? !(muted(d, scope) ?? false) : sub == "on"
        guard setMuted(d, scope, want) else { throw CLIError.runtime("\(deviceName(d)) mute is not settable") }
        print("\(deviceName(d)) mute -> \(want ? "on" : "off")")
    }
}

func cmdSampleRate(args: [String], input: Bool, device: String?, json: Bool) throws {
    let sub = args.first ?? "get"
    var target: Double?
    switch sub {
    case "get", "list": break
    case "set":
        guard args.count > 1 else { throw CLIError.usage("usage: audioctl samplerate set <hz>") }
        guard let hz = Double(args[1]), hz.isFinite, hz > 0 else {
            throw CLIError.usage("\"\(args[1])\" is not a positive sample rate in Hz")
        }
        target = hz
    default:
        throw CLIError.usage("usage: audioctl samplerate [get | list | set <hz>] [--input] [--device \"<name|uid>\"]")
    }

    let (d, _) = try resolveTarget(input: input, device: device)
    switch sub {
    case "get":
        guard let hz = sampleRate(d) else { throw CLIError.runtime("\(deviceName(d)) has no sample rate") }
        if json { try printJSON(["device": deviceName(d), "sample_rate": hz]) } else { print(Int(hz)) }
    case "list":
        let rates = availableSampleRates(d)
        if json { try printJSON(["device": deviceName(d), "available_sample_rates": rates]) }
        else { rates.forEach { print(Int($0)) } }
    default:
        let hz = target!
        guard setSampleRate(d, hz) else {
            throw CLIError.runtime("\(deviceName(d)) does not accept \(Int(hz)) Hz (see: audioctl samplerate list)")
        }
        print("\(deviceName(d)) sample rate -> \(Int(hz)) Hz")
    }
}

// -- status ------------------------------------------------------------------

func hotkeyJSON() throws -> [String: Any] {
    let s = hotkeyAgentState()
    let loaded = Result { try loadHotkeyConfig() }
    let config = (try? loaded.get()) ?? HotkeyConfig(bindings: [])
    return [
        "bindings": try config.bindings.map { b -> [String: Any] in
            ["keys": try KeyCombo.parse(b.keys).display,
             "action": b.action.rawValue,
             "description": b.action.summary]
        },
        "config_error": (loaded.failure as? CLIError)?.message as Any? ?? NSNull(),
        "config_path": configPath(),
        "config_present": FileManager.default.fileExists(atPath: configPath()),
        "agent_loaded": s.loaded,
        "agent_pid": s.pid.map { $0 as Any } ?? NSNull(),
        "plist_path": hotkeyPlistPath(),
        "plist_present": s.plistPresent,
        "plist_binary": s.plistBinary.map { $0 as Any } ?? NSNull(),
        "plist_binary_stale": s.stale,
        "running_binary": binaryPath(),
    ]
}

/// Renders the hotkey section. Returns false if the config could not be read —
/// the caller decides whether that is fatal. `status` keeps showing the audio
/// state either way; a broken hotkey file should not blind the whole overview.
@discardableResult
func printHotkeyStatus(indent: String = "") -> Bool {
    let s = hotkeyAgentState()
    let loaded = Result { try loadHotkeyConfig() }
    let config = (try? loaded.get()) ?? HotkeyConfig(bindings: [])

    if loaded.failure != nil {
        print("\(indent)bindings:  unavailable — config is broken, no hotkeys are active")
    } else if config.bindings.isEmpty {
        print("\(indent)bindings:  none")
    }
    for (i, b) in config.bindings.enumerated() {
        let combo = (try? KeyCombo.parse(b.keys))?.display ?? b.keys
        print("\(indent)\(i == 0 ? "bindings: " : "          ") \(combo.padded(14)) \(b.action.summary)")
    }
    let present = FileManager.default.fileExists(atPath: configPath())
    print("\(indent)config:    \(present ? configPath() : "\(configPath()) (absent — using defaults)")")
    if let error = loaded.failure as? CLIError {
        for line in error.message.split(separator: "\n") { print("\(indent)  \(line)") }
    }
    let pid = s.pid.map { " (pid \($0))" } ?? ""
    print("\(indent)agent:     \(s.loaded ? "loaded\(pid)" : "not loaded")")
    print("\(indent)plist:     \(s.plistPresent ? hotkeyPlistPath() : "absent (run: audioctl hotkeys install)")")
    if let b = s.plistBinary, s.stale {
        print("\(indent)  stale:   agent runs \(b)")
        print("\(indent)           this binary is \(binaryPath()) — re-run `audioctl hotkeys install` here")
    }
    return loaded.failure == nil
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

/// Everything currently in effect: the three default devices, their volume / mute /
/// sample rate, and the hotkey bindings plus the launch agent behind them.
func cmdStatus(json: Bool) throws {
    let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let inp = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let system = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)

    if json {
        try printJSON([
            "version": VERSION,
            "default_output": deviceJSON(out),
            "default_input": deviceJSON(inp),
            "default_system": deviceJSON(system),
            "hotkeys": try hotkeyJSON(),
        ])
        return
    }

    func line(_ label: String, _ d: AudioObjectID, _ scope: AudioObjectPropertyScope) {
        print("\(label.padded(10)) \(deviceName(d))")
        print("           \(transportType(d)) · \(fmtRate(sampleRate(d)))"
            + " · volume \(fmtVol(volume(d, scope))) · mute \(fmtMute(muted(d, scope)))")
    }

    print("audioctl \(VERSION)\n")
    line("output:", out, OUT)
    line("input:", inp, IN)
    print("system:    \(deviceName(system))")
    print("")
    print("hotkeys")
    printHotkeyStatus(indent: "  ")
}

// -- hotkey management -------------------------------------------------------

func cmdHotkeys(args: [String], json: Bool) throws {
    switch args.first {
    case "install": try installHotkeys()
    case "uninstall": uninstallHotkeys()
    case "status":
        if json { try printJSON(try hotkeyJSON()) }
        else if !printHotkeyStatus() {
            // shown above in context; exit non-zero so scripts notice
            throw CLIError.silent(1)
        }
    case "plist": print(hotkeyPlist())
    case "bind": try cmdBind(Array(args.dropFirst()))
    case "unbind": try cmdUnbind(Array(args.dropFirst()))
    case "reset":
        try saveHotkeyConfig(HotkeyConfig.defaults)
        print("bindings reset to defaults (\(configPath()))")
        reportReload()
    case "actions":
        for a in HotkeyAction.allCases { print("\(a.rawValue.padded(20)) \(a.summary)") }
    case "keys":
        let names = KEY_CODES.keys.sorted()
        print(names.joined(separator: " "))
        print("\nmodifiers: ctrl, opt (alt), shift, cmd — at least one is required")
    case nil, "run": try runHotkeys()
    default:
        throw CLIError.usage(HOTKEY_USAGE)
    }
}

func cmdBind(_ args: [String]) throws {
    guard args.count >= 2 else {
        throw CLIError.usage("usage: audioctl hotkeys bind \"<keys>\" <action>\n"
            + "  e.g. audioctl hotkeys bind \"ctrl+opt+m\" mute-toggle    (see: audioctl hotkeys actions)")
    }
    let combo = try KeyCombo.parse(args[0])
    guard let action = HotkeyAction(rawValue: args[1]) else {
        throw CLIError.usage("unknown action \"\(args[1])\" — one of: "
            + HotkeyAction.allCases.map(\.rawValue).joined(separator: ", "))
    }
    var config = try loadHotkeyConfig()
    config.bindings.removeAll { (try? KeyCombo.parse($0.keys))?.canonical == combo.canonical }
    config.bindings.append(Binding(keys: combo.canonical, action: action))
    try saveHotkeyConfig(config.validated())
    print("bound \(combo.display) -> \(action.summary)")
    reportReload()
}

func cmdUnbind(_ args: [String]) throws {
    guard let keys = args.first else { throw CLIError.usage("usage: audioctl hotkeys unbind \"<keys>\"") }
    let combo = try KeyCombo.parse(keys)
    var config = try loadHotkeyConfig()
    let before = config.bindings.count
    config.bindings.removeAll { (try? KeyCombo.parse($0.keys))?.canonical == combo.canonical }
    guard config.bindings.count < before else {
        throw CLIError.runtime("\(combo.display) is not bound (see: audioctl hotkeys status)")
    }
    try saveHotkeyConfig(config)
    print("unbound \(combo.display)")
    reportReload()
}

/// Bindings are read at agent start, so a change only takes effect after a
/// restart — do it, and say so either way.
func reportReload() {
    if reloadAgentIfLoaded() { print("launch agent restarted — the new bindings are live") }
    else if hotkeyAgentState().plistPresent {
        print("note: the launch agent is not running — start it with `audioctl hotkeys install`")
    }
}
