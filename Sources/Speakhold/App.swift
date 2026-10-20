import AppKit
import AVFoundation
import SwiftUI

final class AppStatus: ObservableObject {
    @Published var modelStatus = "Not loaded"
    @Published var micOK = false
    @Published var axOK = false
    @Published var micTest = ""
    @Published var micLevel: Float = 0
    var runMicTest: (() -> Void)?
    /// Settings sets this while the user is recording a new shortcut so the global hotkey does not fire.
    var suspendHotkey: ((Bool) -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayPanel()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkeys = HotkeyMonitor()
    private let status = AppStatus()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var isRecording = false
    private var busy = false
    private var targetApp: String?
    private var pressedAt: Date?
    private var lastLevelPush = Date.distantPast
    private var settingsObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        wireRecorder()
        wireHotkeys()
        Task { await self.loadModel() }
        overlay.hide()   // shows the idle pill if enabled
        refreshPermissions()
        status.runMicTest = { [weak self] in self?.micTest() }
        status.suspendHotkey = { [weak self] on in self?.hotkeys.suspended = on }
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        if CommandLine.arguments.contains("--demo-overlay") { demoOverlay() }
    }

    /// Shows the pill through its states with a fake waveform, for screenshots and layout checks.
    private func demoOverlay() {
        overlay.show(.listening)
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            tick += 1
            self.overlay.model.push(level: Float.random(in: 0.1...1.0))
            if tick == 60 { self.overlay.show(.transcribing) }
            if tick == 90 { self.overlay.show(.done("Hey Smriti, can you check the Pinnacle HubSpot sync before standup?")) }
            if tick == 130 { self.overlay.hide(); t.invalidate() }
        }
    }

    // MARK: menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.addItem(withTitle: "Start dictation", action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Speakhold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Speakhold")
        img?.isTemplate = !recording
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    @objc private func toggleFromMenu() { isRecording ? finishRecording() : beginRecording() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Speakhold Settings"
            w.contentView = NSHostingView(rootView: SettingsView(status: status))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openHistory() {
        if historyWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Dictation History"
            w.contentView = NSHostingView(rootView: HistoryView())
            w.isReleasedWhenClosed = false
            w.center()
            historyWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: setup

    private func wireRecorder() {
        recorder.levelHandler = { [weak self] level in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastLevelPush) > 0.045 else { return }
            self.lastLevelPush = now
            DispatchQueue.main.async { self.overlay.model.push(level: level) }
        }
    }

    private func wireHotkeys() {
        hotkeys.combo = Settings.shared.hotkey
        hotkeys.onPress = { [weak self] in
            guard let self else { return }
            switch Settings.shared.mode {
            case .hold:
                self.pressedAt = Date()
                if !self.isRecording { self.beginRecording() }
            case .toggle:
                self.isRecording ? self.finishRecording() : self.beginRecording()
            }
        }
        hotkeys.onRelease = { [weak self] in
            guard let self, Settings.shared.mode == .hold, self.isRecording else { return }
            // A very quick tap is almost always accidental; drop it.
            if let t = self.pressedAt, Date().timeIntervalSince(t) < 0.25 { self.cancelRecording(); return }
            self.finishRecording()
        }
        hotkeys.onEscape = { [weak self] in
            guard let self, self.isRecording else { return false }
            self.cancelRecording()
            return true
        }
        if !hotkeys.start() {
            Paster.promptAccessibility()
            // Retry until Accessibility is granted.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                if self.hotkeys.start() { t.invalidate() }
            }
        }
    }

    private func applySettings() {
        if hotkeys.combo != Settings.shared.hotkey {
            hotkeys.combo = Settings.shared.hotkey
        }
        if !isRecording, !busy { overlay.relayout(); overlay.hide() }   // apply the idle-pill / position settings immediately
        Task { await self.loadModel() }
    }

    private func loadModel() async {
        let model = Settings.shared.model.rawValue
        await transcriber.setStateHandler { [weak self] s in
            DispatchQueue.main.async {
                switch s {
                case .idle: self?.status.modelStatus = "Not loaded"
                case .downloading(let p): self?.status.modelStatus = p < 0.01 ? "Checking model…" : "Downloading \(Int(p * 100))%"
                case .loading: self?.status.modelStatus = "Loading into memory…"
                case .ready: self?.status.modelStatus = "Ready"; self?.overlay.model.ready = true
                case .failed(let e): self?.status.modelStatus = "Failed: \(e)"
                }
            }
        }
        await transcriber.prepare(model: model)
    }

    /// Settings → "Test microphone": records 3 s from the chosen device, shows the level and the raw transcript.
    private func micTest() {
        guard !isRecording, !busy else { return }
        Task { @MainActor in
            guard await AudioRecorder.requestPermission() else { status.micTest = "Microphone permission is off."; return }
            recorder.inputDeviceUID = Settings.shared.inputDeviceUID
            var peak: Float = 0
            let previous = recorder.levelHandler
            recorder.levelHandler = { [weak self] l in
                peak = max(peak, l)
                DispatchQueue.main.async { self?.status.micLevel = l }
            }
            defer { recorder.levelHandler = previous }
            do { try recorder.start() } catch { status.micTest = error.localizedDescription; return }
            busy = true
            status.micTest = "Recording 3 seconds… say something."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let samples = recorder.stop()
            status.micLevel = 0
            if peak < 0.08 {
                status.micTest = "Heard almost nothing (peak level \(Int(peak * 100))%). Wrong device, or it is muted."
                busy = false; return
            }
            status.micTest = "Peak level \(Int(peak * 100))%. Transcribing…"
            do {
                let text = try await transcriber.transcribe(samples, language: Settings.shared.language, promptTerms: Settings.shared.dictionaryTerms)
                status.micTest = text.isEmpty ? "Peak level \(Int(peak * 100))%, but no words recognised." : "Heard: “\(text)”"
            } catch { status.micTest = error.localizedDescription }
            busy = false
        }
    }

    private func refreshPermissions() {
        status.axOK = Paster.accessibilityTrusted
        status.micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: recording flow

    private func beginRecording() {
        guard !busy, !isRecording else { return }
        Task { @MainActor in
            guard await AudioRecorder.requestPermission() else {
                overlay.show(.error("Microphone access is off. Grant it in System Settings → Privacy → Microphone."))
                Paster.openMicrophonePane()
                hideSoon(3)
                return
            }
            if await transcriber.state != .ready {
                overlay.show(.error("Speech model is still loading (\(status.modelStatus)). Try again in a moment."))
                hideSoon(2.5)
                return
            }
            targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            recorder.inputDeviceUID = Settings.shared.inputDeviceUID
            do {
                try recorder.start()
            } catch {
                overlay.show(.error(error.localizedDescription)); hideSoon(3); return
            }
            isRecording = true
            setIcon(recording: true)
            overlay.model.resetLevels()
            overlay.show(.listening)
            if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        _ = recorder.stop()
        isRecording = false
        setIcon(recording: false)
        overlay.hide()
    }

    private func finishRecording() {
        guard isRecording else { return }
        let samples = recorder.stop()
        isRecording = false
        setIcon(recording: false)
        if Settings.shared.playSounds { NSSound(named: "Pop")?.play() }

        // Under half a second of audio is a mis-press.
        guard samples.count > 8_000 else { overlay.hide(); return }
        busy = true
        overlay.show(.transcribing)
        let s = Settings.shared
        let app = targetApp
        Task {
            defer { Task { @MainActor in self.busy = false } }
            do {
                let raw = try await transcriber.transcribe(samples, language: s.language, promptTerms: s.dictionaryTerms)
                guard !raw.isEmpty else {
                    await MainActor.run { overlay.show(.error("Didn't catch anything.")); hideSoon(1.5) }
                    return
                }
                let text: String
                if s.cleanupEnabled, !s.anthropicKey.isEmpty {
                    await MainActor.run { overlay.show(.cleaning) }
                    text = await Cleanup(apiKey: s.anthropicKey, model: s.cleanupModel)
                        .clean(raw, dictionary: s.dictionaryTerms, style: s.styleNotes, appName: app)
                } else {
                    text = raw
                }
                await MainActor.run {
                    Paster.paste(text)
                    History.shared.add(text, app: app)
                    overlay.show(.done(text))
                    hideSoon(1.4)
                }
            } catch {
                await MainActor.run { overlay.show(.error(error.localizedDescription)); hideSoon(3) }
            }
        }
    }

    private func hideSoon(_ seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.isRecording else { return }
            self.overlay.hide()
        }
    }
}
