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
    private var previewTask: Task<Void, Never>?
    /// Hands-free: Space was tapped while the chord was held, so the release is ignored and the next press finishes.
    private var locked = false
    /// The last recording, kept so an error can offer "Try again".
    private var lastSamples: [Float] = []
    static let commandNote = Notification.Name("co.wildinteractive.speakhold.command")

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockPolicy()
        buildMainMenu()
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
        overlay.model.onRetry = { [weak self] in self?.retryLast() }
        DistributedNotificationCenter.default().addObserver(forName: Self.commandNote, object: nil, queue: .main) { [weak self] n in
            self?.handleCommand(n.object as? String ?? "")
        }
        if CommandLine.arguments.contains("--demo-overlay") { demoOverlay() }
    }

    // MARK: remote control (CLI flags, speakhold:// URLs)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleCommand(url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    }

    private func handleCommand(_ cmd: String) {
        switch cmd {
        case "toggle": isRecording ? finishRecording() : beginRecording()
        case "start": beginRecording()
        case "stop", "finish": finishRecording()
        case "cancel": cancelRecording()
        case "settings": openSettings()
        case "history": openHistory()
        default: NSLog("Speakhold: unknown command %@", cmd)
        }
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
            if tick == 90 { self.overlay.show(.done("Can you check the sync before standup?")) }
            if tick == 130 { self.overlay.hide(); t.invalidate() }
        }
    }

    // MARK: Dock + main menu

    /// Dock icon on or off at runtime; the bundle is LSUIElement so nothing flashes in the Dock before this runs.
    private func applyDockPolicy() {
        let want: NSApplication.ActivationPolicy = Settings.shared.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// Clicking the Dock icon with no window open opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openSettings() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: isRecording ? "Stop dictation" : "Start dictation", action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "")
        return menu
    }

    /// A real main menu so ⌘, ⌘Q and the Edit shortcuts (⌘V into the API-key field) work while a window is key.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Speakhold", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        app.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Speakhold", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Quit Speakhold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
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
            settingsWindow = AppDelegate.inkWindow(title: "Speakhold Settings", root: SettingsView(status: status))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A window in the pill's language: ink background, dark controls, the title bar dissolved into the content so
    /// the sidebar runs under the traffic lights. Shared by Settings and History.
    static func inkWindow<V: View>(title: String, root: V, resizable: Bool = false) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let w = NSWindow(contentRect: .zero, styleMask: mask, backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Ink.bg)
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    @objc private func openHistory() {
        if historyWindow == nil {
            historyWindow = AppDelegate.inkWindow(title: "Dictation History", root: HistoryView(), resizable: true)
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
            if self.locked { self.finishRecording(); return }   // hands-free: the next press finishes
            switch Settings.shared.mode {
            case .hold:
                self.pressedAt = Date()
                if !self.isRecording { self.beginRecording() }
            case .toggle:
                self.isRecording ? self.finishRecording() : self.beginRecording()
            }
        }
        hotkeys.onLock = { [weak self] in
            guard let self, self.isRecording, Settings.shared.mode == .hold, !self.locked else { return false }
            self.locked = true
            self.overlay.model.locked = true
            return true
        }
        hotkeys.onRelease = { [weak self] in
            guard let self, Settings.shared.mode == .hold, self.isRecording, !self.locked else { return }
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

    /// UserDefaults.didChangeNotification is posted synchronously from inside a Settings setter, i.e. while that
    /// property's exclusive write access is still open. Touching the overlay here would make SwiftUI lay out the
    /// pill (which reads Settings) inside that access and abort with "simultaneous accesses" — the 20 Oct crash.
    /// So everything is deferred to the next run-loop turn.
    private func applySettings() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyDockPolicy()
            if self.hotkeys.combo != Settings.shared.hotkey {
                self.hotkeys.combo = Settings.shared.hotkey
            }
            if !self.isRecording, !self.busy { self.overlay.relayout(); self.overlay.hide() }   // apply idle-pill / position settings immediately
            Task { await self.loadModel() }
        }
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
            locked = false
            overlay.model.locked = false
            overlay.model.onUndo = nil
            overlay.model.canRetry = false
            recorder.inputDeviceUID = Settings.shared.inputDeviceUID
            do {
                try recorder.start()
            } catch {
                overlay.show(.error(error.localizedDescription)); hideSoon(3); return
            }
            isRecording = true
            setIcon(recording: true)
            overlay.model.resetLevels()
            overlay.model.liveText = ""
            overlay.show(.listening)
            if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
            if Settings.shared.livePreview { startLivePreview() }
        }
    }

    /// Willow-style live transcript: every ~0.8 s re-run the decoder over everything captured so far and show the
    /// result in the pill. Runs through the same actor as the final pass, so the two never overlap; the final
    /// pass simply queues behind an in-flight tick.
    /// 15 s of 16 kHz audio: enough context for Whisper to be right about the last sentence, small enough to decode in well under the 0.8 s tick.
    private static let previewWindowSamples = 16_000 * 15

    private func startLivePreview() {
        previewTask?.cancel()
        let s = Settings.shared
        previewTask = Task { [weak self] in
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, !Task.isCancelled else { return }
                let all = self.recorder.snapshot()
                // Need a second of audio, and at least half a second of new audio since the last tick.
                guard all.count >= 16_000, all.count - lastCount >= 8_000 else { continue }
                lastCount = all.count
                // The preview only ever shows the tail of a long dictation (the bar keeps the newest words), so
                // decode just the last `previewWindow` seconds: the cost per tick stays flat however long you talk.
                // The final transcript after release still uses the whole recording.
                let window = Self.previewWindowSamples
                let samples = all.count > window ? Array(all.suffix(window)) : all
                guard let text = try? await self.transcriber.transcribe(samples, language: s.language, promptTerms: s.dictionaryTerms, fast: true),
                      !Task.isCancelled, !text.isEmpty else { continue }
                let shown = all.count > window ? "… " + text : text
                await MainActor.run { if self.isRecording { self.overlay.model.liveText = shown } }
            }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        previewTask?.cancel(); previewTask = nil
        _ = recorder.stop()
        isRecording = false
        locked = false
        setIcon(recording: false)
        overlay.hide()
    }

    private func finishRecording() {
        guard isRecording else { return }
        previewTask?.cancel(); previewTask = nil
        let samples = recorder.stop()
        isRecording = false
        locked = false
        setIcon(recording: false)
        if Settings.shared.playSounds { NSSound(named: "Pop")?.play() }

        // Under half a second of audio is a mis-press.
        guard samples.count > 8_000 else { overlay.hide(); return }
        lastSamples = samples
        process(samples)
    }

    /// "Try again" on the error pill: run the same recording through the pipeline again.
    private func retryLast() {
        guard !busy, !isRecording, !lastSamples.isEmpty else { return }
        process(lastSamples)
    }

    /// Transcribe → polish → paste. The pill shows each step; the result keeps an Undo for a few seconds.
    private func process(_ samples: [Float]) {
        busy = true
        overlay.model.canRetry = false
        overlay.show(.transcribing)
        let s = Settings.shared
        let app = targetApp
        Task {
            defer { Task { @MainActor in self.busy = false } }
            do {
                let raw = try await transcriber.transcribe(samples, language: s.language, promptTerms: s.dictionaryTerms)
                guard !raw.isEmpty else {
                    await MainActor.run { overlay.model.canRetry = true; overlay.show(.error("Didn't catch anything.")); hideSoon(4) }
                    return
                }
                if Polish.willUseModel(s) { await MainActor.run { overlay.show(.cleaning) } }
                let text = await Polish.run(raw, settings: s, appName: app)
                await MainActor.run {
                    Paster.paste(text)
                    History.shared.add(text, app: app)
                    overlay.model.onUndo = { [weak self] in self?.undoLast() }
                    overlay.show(.done(text))
                    hideSoon(3)
                }
            } catch {
                await MainActor.run { overlay.model.canRetry = true; overlay.show(.error(error.localizedDescription)); hideSoon(4) }
            }
        }
    }

    /// Undo on the pill: ⌘Z to the app we pasted into (we never took focus, so it is still frontmost).
    private func undoLast() {
        overlay.model.onUndo = nil
        Paster.undo()
        overlay.hide()
    }

    private func hideSoon(_ seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.isRecording else { return }
            self.overlay.hide()
        }
    }
}
