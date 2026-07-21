// SPDX-License-Identifier: GPL-3.0-or-later
// audioctl — control macOS audio from the command line via CoreAudio.
//
// A single-file, dependency-free native CLI: switch the default output / input /
// system device, read and set volume and mute, read and set the sample rate, and
// dump full device info — with `--json` for scripting. No brew, no .app bundle,
// no TCC permission (audio *routing* and output control are not permission-gated;
// only capturing microphone input would be, which this tool never does).

import AppKit
import Carbon.HIToolbox
import CoreAudio
import Foundation

let VERSION = "0.1.0"
let OUT = kAudioObjectPropertyScopeOutput
let IN = kAudioObjectPropertyScopeInput
let sys = AudioObjectID(kAudioObjectSystemObject)

// -- generic CoreAudio property access ---------------------------------------

func propAddr(_ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
              -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func hasProp(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var a = a
    return AudioObjectHasProperty(obj, &a)
}

func isSettable(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var a = a
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(obj, &a, &settable) == noErr && settable.boolValue
}

func getValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = a
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    return st == noErr ? value : nil
}

func setValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> Bool {
    var a = a
    var value = value
    return withUnsafePointer(to: &value) {
        AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
    }
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) -> [T] {
    var a = a
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    var arr = [T](repeating: zero, count: count)
    size = UInt32(count * MemoryLayout<T>.stride)  // report the real buffer size, not the (maybe larger) queried size
    let st = arr.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0.baseAddress!)
    }
    return st == noErr ? arr : []
}

func getString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    var a = a
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    guard st == noErr, let s = cf?.takeRetainedValue() else { return nil }
    return s as String
}

// -- device model ------------------------------------------------------------

func allDevices() -> [AudioObjectID] {
    getArray(sys, propAddr(kAudioHardwarePropertyDevices), AudioObjectID(0))
}

func deviceName(_ d: AudioObjectID) -> String { getString(d, propAddr(kAudioObjectPropertyName)) ?? "?" }
func deviceUID(_ d: AudioObjectID) -> String { getString(d, propAddr(kAudioDevicePropertyDeviceUID)) ?? "?" }

func channelCount(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = propAddr(kAudioDevicePropertyStreamConfiguration, scope)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, ptr) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportType(_ d: AudioObjectID) -> String {
    guard let t: UInt32 = getValue(d, propAddr(kAudioDevicePropertyTransportType), UInt32(0)) else { return "?" }
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
    case kAudioDeviceTransportTypeHDMI: return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort: return "displayport"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
    case kAudioDeviceTransportTypePCI: return "pci"
    case kAudioDeviceTransportTypeAVB: return "avb"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    default: return "other"
    }
}

func isAlive(_ d: AudioObjectID) -> Bool {
    (getValue(d, propAddr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) != 0
}

func isRunning(_ d: AudioObjectID) -> Bool {
    (getValue(d, propAddr(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) != 0
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    getValue(sys, propAddr(selector), AudioObjectID(0)) ?? 0
}

func setDefaultDevice(_ selector: AudioObjectPropertySelector, _ d: AudioObjectID) -> Bool {
    setValue(sys, propAddr(selector), d)
}

/// Whether a device can serve as the default for a scope. Prefers the HAL's own
/// "can be default" flag — true for AirPlay endpoints even while idle with zero
/// channels — and falls back to a positive channel count.
func selectable(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    if (getValue(d, propAddr(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope), UInt32(0)) ?? 0) != 0 {
        return true
    }
    return channelCount(d, scope) > 0
}

/// First device with the given name that is selectable in `scope` (nil = any).
func findDevice(named name: String, scope: AudioObjectPropertyScope?) -> AudioObjectID? {
    allDevices().first { deviceName($0) == name && (scope == nil || selectable($0, scope!)) }
}

// -- volume / mute / sample rate ---------------------------------------------

/// Volume 0..1, master element if present, else the average of the channel
/// elements. nil when the device exposes no volume control for the scope.
func volume(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Float? {
    let master = propAddr(kAudioDevicePropertyVolumeScalar, scope, kAudioObjectPropertyElementMain)
    if hasProp(d, master), let v: Float32 = getValue(d, master, 0) { return v }
    var vals: [Float] = []
    for ch in 1...max(channelCount(d, scope), 1) {
        let a = propAddr(kAudioDevicePropertyVolumeScalar, scope, AudioObjectPropertyElement(ch))
        if hasProp(d, a), let v: Float32 = getValue(d, a, 0) { vals.append(v) }
    }
    return vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
}

func setVolume(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope, _ value: Float) -> Bool {
    let vol = Float32(max(0, min(1, value)))
    let master = propAddr(kAudioDevicePropertyVolumeScalar, scope, kAudioObjectPropertyElementMain)
    if hasProp(d, master), isSettable(d, master) { return setValue(d, master, vol) }
    var ok = false
    for ch in 1...max(channelCount(d, scope), 1) {
        let a = propAddr(kAudioDevicePropertyVolumeScalar, scope, AudioObjectPropertyElement(ch))
        if hasProp(d, a), isSettable(d, a) { ok = setValue(d, a, vol) || ok }
    }
    return ok
}

func muted(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool? {
    let a = propAddr(kAudioDevicePropertyMute, scope, kAudioObjectPropertyElementMain)
    guard hasProp(d, a), let v: UInt32 = getValue(d, a, 0) else { return nil }
    return v != 0
}

func setMuted(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope, _ on: Bool) -> Bool {
    let a = propAddr(kAudioDevicePropertyMute, scope, kAudioObjectPropertyElementMain)
    guard hasProp(d, a), isSettable(d, a) else { return false }
    return setValue(d, a, UInt32(on ? 1 : 0))
}

func sampleRate(_ d: AudioObjectID) -> Double? {
    getValue(d, propAddr(kAudioDevicePropertyNominalSampleRate), Float64(0))  // Float64 == Double
}

func setSampleRate(_ d: AudioObjectID, _ hz: Double) -> Bool {
    setValue(d, propAddr(kAudioDevicePropertyNominalSampleRate), Float64(hz))
}

func availableSampleRates(_ d: AudioObjectID) -> [Double] {
    let ranges: [AudioValueRange] = getArray(
        d, propAddr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
    var out: [Double] = []
    for r in ranges {
        out.append(r.mMinimum)
        if r.mMaximum != r.mMinimum { out.append(r.mMaximum) }
    }
    return Array(Set(out)).sorted()
}

// -- output ------------------------------------------------------------------

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func fmtRate(_ hz: Double?) -> String { hz.map { String(format: "%.0f Hz", $0) } ?? "—" }
func fmtVol(_ v: Float?) -> String { v.map { String(format: "%d%%", Int(($0 * 100).rounded())) } ?? "—" }
func fmtMute(_ m: Bool?) -> String { m.map { $0 ? "on" : "off" } ?? "—" }

func deviceJSON(_ d: AudioObjectID) -> [String: Any] {
    [
        "name": deviceName(d),
        "uid": deviceUID(d),
        "transport": transportType(d),
        "out_channels": channelCount(d, OUT),
        "in_channels": channelCount(d, IN),
        "sample_rate": sampleRate(d) ?? 0,
        "available_sample_rates": availableSampleRates(d),
        "output_volume": volume(d, OUT).map { Double($0) as Any } ?? NSNull(),
        "input_volume": volume(d, IN).map { Double($0) as Any } ?? NSNull(),
        "output_muted": muted(d, OUT).map { $0 as Any } ?? NSNull(),
        "input_muted": muted(d, IN).map { $0 as Any } ?? NSNull(),
        "alive": isAlive(d),
        "running": isRunning(d),
        "is_default_output": d == defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
        "is_default_input": d == defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
        "is_default_system": d == defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice),
    ]
}

func printJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { die("json encode failed", 1) }
    print(s)
}

// -- commands ----------------------------------------------------------------

func cmdList(_ mode: String, json: Bool) {
    let defOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let defIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let devices = allDevices().filter { d in
        switch mode {
        case "out": return selectable(d, OUT)
        case "in": return selectable(d, IN)
        default: return selectable(d, OUT) || selectable(d, IN)
        }
    }
    if json {
        printJSON(devices.map(deviceJSON))
        return
    }
    for d in devices {
        let outSel = selectable(d, OUT), inSel = selectable(d, IN)
        let out = channelCount(d, OUT), inp = channelCount(d, IN)
        let dir = outSel && inSel ? "i/o" : outSel ? "out" : "in "
        let marker = (d == defOut && outSel) || (d == defIn && inSel) ? "*" : " "
        let ch = out > 0 && inp > 0 ? "\(out)o/\(inp)i" : "\(max(out, inp))ch"
        // pad the name to a column, but never truncate — the full name is what `set`/`info` need
        let nm = deviceName(d)
        let namePad = nm.count < 30 ? nm.padding(toLength: 30, withPad: " ", startingAt: 0) : nm + " "
        print("\(marker) [\(dir)] \(namePad) "
            + "\(transportType(d).padding(toLength: 11, withPad: " ", startingAt: 0)) "
            + "\(ch.padding(toLength: 7, withPad: " ", startingAt: 0)) \(fmtRate(sampleRate(d)))")
    }
}

func cmdInfo(_ name: String, json: Bool) {
    guard let d = findDevice(named: name, scope: nil) else { die("no device named \"\(name)\"", 1) }
    if json { printJSON(deviceJSON(d)); return }
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

/// Move the default device (for `selector`) one step through the devices that
/// have channels in `scope`, wrapping around. Returns the new device name.
@discardableResult
func cycleDefault(_ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope, forward: Bool) -> String? {
    let scoped = allDevices().filter { selectable($0, scope) }
    guard !scoped.isEmpty else { return nil }
    let n = scoped.count
    let target: AudioObjectID
    if let i = scoped.firstIndex(of: defaultDevice(selector)) {
        target = scoped[forward ? (i + 1) % n : (i - 1 + n) % n]
    } else {
        target = forward ? scoped[0] : scoped[n - 1]  // current default not in this scope → jump to an end
    }
    return setDefaultDevice(selector, target) ? deviceName(target) : nil
}

/// output/input/system default-device get/set/list.
func cmdDefault(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                label: String, args: [String], json: Bool) {
    let sub = args.first ?? "get"
    switch sub {
    case "get":
        let name = deviceName(defaultDevice(selector))
        if json { printJSON(["device": name]) } else { print(name) }
    case "list":
        cmdList(scope == IN ? "in" : "out", json: json)
    case "set":
        guard args.count > 1 else { die("usage: audioctl \(label) set \"<name>\"", 2) }
        guard let d = findDevice(named: args[1], scope: scope) else {
            die("no \(label) device named \"\(args[1])\"", 1)
        }
        if setDefaultDevice(selector, d) { print("\(label) -> \(deviceName(d))") }
        else { die("failed to set \(label) device", 1) }
    case "next", "prev":
        guard let name = cycleDefault(selector, scope, forward: sub == "next") else {
            die("no \(label) devices to cycle", 1)
        }
        print("\(label) -> \(name)")
    default:
        die("usage: audioctl \(label) [get | list | set \"<name>\" | next | prev]", 2)
    }
}

func resolveTarget(input: Bool, device: String?) -> (AudioObjectID, AudioObjectPropertyScope) {
    let scope = input ? IN : OUT
    if let name = device {
        guard let d = findDevice(named: name, scope: scope) else {
            die("no \(input ? "input" : "output") device named \"\(name)\"", 1)
        }
        return (d, scope)
    }
    let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    return (defaultDevice(sel), scope)
}

func cmdVolume(args: [String], input: Bool, device: String?, json: Bool) {
    let (d, scope) = resolveTarget(input: input, device: device)
    let sub = args.first ?? "get"
    switch sub {
    case "get":
        guard let v = volume(d, scope) else { die("\(device ?? deviceName(d)) has no volume control", 1) }
        if json { printJSON(["device": deviceName(d), "volume": Int((v * 100).rounded())]) }
        else { print(Int((v * 100).rounded())) }
    case "set":
        guard args.count > 1, let pct = Double(args[1]) else { die("usage: audioctl volume set <0-100>", 2) }
        guard setVolume(d, scope, Float(pct / 100.0)) else { die("\(deviceName(d)) volume is not settable", 1) }
        // echo what was actually applied (setVolume clamps to 0..1), read back from the device
        let applied = volume(d, scope).map { Int(($0 * 100).rounded()) } ?? Int(max(0, min(100, pct)))
        print("\(deviceName(d)) volume -> \(applied)%")
    default:
        die("usage: audioctl volume [get | set <0-100>] [--input] [--device \"<name>\"]", 2)
    }
}

func cmdMute(args: [String], input: Bool, device: String?, json: Bool) {
    let (d, scope) = resolveTarget(input: input, device: device)
    let sub = args.first ?? "get"
    switch sub {
    case "get":
        guard let m = muted(d, scope) else { die("\(deviceName(d)) has no mute control", 1) }
        if json { printJSON(["device": deviceName(d), "muted": m]) } else { print(m ? "on" : "off") }
    case "on", "off", "toggle":
        let want = sub == "toggle" ? !(muted(d, scope) ?? false) : sub == "on"
        if setMuted(d, scope, want) { print("\(deviceName(d)) mute -> \(want ? "on" : "off")") }
        else { die("\(deviceName(d)) mute is not settable", 1) }
    default:
        die("usage: audioctl mute [get | on | off | toggle] [--input] [--device \"<name>\"]", 2)
    }
}

func cmdSampleRate(args: [String], input: Bool, device: String?, json: Bool) {
    let (d, _) = resolveTarget(input: input, device: device)
    let sub = args.first ?? "get"
    switch sub {
    case "get":
        guard let hz = sampleRate(d) else { die("\(deviceName(d)) has no sample rate", 1) }
        if json { printJSON(["device": deviceName(d), "sample_rate": hz]) } else { print(Int(hz)) }
    case "list":
        let rates = availableSampleRates(d)
        if json { printJSON(["device": deviceName(d), "available_sample_rates": rates]) }
        else { rates.forEach { print(Int($0)) } }
    case "set":
        guard args.count > 1, let hz = Double(args[1]) else { die("usage: audioctl samplerate set <hz>", 2) }
        if setSampleRate(d, hz) { print("\(deviceName(d)) sample rate -> \(Int(hz)) Hz") }
        else { die("\(deviceName(d)) sample rate \(Int(hz)) not accepted (see samplerate list)", 1) }
    default:
        die("usage: audioctl samplerate [get | list | set <hz>] [--input] [--device \"<name>\"]", 2)
    }
}

// -- global hotkeys (Carbon RegisterEventHotKey; no TCC, no app bundle) -------
//
// Ctrl+Opt+, cycles the default output back, Ctrl+Opt+. forward. RegisterEventHotKey
// is a registered system hotkey, not an event tap, so it needs no Accessibility /
// Input-Monitoring permission. A faceless NSApplication (.accessory) pumps the
// event loop without a Dock icon or an .app bundle.

let HOTKEY_LABEL = "audioctl.hotkeys"

func hotkeyPlistPath() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/\(HOTKEY_LABEL).plist")
}

func binaryPath() -> String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

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

@discardableResult
func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func installHotkeys() {
    let path = hotkeyPlistPath()
    do {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try hotkeyPlist().write(toFile: path, atomically: true, encoding: .utf8)
    } catch { die("cannot write \(path): \(error)", 1) }
    let uid = getuid()
    launchctl(["bootout", "gui/\(uid)/\(HOTKEY_LABEL)"])  // ignore if not already loaded
    var st = launchctl(["bootstrap", "gui/\(uid)", path])
    if st != 0 {  // launchd tears the old job down asynchronously — let it settle, retry once
        usleep(300_000)
        st = launchctl(["bootstrap", "gui/\(uid)", path])
    }
    if st == 0 {
        print("hotkeys installed: \(path)")
        print("  Ctrl+Opt+, = output prev    Ctrl+Opt+. = output next")
    } else {
        die("wrote \(path), but launchctl bootstrap failed (\(st)). Load it with:\n"
            + "  launchctl bootstrap gui/\(uid) \(path)", 1)
    }
}

func uninstallHotkeys() {
    launchctl(["bootout", "gui/\(getuid())/\(HOTKEY_LABEL)"])
    let path = hotkeyPlistPath()
    try? FileManager.default.removeItem(atPath: path)
    print("hotkeys uninstalled (\(path) removed)")
}

func hotkeyStatus() {
    let loaded = launchctl(["print", "gui/\(getuid())/\(HOTKEY_LABEL)"]) == 0
    let onDisk = FileManager.default.fileExists(atPath: hotkeyPlistPath())
    print("launch agent: \(loaded ? "loaded" : "not loaded"), plist: \(onDisk ? "present" : "absent")")
}

func runHotkeys() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // faceless: no Dock icon, no .app bundle
    let mods = UInt32(controlKey | optionKey)
    let target = GetApplicationEventTarget()
    let sig = OSType(0x61637468)  // 'acth'
    var ref1: EventHotKeyRef?
    var ref2: EventHotKeyRef?
    let s1 = RegisterEventHotKey(UInt32(kVK_ANSI_Comma), mods, EventHotKeyID(signature: sig, id: 1), target, 0, &ref1)
    let s2 = RegisterEventHotKey(UInt32(kVK_ANSI_Period), mods, EventHotKeyID(signature: sig, id: 2), target, 0, &ref2)
    if s1 != noErr || s2 != noErr {
        // Note: RegisterEventHotKey usually still returns noErr when another app
        // already owns the combo — the keys then silently do nothing. So a clean
        // status is not proof the hotkeys work; see the README troubleshooting note.
        FileHandle.standardError.write(
            "warning: hotkey registration returned \(s1)/\(s2), expected 0\n".data(using: .utf8)!)
    }

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handler: EventHandlerUPP = { _, event, _ in
        guard let event = event else { return noErr }
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        if let name = cycleDefault(kAudioHardwarePropertyDefaultOutputDevice, OUT, forward: hk.id == 2) {
            print("output -> \(name)"); fflush(stdout)
        }
        return noErr
    }
    InstallEventHandler(target, handler, 1, &spec, nil, nil)
    print("audioctl hotkeys running — Ctrl+Opt+, = output prev · Ctrl+Opt+. = output next")
    fflush(stdout)
    app.run()
}

let USAGE = """
audioctl \(VERSION) — control macOS audio from the command line

  audioctl list [out|in|all]                 list devices (* = current default)
  audioctl info "<name>"                      full properties of one device
  audioctl output [get | list | set "<name>" | next | prev]  default output
  audioctl input  [get | list | set "<name>" | next | prev]  default input
  audioctl system [get | set "<name>"]        default system-sound output device
  audioctl volume [get | set <0-100>]         output volume (--input for input)
  audioctl mute   [get | on | off | toggle]   output mute   (--input for input)
  audioctl samplerate [get | list | set <hz>] device nominal sample rate
  audioctl hotkeys [install | uninstall | status | plist]
                     Ctrl+Opt+, / Ctrl+Opt+. cycle the output device;
                     `install` runs it as a login agent (no bare arg = run now)

Flags: --json machine-readable output · --input operate on the input scope
       --device "<name>" target a specific device (default: the current default)
"""

// -- entry -------------------------------------------------------------------

var raw = Array(CommandLine.arguments.dropFirst())
var json = false
var inputScope = false
var deviceOverride: String?
var positional: [String] = []
var idx = 0
while idx < raw.count {
    switch raw[idx] {
    case "--json": json = true
    case "--input", "-i": inputScope = true
    case "--device", "-d":
        idx += 1
        if idx < raw.count { deviceOverride = raw[idx] } else { die("--device needs a name", 2) }
    default: positional.append(raw[idx])
    }
    idx += 1
}

let command = positional.first ?? "list"
let rest = Array(positional.dropFirst())

switch command {
case "list": cmdList(rest.first ?? "all", json: json)
case "info":
    guard let name = rest.first else { die("usage: audioctl info \"<name>\"", 2) }
    cmdInfo(name, json: json)
case "output":
    cmdDefault(selector: kAudioHardwarePropertyDefaultOutputDevice, scope: OUT, label: "output", args: rest, json: json)
case "input":
    cmdDefault(selector: kAudioHardwarePropertyDefaultInputDevice, scope: IN, label: "input", args: rest, json: json)
case "system":
    cmdDefault(selector: kAudioHardwarePropertyDefaultSystemOutputDevice, scope: OUT, label: "system", args: rest, json: json)
case "volume", "vol": cmdVolume(args: rest, input: inputScope, device: deviceOverride, json: json)
case "mute": cmdMute(args: rest, input: inputScope, device: deviceOverride, json: json)
case "samplerate", "rate": cmdSampleRate(args: rest, input: inputScope, device: deviceOverride, json: json)
case "hotkeys":
    switch rest.first {
    case "install": installHotkeys()
    case "uninstall": uninstallHotkeys()
    case "status": hotkeyStatus()
    case "plist": print(hotkeyPlist())
    case nil, "run": runHotkeys()
    default: die("usage: audioctl hotkeys [install | uninstall | status | plist]", 2)
    }
case "help", "-h", "--help": print(USAGE)
case "version", "--version": print("audioctl \(VERSION)")
default:
    die("unknown command \"\(command)\"\n\n\(USAGE)", 2)
}
