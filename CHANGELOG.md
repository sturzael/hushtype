# Changelog

## Unreleased

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
