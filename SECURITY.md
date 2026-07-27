# Security Policy

## Supported versions

Only the latest release on `main` is supported. Fixes go into a new release
rather than being backported.

## Reporting a vulnerability

Please report privately via GitHub's
[security advisory form](https://github.com/bmmmm/audioctl/security/advisories/new)
rather than opening a public issue. Include what an attacker gains and the steps
to reproduce.

Expect an initial response within about a week. A confirmed issue is fixed and
released *before* the details are described publicly.

## What this tool touches

Worth knowing when judging impact:

- **No elevated privileges.** `audioctl` runs as your user and never asks for
  root. Installation copies a binary onto your `PATH` — nothing else.
- **No TCC permission.** It only changes audio *routing and output*, which macOS
  does not gate. It never captures audio, so it never needs microphone access.
- **Writes two files, both in your home directory:**
  `~/.config/audioctl/hotkeys.json` (bindings) and
  `~/Library/LaunchAgents/audioctl.hotkeys.plist` (the login agent, only after you
  run `hotkeys install`). The plist records the absolute path of the binary it was
  installed from — if that path is writable by another user, they control what the
  agent runs at login. Install to a location only you can write.
- **Executes exactly one external program:** `/bin/launchctl`, with a fixed
  argument list, to load, unload and restart the agent. No shell is involved, so
  device names and key names are never interpreted as commands.
- **No network access, no telemetry, no dependencies.**

Global hotkeys use Carbon `RegisterEventHotKey`, which receives only the specific
registered combinations — it is not a keylogger and cannot observe other keystrokes.
