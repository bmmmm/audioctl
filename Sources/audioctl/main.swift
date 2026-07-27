// SPDX-License-Identifier: GPL-3.0-or-later
// audioctl — control macOS audio from the command line via CoreAudio.
//
// A dependency-free native CLI: switch the default output / input / system
// device, read and set volume and mute, read and set the sample rate, bind
// global hotkeys, and dump full device info — with `--json` for scripting.
// No brew, no .app bundle, no TCC permission (audio *routing* and output control
// are not permission-gated; only capturing microphone input would be, which this
// tool never does).
//
// Everything lives in the AudioCtlCore library so it can be unit-tested; this
// file is only the process entry point.

import AudioCtlCore
import Foundation

exit(AudioCtl.run(Array(CommandLine.arguments.dropFirst())))
