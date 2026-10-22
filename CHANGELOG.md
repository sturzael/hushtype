# Changelog

## Unreleased

- **Meetings, the full set.** Your own notes during the call (a meeting window; the transcript expands them afterwards), **Mark this moment** (menu, window, or a single tap of the dictation chord), **Catch me up** (the last two minutes as text), title and invitees from the Calendar event happening now, the other voices told apart on-device (**Speaker 1, 2, 3**), an optional **follow-up email draft**, a **Save notes to** folder, **Parakeet** as a faster transcription engine for long meetings (optional, ~600 MB), and an **offer to record** when any app starts using the microphone. Audio streams to a temp file during the call, so length is no longer limited by memory, and is deleted once the notes are written. Settings → Meetings.
- **Record meeting** (menu bar, Dock menu, `Speakhold --meeting`): records both sides of a call on this Mac, the microphone and whatever the Mac is playing (Core Audio process tap, macOS 14.2+, no BlackHole), shows a red dot with the elapsed time in the pill, and on stop transcribes both streams on the Neural Engine, merges them by time as you / Them, writes notes (Claude if a key is set, otherwise Apple Intelligence) and saves one markdown file to `~/Documents/Speakhold Meetings/`, then opens it. Audio is discarded. First use asks for "System Audio Recording Only".
- **Polish on this Mac with Apple Intelligence** (macOS 26, Apple silicon): the default polish engine is now Apple's on-device model, so filler removal and punctuation need no API key and nothing leaves the machine. Claude stays as the opt-in engine under Settings → Cleanup → "Polish with". A length guard keeps the raw transcript if a model answers instead of editing.
- Spoken commands ("new paragraph", "new line", "full stop", "comma", "question mark", "exclamation mark") are applied deterministically before any model, so they work with polish off too.
- **Undo** on the pill for three seconds after a paste (sends ⌘Z to the app you dictated into). **Try again** on the error pill re-runs the last recording.
- **Hands-free lock:** while holding the chord, tap Space; let go and keep talking. Press the chord again to finish, Esc to cancel. The pill shows a lock while locked.
- **Text replacements** (Settings → Cleanup): one per line, `spoken -> written`, whole phrase, any case.
- **Remote control:** `Speakhold --toggle | --start | --stop | --cancel | --settings | --history` talks to the running copy, as does `open speakhold://toggle`. For SketchyBar, Raycast, Shortcuts and scripts.
- `--polish "text"` headless flag runs the polish pipeline on a string.
- Settings and History windows redrawn in the bar's ink/mint language: sidebar, hairline cards, mint toggles, the shortcut as a chip, a waveform level meter, and a live miniature of the pill that follows your position / idle-tab / live-words choices.
- App icon redrawn to match (ink squircle, mint waveform). `swift scripts/make-icon.swift` regenerates it.
- Speakhold now keeps an icon in the Dock by default: click it to open Settings, right-click for Start dictation / Settings / History. Turn it off under Settings → General → App → "Show in the Dock" for menu-bar only.
- A real main menu, so ⌘V works in the API-key field and ⌘, / ⌘W / ⌘Q work while a window is open.
- Headless `--render-settings dir` renders each settings tab to PNG for layout checks.

## 0.1.2 — 2026-10-21

- New look for the bar: navy-slate ink, hairline border, mint waveform and status colours (mint / amber / red); idle is a small vertical lozenge docked to the right screen edge just above centre (new default position).
- Live transcript in the pill while you hold the key (Willow-style): words appear as you speak, newest words stay visible. Toggle under Settings → General → "Show words in the pill while you speak".
- Idle state is a small tab that hugs the screen edge; the pill floats just above it while active.
- Fixed a crash when changing the pill position / idle-tab settings while the overlay was on screen (Swift exclusivity abort inside SwiftUI layout).

## 0.1.0 — 2026-10-20

First public release.

- Push-to-talk dictation with on-device WhisperKit (Large v3 Turbo default)
- Chord hotkeys with left/right-specific modifiers, optional F-key, hold or toggle
- Willow-style floating pill with live waveform, Esc to cancel
- Pastes into the frontmost app and restores your clipboard
- Optional Claude cleanup pass with personal dictionary and style notes
- History window, launch at login, menu-bar only
