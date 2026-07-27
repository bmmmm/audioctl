// SPDX-License-Identifier: GPL-3.0-or-later
// Human- and machine-readable rendering.

import CoreAudio
import Foundation

extension String {
    /// Pad to a column width, but never truncate — the full device name is what
    /// `set` / `info` need to be given back.
    func padded(_ width: Int) -> String {
        count < width ? padding(toLength: width, withPad: " ", startingAt: 0) : self + " "
    }
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

func printJSON(_ obj: Any) throws {
    guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else {
        throw CLIError.runtime("json encode failed")
    }
    print(s)
}
