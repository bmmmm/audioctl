// SPDX-License-Identifier: GPL-3.0-or-later
// Argument parsing and dispatch. The parser is a pure function over the argument
// vector so it can be tested without touching CoreAudio or launchd.

import CoreAudio
import Foundation

let VERSION = "0.2.0"

enum CLIError: Error, Equatable {
    case usage(String)   // exit 2 — the invocation was wrong
    case runtime(String) // exit 1 — the invocation was fine, the system said no
    case silent(Int32)   // exit code only; the reason was already printed in context

    var message: String {
        switch self {
        case .usage(let m), .runtime(let m): return m
        case .silent: return ""
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .runtime: return 1
        case .silent(let code): return code
        }
    }
}

struct ParsedCommand: Equatable {
    var command = "status"
    var args: [String] = []
    var json = false
    var input = false
    var device: String?
}

/// Commands that act on a specific device scope. Passing `--input` / `--device`
/// to anything else is rejected rather than silently ignored — a flag that looks
/// like it retargets the command but doesn't is how you mute the wrong device.
let SCOPED_COMMANDS: Set<String> = ["volume", "vol", "mute", "samplerate", "rate"]

func parseArguments(_ argv: [String]) throws -> ParsedCommand {
    var parsed = ParsedCommand()
    var positional: [String] = []
    var passthrough = false
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        if passthrough || arg == "-" || !arg.hasPrefix("-") {
            positional.append(arg)
            i += 1
            continue
        }
        switch arg {
        case "--": passthrough = true
        case "--json": parsed.json = true
        case "--input", "-i": parsed.input = true
        case "--device", "-d":
            i += 1
            guard i < argv.count else { throw CLIError.usage("--device needs a name or UID") }
            parsed.device = argv[i]
        case "--help", "-h": return finish(&parsed, ["help"])
        case "--version": return finish(&parsed, ["version"])
        default:
            throw CLIError.usage("unknown flag \"\(arg)\"\n"
                + "  known flags: --json, --input/-i, --device/-d <name|uid>\n"
                + "  to pass it as a value, put it after --")
        }
        i += 1
    }
    return finish(&parsed, positional)
}

private func finish(_ parsed: inout ParsedCommand, _ positional: [String]) -> ParsedCommand {
    parsed.command = positional.first ?? "status"
    parsed.args = Array(positional.dropFirst())
    return parsed
}

func validateScopeFlags(_ p: ParsedCommand) throws {
    guard !SCOPED_COMMANDS.contains(p.command) else { return }
    if p.device != nil {
        let hint = ["info", "output", "input", "system"].contains(p.command)
            ? "pass the device as an argument: audioctl \(p.command) … \"<name|uid>\""
            : "it applies to volume, mute and samplerate only"
        throw CLIError.usage("--device does not apply to `\(p.command)` — \(hint)")
    }
    if p.input {
        throw CLIError.usage("--input does not apply to `\(p.command)` — "
            + "use `audioctl input …` for the input device")
    }
}

let HOTKEY_USAGE = """
usage: audioctl hotkeys [run | install | uninstall | status | plist
                         | bind "<keys>" <action> | unbind "<keys>" | reset
                         | actions | keys]
"""

let USAGE = """
audioctl \(VERSION) — control macOS audio from the command line

  audioctl status                             what is in effect right now
  audioctl list [out|in|all]                  list devices (* = current default)
  audioctl info "<name|uid>"                  full properties of one device
  audioctl output [get | list | set "<name|uid>" | next | prev]  default output
  audioctl input  [get | list | set "<name|uid>" | next | prev]  default input
  audioctl system [get | list | set "<name|uid>" | next | prev]  system sounds
  audioctl volume [get | set <0-100>]         output volume (--input for input)
  audioctl mute   [get | on | off | toggle]   output mute   (--input for input)
  audioctl samplerate [get | list | set <hz>] device nominal sample rate

  audioctl hotkeys status                     bindings + launch agent state
  audioctl hotkeys bind "<keys>" <action>     e.g. "ctrl+opt+m" mute-toggle
  audioctl hotkeys unbind "<keys>" | reset    remove one / restore defaults
  audioctl hotkeys actions | keys             what can be bound, and to what
  audioctl hotkeys install | uninstall        run the bindings as a login agent
  audioctl hotkeys                            run them in this terminal

Devices are matched by UID, then exact name, then unique substring; an ambiguous
name is reported with the UIDs to disambiguate it.

Flags: --json machine-readable output · --input operate on the input scope
       --device "<name|uid>" target a device (volume / mute / samplerate)
"""

public enum AudioCtl {
    /// Run one invocation. Returns the process exit code.
    public static func run(_ argv: [String]) -> Int32 {
        do {
            let p = try parseArguments(argv)
            try validateScopeFlags(p)
            try dispatch(p)
            return 0
        } catch let e as CLIError {
            if !e.message.isEmpty {
                FileHandle.standardError.write((e.message + "\n").data(using: .utf8)!)
            }
            return e.exitCode
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            return 1
        }
    }
}

func dispatch(_ p: ParsedCommand) throws {
    switch p.command {
    case "status": try cmdStatus(json: p.json)
    case "list": try cmdList(p.args.first ?? "all", json: p.json)
    case "info":
        guard let ref = p.args.first else { throw CLIError.usage("usage: audioctl info \"<name|uid>\"") }
        try cmdInfo(ref, json: p.json)
    case "output":
        try cmdDefault(selector: kAudioHardwarePropertyDefaultOutputDevice, scope: OUT,
                       label: "output", args: p.args, json: p.json)
    case "input":
        try cmdDefault(selector: kAudioHardwarePropertyDefaultInputDevice, scope: IN,
                       label: "input", args: p.args, json: p.json)
    case "system":
        try cmdDefault(selector: kAudioHardwarePropertyDefaultSystemOutputDevice, scope: OUT,
                       label: "system", args: p.args, json: p.json)
    case "volume", "vol": try cmdVolume(args: p.args, input: p.input, device: p.device, json: p.json)
    case "mute": try cmdMute(args: p.args, input: p.input, device: p.device, json: p.json)
    case "samplerate", "rate":
        try cmdSampleRate(args: p.args, input: p.input, device: p.device, json: p.json)
    case "hotkeys": try cmdHotkeys(args: p.args, json: p.json)
    case "help": print(USAGE)
    case "version": print("audioctl \(VERSION)")
    default:
        throw CLIError.usage("unknown command \"\(p.command)\"\n\n\(USAGE)")
    }
}
