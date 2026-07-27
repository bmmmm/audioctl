// SPDX-License-Identifier: GPL-3.0-or-later
// The device model: enumeration, identity, and resolving a user-supplied
// reference (UID, exact name, or unique substring) to one device.

import CoreAudio
import Foundation

func allDevices() -> [AudioObjectID] {
    getArray(sys, propAddr(kAudioHardwarePropertyDevices), AudioObjectID(0))
}

/// Devices in a stable order. The HAL returns them in discovery order, which
/// changes as devices come and go — that would make `next`/`prev` cycle through
/// a different sequence after every reconnect. Sorted by name, UID as tiebreak
/// so identically named devices keep a fixed relative order.
func sortedDevices() -> [AudioObjectID] {
    allDevices().sorted { a, b in
        let (na, nb) = (deviceName(a), deviceName(b))
        if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
        return deviceUID(a) < deviceUID(b)
    }
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

// -- resolving a device reference --------------------------------------------

/// How a device reference matched, in decreasing order of precedence.
enum MatchKind { case uid, exactName, substring }

/// Resolve a user-supplied reference to exactly one device. Tries the UID first
/// (the only truly unique key — two identical USB interfaces share a name), then
/// an exact name, then a unique case-insensitive substring.
///
/// Ambiguity is an error, never a silent pick: reporting the candidates with their
/// UIDs is what makes two same-named devices addressable at all.
func resolveDevice(_ ref: String, scope: AudioObjectPropertyScope?) throws -> AudioObjectID {
    let candidates = allDevices().filter { scope == nil || selectable($0, scope!) }
    let scopeLabel = scope == nil ? "" : (scope == IN ? "input " : "output ")

    for kind in [MatchKind.uid, .exactName, .substring] {
        let hits = candidates.filter { match($0, ref, kind) }
        guard !hits.isEmpty else { continue }
        if hits.count == 1 { return hits[0] }
        // List the UIDs plainly — the caller may want them as an argument
        // (`output set`) or after --device (`volume`), so don't presume either.
        let list = hits.map { "  \(deviceName($0).padded(24)) \(deviceUID($0))" }.joined(separator: "\n")
        throw CLIError.runtime(
            "\"\(ref)\" matches \(hits.count) devices — repeat with one of these UIDs:\n\(list)")
    }
    throw CLIError.runtime("no \(scopeLabel)device matching \"\(ref)\" (see: audioctl list)")
}

private func match(_ d: AudioObjectID, _ ref: String, _ kind: MatchKind) -> Bool {
    switch kind {
    case .uid: return deviceUID(d) == ref
    case .exactName: return deviceName(d) == ref
    case .substring: return deviceName(d).localizedCaseInsensitiveContains(ref)
    }
}

/// Move the default device (for `selector`) one step through the devices
/// selectable in `scope`, wrapping around. Returns the new device name.
@discardableResult
func cycleDefault(_ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope, forward: Bool) -> String? {
    let scoped = sortedDevices().filter { selectable($0, scope) }
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
