// SPDX-License-Identifier: GPL-3.0-or-later
// Registering the bindings with Carbon and running them as a launchd agent.
//
// RegisterEventHotKey is a registered system hotkey, not an event tap, so it
// needs no Accessibility / Input-Monitoring permission. A faceless NSApplication
// (.accessory) pumps the event loop without a Dock icon or an .app bundle.

import AppKit
import Carbon.HIToolbox
import CoreAudio
import Foundation

let HOTKEY_LABEL = "audioctl.hotkeys"

func hotkeyPlistPath() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/\(HOTKEY_LABEL).plist")
}

func binaryPath() -> String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

func realPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

func hotkeyPlist() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(HOTKEY_LABEL)</string>
        <key>ProgramArguments</key>
        <array><string>\(binaryPath())</string><string>hotkeys</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Interactive</string>
    </dict>
    </plist>
    """
}

func launchctlOutput(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    // read before waiting: `launchctl print` output can exceed the pipe buffer and deadlock
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

@discardableResult
func launchctl(_ args: [String]) -> Int32 { launchctlOutput(args).status }

// -- agent state -------------------------------------------------------------

struct HotkeyAgentState {
    let loaded: Bool
    let pid: Int?
    let plistPresent: Bool
    /// Binary the installed plist points at — the agent keeps running the path it
    /// was installed from, so a moved binary silently leaves it stale. Compared
    /// symlink-resolved: an install via a PATH symlink is the same binary, not stale.
    let plistBinary: String?
    var stale: Bool { plistBinary.map { realPath($0) != realPath(binaryPath()) } ?? false }
}

func hotkeyAgentState() -> HotkeyAgentState {
    let (st, out) = launchctlOutput(["print", "gui/\(getuid())/\(HOTKEY_LABEL)"])
    var pid: Int?
    if st == 0, let r = out.range(of: #"(?m)^\s*pid = (\d+)"#, options: .regularExpression) {
        pid = Int(out[r].split(separator: "=")[1].trimmingCharacters(in: .whitespaces))
    }
    let path = hotkeyPlistPath()
    var binary: String?
    if let data = FileManager.default.contents(atPath: path),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        binary = (plist["ProgramArguments"] as? [String])?.first
    }
    return HotkeyAgentState(loaded: st == 0, pid: pid,
                            plistPresent: FileManager.default.fileExists(atPath: path), plistBinary: binary)
}

/// Restart a loaded agent so edited bindings take effect immediately. A no-op
/// when the agent is not running.
func reloadAgentIfLoaded() -> Bool {
    guard hotkeyAgentState().loaded else { return false }
    return launchctl(["kickstart", "-k", "gui/\(getuid())/\(HOTKEY_LABEL)"]) == 0
}

func installHotkeys() throws {
    let config = try loadHotkeyConfig()
    let path = hotkeyPlistPath()
    do {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try hotkeyPlist().write(toFile: path, atomically: true, encoding: .utf8)
    } catch { throw CLIError.runtime("cannot write \(path): \(error)") }
    let uid = getuid()
    launchctl(["bootout", "gui/\(uid)/\(HOTKEY_LABEL)"])  // ignore if not already loaded
    var st = launchctl(["bootstrap", "gui/\(uid)", path])
    if st != 0 {  // launchd tears the old job down asynchronously — let it settle, retry once
        usleep(300_000)
        st = launchctl(["bootstrap", "gui/\(uid)", path])
    }
    guard st == 0 else {
        throw CLIError.runtime("wrote \(path), but launchctl bootstrap failed (\(st)). Load it with:\n"
            + "  launchctl bootstrap gui/\(uid) \(path)")
    }
    print("hotkeys installed: \(path)")
    for b in config.bindings { print("  \(b.combo.display.padded(12)) \(b.action.summary)") }
}

func uninstallHotkeys() {
    launchctl(["bootout", "gui/\(getuid())/\(HOTKEY_LABEL)"])
    let path = hotkeyPlistPath()
    try? FileManager.default.removeItem(atPath: path)
    print("hotkeys uninstalled (\(path) removed)")
}

// -- running -----------------------------------------------------------------

/// Set once before the event loop starts; the Carbon handler is a bare C function
/// pointer and cannot capture context.
private var activeActions: [UInt32: HotkeyAction] = [:]

func runHotkeys() throws {
    let config = try loadHotkeyConfig()
    guard !config.bindings.isEmpty else {
        throw CLIError.runtime("no hotkeys bound — see: audioctl hotkeys bind \"<keys>\" <action>")
    }
    let agent = hotkeyAgentState()
    if agent.loaded {
        FileHandle.standardError.write(("warning: the launch agent is already running (pid "
            + "\(agent.pid.map(String.init) ?? "?")) and holds these combos too — both instances will "
            + "react, moving two steps per press. Stop it with `audioctl hotkeys uninstall` first.\n")
            .data(using: .utf8)!)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // faceless: no Dock icon, no .app bundle
    let target = GetApplicationEventTarget()
    let sig = OSType(0x61637468)  // 'acth'

    for (i, b) in config.bindings.enumerated() {
        let combo = try KeyCombo.parse(b.keys)
        let id = UInt32(i + 1)
        activeActions[id] = b.action
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(combo.keyCode), combo.mods,
                                     EventHotKeyID(signature: sig, id: id), target, 0, &ref)
        if st != noErr {
            // Note: RegisterEventHotKey usually still returns noErr when another app
            // already owns the combo — the keys then silently do nothing. So a clean
            // start is not proof the hotkeys work; see the README troubleshooting note.
            FileHandle.standardError.write(
                "warning: registering \(combo.display) returned \(st), expected 0\n".data(using: .utf8)!)
        }
    }

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handler: EventHandlerUPP = { _, event, _ in
        guard let event = event else { return noErr }
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        if let action = activeActions[id.id], let msg = perform(action) {
            print(msg); fflush(stdout)
        }
        return noErr
    }
    InstallEventHandler(target, handler, 1, &spec, nil, nil)
    print("audioctl hotkeys running — "
        + config.bindings.map { "\($0.combo.display) = \($0.action.summary)" }.joined(separator: " · "))
    fflush(stdout)
    app.run()
}

/// Apply one bound action. Returns the line to log, or nil if it did nothing.
func perform(_ action: HotkeyAction) -> String? {
    switch action {
    case .outputNext, .outputPrev:
        let name = cycleDefault(kAudioHardwarePropertyDefaultOutputDevice, OUT,
                                forward: action == .outputNext)
        return name.map { "output -> \($0)" }
    case .inputNext, .inputPrev:
        let name = cycleDefault(kAudioHardwarePropertyDefaultInputDevice, IN,
                                forward: action == .inputNext)
        return name.map { "input -> \($0)" }
    case .muteToggle, .inputMuteToggle:
        let isInput = action == .inputMuteToggle
        let scope = isInput ? IN : OUT
        let d = defaultDevice(isInput ? kAudioHardwarePropertyDefaultInputDevice
                                      : kAudioHardwarePropertyDefaultOutputDevice)
        let want = !(muted(d, scope) ?? false)
        guard setMuted(d, scope, want) else { return nil }
        return "\(isInput ? "input" : "output") mute -> \(want ? "on" : "off")"
    case .volumeUp, .volumeDown:
        let d = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard let current = volume(d, OUT) else { return nil }
        let step = Float(VOLUME_STEP_PERCENT) / 100 * (action == .volumeUp ? 1 : -1)
        guard setVolume(d, OUT, current + step) else { return nil }
        let applied = volume(d, OUT).map { Int(($0 * 100).rounded()) }
        return applied.map { "volume -> \($0)%" }
    }
}
