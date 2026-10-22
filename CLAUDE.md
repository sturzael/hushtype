# Speakhold — notes for agents

Native Swift menu-bar app: hold-to-talk dictation (WhisperKit on the Neural Engine) and meeting recording with notes. Public, MIT; keep client and staff names out of code, demo strings and docs.

## Build and run
- `swift build -c release` for a quick compile; `./build.sh` makes `dist/Speakhold.app`, signs it (self-signed "Speakhold Dev", stable designated requirement so TCC grants persist) and installs to `~/Applications`. Relaunch with `pkill -x Speakhold; open -a Speakhold`. Never relaunch while the user is on a call (`Speakhold --calls` lists apps using the mic).
- Anything that touches the microphone, system audio or the screen must run as the signed bundle (`open -n -a Speakhold --args …`): a bare binary or a `!` command from an agent session gets silence, not an error, because TCC never prompts it.
- Settings observers: defer with `DispatchQueue.main.async` (publishing during a view update crashes).

## Headless checks (no permissions needed)
- `--polish "text"` runs the polish pipeline and prints the result and engine.
- `--meeting-from-files me.wav them.wav [--marks] [--notes "…"] [--diarise] [--parakeet]` runs the whole meeting pipeline on two 16 kHz clips and prints the markdown; delete the file it writes to the notes folder afterwards.
- `--notes-from-transcript file.md` rewrites a saved meeting's Notes section with the engine configured now.
- `--render-settings dir` renders each Settings tab to PNG; `--demo-overlay` cycles the pill. `screencapture` is TCC-blocked here.
- End-to-end dictation (hold, speak, paste) and real calls can only be verified by the user; say so rather than claiming it.

## Where things are
- `Overlay.swift` the pill and its states; `SettingsView.swift` the ink design kit and tabs; `Cleanup.swift` polish engines (Apple Foundation Models guided generation, Claude); `Meeting*.swift` capture (Core Audio process tap + mic), session, notes, Parakeet/diarisation (FluidAudio); `App.swift` menu bar, hotkeys, meeting lifecycle and the background notes job; `main.swift` headless flags.
- Apple Foundation Models holds far less than its nominal 4k tokens of real text (about 400 plain words per call with a brief and an answer): strip markup, map-reduce, watch for condense passes that stop shrinking. Guided generation (`@Generable`) stops the prefacing and refusals that plain `respond(to:)` produces.
- Release: bump `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`, tag, GitHub release zip, update the Homebrew cask SHA in `sturzael/homebrew-tap`. The landing page is `docs/index.html` (GitHub Pages from `main:/docs`).
