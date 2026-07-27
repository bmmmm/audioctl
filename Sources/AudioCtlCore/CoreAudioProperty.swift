// SPDX-License-Identifier: GPL-3.0-or-later
// Generic typed access to CoreAudio's property bag.

import CoreAudio
import Foundation

let OUT = kAudioObjectPropertyScopeOutput
let IN = kAudioObjectPropertyScopeInput
let sys = AudioObjectID(kAudioObjectSystemObject)

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
