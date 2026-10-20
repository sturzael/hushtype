# Changelog

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
