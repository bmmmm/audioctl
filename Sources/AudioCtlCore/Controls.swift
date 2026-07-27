// SPDX-License-Identifier: GPL-3.0-or-later
// Volume, mute and sample rate for one device scope.

import CoreAudio
import Foundation

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
    let vol = Float32(clampVolume(Double(value)))
    let master = propAddr(kAudioDevicePropertyVolumeScalar, scope, kAudioObjectPropertyElementMain)
    if hasProp(d, master), isSettable(d, master) { return setValue(d, master, vol) }
    var ok = false
    for ch in 1...max(channelCount(d, scope), 1) {
        let a = propAddr(kAudioDevicePropertyVolumeScalar, scope, AudioObjectPropertyElement(ch))
        if hasProp(d, a), isSettable(d, a) { ok = setValue(d, a, vol) || ok }
    }
    return ok
}

/// Clamp to 0..1, mapping a non-finite input to 0 rather than to full volume.
/// `min(1, .nan)` returns 1 in Swift, so a plain clamp turns a NaN — e.g. from a
/// shell expression that failed — into an unexpected blast at 100 %.
func clampVolume(_ v: Double) -> Double {
    guard v.isFinite else { return 0 }
    return max(0, min(1, v))
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
    guard hz.isFinite, hz > 0 else { return false }
    return setValue(d, propAddr(kAudioDevicePropertyNominalSampleRate), Float64(hz))
}

func availableSampleRates(_ d: AudioObjectID) -> [Double] {
    expandSampleRateRanges(
        getArray(d, propAddr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange()))
}

/// Flatten the HAL's rate ranges to a sorted, deduplicated list of endpoints.
/// Most devices report each supported rate as a degenerate min == max range;
/// a true continuous range contributes its two endpoints.
func expandSampleRateRanges(_ ranges: [AudioValueRange]) -> [Double] {
    var out: [Double] = []
    for r in ranges {
        out.append(r.mMinimum)
        if r.mMaximum != r.mMinimum { out.append(r.mMaximum) }
    }
    return Array(Set(out)).sorted()
}
