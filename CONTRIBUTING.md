# Contributing to Hushtype

Thanks for looking. Hushtype is small on purpose; please keep it that way.

## Setup

```bash
git clone https://github.com/sturzael/hushtype.git && cd hushtype
swift build            # debug build in .build/debug/Hushtype
./build.sh             # release .app → ~/Applications/Hushtype.app
```

Open `Package.swift` in Xcode if you prefer an IDE. There is no Xcode project to keep in sync.

## Layout

```
Sources/Hushtype/
  main.swift          entry point + headless check modes
  App.swift           AppDelegate: menu bar, recording flow, windows
  HotkeyMonitor.swift CGEvent tap; chord matching with left/right-specific modifier bits
  AudioRecorder.swift AVAudioEngine → 16 kHz mono Float32
  Transcriber.swift   WhisperKit wrapper (download, load, transcribe)
  Cleanup.swift       optional Claude Messages API polish pass (raw HTTP)
  Paster.swift        pasteboard + synthetic ⌘V, clipboard restore
  Overlay.swift       floating pill: NSPanel + SwiftUI waveform
  SettingsView.swift  settings + history windows
  Settings.swift      UserDefaults-backed preferences
  History.swift       last 200 transcripts in ~/Library/Application Support/Hushtype
Resources/            Info.plist, AppIcon.icns
build.sh              bundle + sign + install
```

## Headless checks

No test target yet, but every subsystem can be exercised without clicking:

```bash
.build/release/Hushtype --test-hotkey                 # synthetic chord events → expects press/release
.build/release/Hushtype --transcribe clip.aiff        # downloads model if needed, prints RAW (and CLEAN if a key is set)
say -o clip.aiff "testing one two three"              # quick way to make a clip
.build/release/Hushtype --render-overlay /tmp/pills   # PNG of each pill state
.build/release/Hushtype --render-gif docs/demo.gif    # README animation
DICTATE_DEBUG=1 … --transcribe …                      # logs sample counts and segments
```

## Signing

`build.sh` signs ad-hoc unless `HUSHTYPE_SIGN_IDENTITY` is set. Ad-hoc signatures change every build, so macOS drops the Accessibility grant each rebuild. Any trusted identity (Developer ID, or a self-signed code-signing cert you trust in Keychain Access) fixes that.

## Roadmap / good first issues

- Notarized builds + Homebrew cask
- Parakeet (FluidAudio) as an alternative engine
- Per-app style presets (casual in Slack, formal in Mail)
- Streaming partial transcripts in the pill
- Cloud transcription fallback (Deepgram / Groq) for long dictations
- Localised UI

## Style

Swift 5 language mode, no third-party UI dependencies, no analytics. Keep the pill fast: nothing on the main thread that takes longer than a frame.
