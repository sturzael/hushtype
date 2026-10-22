# Spikes

Throwaway experiments that are not part of the app build.

- `meetingtap.swift`: records system audio (Core Audio process tap, macOS 14.2+) and the microphone to two 16 kHz WAVs, to test whether a meetings mode can capture both sides of a call without a virtual audio driver. Needs the "System Audio Recording Only" and microphone permissions, which macOS only prompts for when you run it from your own terminal:

  ```bash
  swiftc -O spikes/meetingtap.swift -o /tmp/meetingtap && /tmp/meetingtap 10 /tmp/meetingtap-out
  ```

  Play something (a call, a video) while it runs; it prints the peak level of each stream and writes `system.wav` and `mic.wav`. Transcribe either with `Speakhold --transcribe /tmp/meetingtap-out/system.wav --no-cleanup`.
