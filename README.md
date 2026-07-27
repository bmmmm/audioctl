# audioctl

[![CI](https://github.com/bmmmm/audioctl/actions/workflows/ci.yml/badge.svg)](https://github.com/bmmmm/audioctl/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform: macOS 12+](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey)

Control macOS audio from the command line — switch the default output / input /
system device, read and set volume, mute and sample rate, and **bind global
hotkeys** to any of it. One dependency-free native binary.

```sh
audioctl status                             # what is set right now, in one shot
audioctl output next                        # cycle to the next output device
audioctl output set "External Headphones"   # or pick one by name, substring or UID
audioctl volume set 40                      # 40 % output volume
audioctl mute toggle                        # mute the current output
audioctl hotkeys bind "ctrl+opt+m" input-mute-toggle   # a mic-mute key macOS lacks
audioctl list --json                        # machine-readable
```

The listing is sorted, aligned for eyes and greppable for scripts (`* ` marks the
current default for each direction):

```console
$ audioctl list
  [i/o] BlackHole 2ch                  virtual     2o/2i   48000 Hz
  [out] External Headphones            usb         2ch     48000 Hz
* [in ] MacBook Pro Microphone         builtin     1ch     48000 Hz
* [out] MacBook Pro Speakers           builtin     2ch     48000 Hz
```

## Why

macOS has no built-in CLI for the default audio device, and the hotkey to *cycle*
output devices — jump between speakers, headphones and a virtual device without
opening System Settings — is something the desktop just doesn't offer.
[`switchaudio-osx`](https://github.com/deweller/switchaudio-osx) covers device
switching well; `audioctl` adds volume / mute / sample-rate control and bindable
global hotkeys, in a single native binary with **no dependencies, no `.app`
bundle, and no TCC permission** — audio *output* control is not permission-gated
(only capturing microphone input would be, which this never does).

## Install

Requires the Swift toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/bmmmm/audioctl && cd audioctl
swift build -c release
cp .build/release/audioctl /usr/local/bin/    # or ~/.local/bin, anywhere on PATH
```

## Usage

```
audioctl status                             what is in effect right now
audioctl list [out|in|all]                  list devices (* = current default)
audioctl info "<name|uid>"                  full properties of one device
audioctl output [get | list | set "<name|uid>" | next | prev]  default output
audioctl input  [get | list | set "<name|uid>" | next | prev]  default input
audioctl system [get | list | set "<name|uid>" | next | prev]  system sounds
audioctl volume [get | set <0-100>]         output volume (--input for input)
audioctl mute   [get | on | off | toggle]   output mute   (--input for input)
audioctl samplerate [get | list | set <hz>] device nominal sample rate
audioctl hotkeys …                          see "Global hotkeys" below
```

Flags: `--json` machine-readable output · `--input` operate on the input scope ·
`--device "<name|uid>"` target a device (`volume` / `mute` / `samplerate`).
Anything after `--` is taken as a value, not a flag.

Every mutating command prints the new state; errors go to stderr with a non-zero
exit (`1` runtime, `2` usage). An unknown flag, or `--input` / `--device` on a
command that has no use for them, is rejected rather than ignored. `--json` works
on every read — `status`, `list`, `info`, `hotkeys status`, and the `get` and
`list` subcommands.

### Naming a device

A device can be given as its **UID**, its **exact name**, or a **unique
case-insensitive substring** — in that order:

```sh
audioctl output set "External Headphones"   # exact name
audioctl output set headphones              # substring, if unambiguous
audioctl output set BlackHole2ch_UID        # UID, always unique
```

Two devices can share a name — a pair of identical USB interfaces does. Rather
than silently picking one, `audioctl` reports both with the UID that tells them
apart:

```console
$ audioctl output set "Scarlett 2i2"
"Scarlett 2i2" matches 2 devices — repeat with one of these UIDs:
  Scarlett 2i2             AppleUSBAudioEngine:Focusrite:Scarlett 2i2:1
  Scarlett 2i2             AppleUSBAudioEngine:Focusrite:Scarlett 2i2:2
```

## What is currently set

`audioctl status` answers "what is active right now" in one shot — the three
default devices with their volume, mute and sample rate, plus the hotkey bindings
and the state of the launch agent behind them:

```console
$ audioctl status
audioctl 0.2.0

output:    MacBook Pro Speakers
           builtin · 48000 Hz · volume 69% · mute off
input:     MacBook Pro Microphone
           builtin · 48000 Hz · volume 27% · mute off
system:    BlackHole 2ch

hotkeys
  bindings:  Ctrl+Opt+,     previous output device
             Ctrl+Opt+.     next output device
  config:    ~/.config/audioctl/hotkeys.json (absent — using defaults)
  agent:     loaded (pid 75451)
  plist:     ~/Library/LaunchAgents/audioctl.hotkeys.plist
```

`audioctl hotkeys status` prints just the hotkey block. Both flag a **stale
agent** — one whose plist points at a binary that has since moved — which is
otherwise invisible: launchd keeps reporting the job as loaded while the hotkeys
are dead.

## Global hotkeys

Out of the box `Ctrl+Opt+,` and `Ctrl+Opt+.` cycle the default output device
backward and forward, so you can flip between speakers, headphones and a virtual
device without touching the mouse. Bindings are yours to change:

```sh
audioctl hotkeys actions                            # what can be bound
audioctl hotkeys bind "ctrl+opt+m" input-mute-toggle
audioctl hotkeys bind "ctrl+shift+up" volume-up
audioctl hotkeys unbind "ctrl+opt+,"
audioctl hotkeys reset                              # back to the defaults
```

| action | does |
|---|---|
| `output-next` / `output-prev` | cycle the default output device |
| `input-next` / `input-prev` | cycle the default input device |
| `mute-toggle` | toggle output mute |
| `input-mute-toggle` | toggle microphone mute — macOS has no key for this |
| `volume-up` / `volume-down` | output volume in 5 % steps |

Combos are written `modifier+…+key`, e.g. `ctrl+opt+m`. Modifiers are `ctrl`,
`opt` (`alt`), `shift` and `cmd`; at least one is required, since a bare key would
swallow that key system-wide. `audioctl hotkeys keys` lists every accepted key
name. Bindings live in `~/.config/audioctl/hotkeys.json` (honouring
`XDG_CONFIG_HOME`) and may be edited by hand — a malformed file is reported as an
error rather than silently falling back to the defaults: `hotkeys status` names
the problem and exits `1`, `status` keeps showing the audio state alongside it,
and `hotkeys reset` restores the defaults.

Run them as a per-user launch agent:

```sh
audioctl hotkeys install     # writes the launch agent (pointing at this binary) and loads it
audioctl hotkeys status      # bindings, agent state, config path
audioctl hotkeys uninstall   # unload + remove
audioctl hotkeys plist       # print the generated plist without installing
```

Run `install` from the binary's final location (e.g. after copying it to
`/usr/local/bin`) — the launch agent records that exact path, so moving the binary
later breaks the agent; `status` flags exactly this. Changing a binding restarts a
running agent automatically. Foreground use without the agent: `audioctl hotkeys`
blocks and listens in the current terminal (it warns if the agent is also running,
since both would react to every press).

The hotkeys use Carbon `RegisterEventHotKey` — a registered system hotkey, not an
event tap — so macOS asks for no Accessibility or Input-Monitoring permission.

**If the keys do nothing:** another app already owns the combo.
`RegisterEventHotKey` does not report this — it returns success and the OS simply
routes the combo to the other app. Free the shortcut there, or bind a different
one. The agent also only receives hotkeys inside a normal GUI login session, not
over SSH.

## Limitations

**Individual AirPlay 2 endpoints (Sonos, HomePod, …) are not selectable.** macOS
keeps AirPlay endpoint routing in Control Center, outside CoreAudio. While an
AirPlay device is the *active* output a single generic `AirPlay` device appears in
CoreAudio — `audioctl` lists and cycles it like any other — but *which* speaker it
targets is chosen in Control Center, and when idle there is no AirPlay device at
all, so you can't switch onto it from the command line. This is a macOS-level
limitation shared by `switchaudio-osx` and Audio MIDI Setup, not specific to
`audioctl`: the "AirPlay" proxy device exposes no data sources
(`kAudioDevicePropertyDataSources` → `kAudioHardwareUnknownPropertyError`).

## Development

```sh
swift build -c release -Xswiftc -warnings-as-errors
swift test
```

The logic lives in the `AudioCtlCore` library — argument parsing, hotkey combo
parsing and config handling are pure functions covered by unit tests; the
`audioctl` executable is only the entry point. CI additionally runs the binary and
asserts that bad input exits `2` instead of being acted on.

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
For security issues see [SECURITY.md](SECURITY.md).

## Support

If this is useful to you, you can support it at [ko-fi.com/bmabma](https://ko-fi.com/bmabma).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
