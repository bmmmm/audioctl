# audioctl

[![CI](https://github.com/bmmmm/audioctl/actions/workflows/ci.yml/badge.svg)](https://github.com/bmmmm/audioctl/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform: macOS 12+](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey)

Control macOS audio from the command line — switch the default output / input /
system device, read and set volume, mute and sample rate, and **cycle the output
device with a global hotkey**. One dependency-free native binary.

```sh
audioctl output next                        # cycle to the next output device
audioctl output set "External Headphones"   # or pick one by name
audioctl volume set 40                      # 40 % output volume
audioctl mute toggle                        # mute the current output
audioctl output set "BlackHole 2ch"         # route system audio to a virtual device
audioctl list --json                        # machine-readable
```

The listing is aligned for eyes and greppable for scripts (`* ` marks the current
default for each direction):

```console
$ audioctl list
* [out] MacBook Pro Speakers       builtin     2ch     48000 Hz
  [out] External Headphones        usb         2ch     48000 Hz
  [out] LG UltraFine Display       hdmi        2ch     48000 Hz
* [in ] MacBook Pro Microphone     builtin     1ch     48000 Hz
```

## Why

macOS has no built-in CLI for the default audio device, and the hotkey to *cycle*
output devices — jump between speakers, headphones and a virtual device without
opening System Settings — is something the desktop just doesn't offer.
[`switchaudio-osx`](https://github.com/deweller/switchaudio-osx) covers device
switching well; `audioctl` adds volume / mute / sample-rate control and the
built-in global hotkey cycler, in a single native binary with **no dependencies,
no `.app` bundle, and no TCC permission** — audio *output* control is not
permission-gated (only capturing microphone input would be, which this never does).

## Install

Requires the Swift toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/bmmmm/audioctl && cd audioctl
swift build -c release
cp .build/release/audioctl /usr/local/bin/    # or ~/.local/bin, anywhere on PATH
```

## Usage

```
audioctl list [out|in|all]                    list devices (* = current default)
audioctl info "<name>"                         full properties of one device
audioctl output [get | list | set "<name>" | next | prev]
audioctl input  [get | list | set "<name>" | next | prev]
audioctl system [get | set "<name>"]           default system-sound output device
audioctl volume [get | set <0-100>]            output volume (--input for input)
audioctl mute   [get | on | off | toggle]      output mute   (--input for input)
audioctl samplerate [get | list | set <hz>]    device nominal sample rate
audioctl hotkeys [install | uninstall | status | plist]
```

Flags: `--json` machine-readable output · `--input` operate on the input scope ·
`--device "<name>"` target a specific device instead of the current default.

Every mutating command prints the new state; errors go to stderr with a non-zero
exit (`1` runtime, `2` usage). `--json` is available on `list`, `info`, and the
`get` reads for scripting.

## Global hotkey: cycle the output device

`Ctrl+Opt+,` cycles the default output device backward, `Ctrl+Opt+.` forward — so
you can flip between speakers, headphones and a virtual device without touching
the mouse. It runs as a per-user launch agent:

```sh
audioctl hotkeys install     # writes the launch agent (pointing at this binary) and loads it
audioctl hotkeys status      # loaded? plist present?
audioctl hotkeys uninstall   # unload + remove
audioctl hotkeys plist       # print the generated plist without installing
```

Run `install` from the binary's final location (e.g. after copying it to
`/usr/local/bin`) — the launch agent records that exact path, so moving or
deleting the binary later breaks the agent (just re-run `install`). The hotkeys
use Carbon `RegisterEventHotKey` (a registered system hotkey, not an event tap),
so macOS asks for no Accessibility or Input-Monitoring permission. Foreground use
without the agent: `audioctl hotkeys` blocks and listens in the current terminal.

**If the keys do nothing:** another app already owns `Ctrl+Opt+,` / `Ctrl+Opt+.`.
`RegisterEventHotKey` does not report this — it returns success and the OS simply
routes the combo to the other app. Free the shortcut there, or rebind (edit the
key codes in `runHotkeys`). The agent also only receives hotkeys inside a normal
GUI login session, not over SSH.

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

## Support

If this is useful to you, you can support it at [ko-fi.com/bmabma](https://ko-fi.com/bmabma).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
