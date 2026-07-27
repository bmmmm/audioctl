# Contributing

Thanks for taking a look. `audioctl` is a small, deliberately dependency-free
tool — the bar for new dependencies is high, the bar for a good bug report is low.

## Reporting a bug

Audio hardware is where this tool meets reality, and reality varies. What makes a
report immediately actionable:

- the output of `audioctl status` and `audioctl list --json`
- the exact command you ran, what you expected, and what happened
- your macOS version and Mac model
- for a device-specific problem, `audioctl info "<name>" --json` for that device

If a device behaves oddly (no volume control, a rate that won't apply, a name that
matches nothing), the `--json` dump of that device is usually enough to see why.

## Building and testing

```sh
swift build -c release -Xswiftc -warnings-as-errors
swift test
```

The code is split so that it can be tested:

- `Sources/AudioCtlCore/` — everything. Argument parsing (`CLI.swift`), hotkey
  combos and config (`Hotkey.swift`), device resolution (`Device.swift`) and the
  control primitives (`Controls.swift`) are the parts under test.
- `Sources/audioctl/main.swift` — the process entry point, nothing else.

Anything that talks to CoreAudio or launchd can't be unit-tested without hardware,
so keep the decision-making in a pure function and let the thin wrapper call it.
That is why `parsePercent`, `KeyCombo.parse` and `expandSampleRateRanges` exist as
separate functions rather than inline.

## Pull requests

- Add a test for anything with a pure-logic component. If a bug got through, the
  test that would have caught it belongs in the same PR.
- Keep the build warning-free; CI runs with `-warnings-as-errors`.
- Every error message should tell the user what to do next — `audioctl` treats a
  dead end as a bug.
- Match the surrounding style: comments explain *why*, not *what*.

## Scope

In scope: anything CoreAudio exposes about devices, volume, mute, rates and
routing, plus the hotkey layer.

Out of scope: capturing or processing audio (that would drag in a TCC microphone
permission, which this tool deliberately never needs), and per-application volume
(macOS does not expose it).

By contributing you agree that your contribution is licensed under GPL-3.0-or-later.
