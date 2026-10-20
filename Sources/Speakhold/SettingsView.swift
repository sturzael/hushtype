import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var status: AppStatus
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var inputs = AudioDevices.inputs()
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "keyboard") }
            cleanup.tabItem { Label("Cleanup", systemImage: "sparkles") }
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 680)
        .onAppear { inputs = AudioDevices.inputs() }
        .padding()
    }

    var general: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Shortcut").foregroundStyle(.secondary)
                    Spacer()
                    Text(recorder.isRecording ? (recorder.held.isEmpty ? "Press your keys…" : recorder.previewLabel) : settings.hotkey.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(recorder.isRecording ? Color.accentColor : (settings.hotkey.isValid ? Color.primary : Color.red))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(recorder.isRecording ? 0.18 : 0.08)))
                    Button(recorder.isRecording ? "Cancel" : "Record…") {
                        if recorder.isRecording { recorder.stop(); status.suspendHotkey?(false) }
                        else { status.suspendHotkey?(true); recorder.start { combo in settings.hotkey = combo; status.suspendHotkey?(false) } }
                    }
                }
                Text("Click Record, then hold the keys you want (e.g. Control + Option) and let go. Left and right keys are told apart. Add an F-key by pressing it while holding the modifiers.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Behaviour", selection: $settings.mode) {
                    ForEach(HotkeyMode.allCases) { Text($0.label).tag($0) }
                }
                DisclosureGroup("Fine-tune individual keys") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        ForEach(ModKey.allCases) { m in
                            Toggle(m.label, isOn: Binding(
                                get: { settings.hotkey.mods.contains(m) },
                                set: { on in var c = settings.hotkey; if on { c.mods.insert(m) } else { c.mods.remove(m) }; settings.hotkey = c }
                            ))
                        }
                    }
                    Picker("Plus key", selection: Binding(
                        get: { settings.hotkey.key },
                        set: { k in var c = settings.hotkey; c.key = k; settings.hotkey = c }
                    )) {
                        ForEach(PlainKey.allCases) { Text($0.label).tag($0) }
                    }
                }
                if settings.hotkey.mods.contains(.fn) {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” = Do Nothing, or macOS will open emoji/dictation too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Microphone") {
                Picker("Input device", selection: $settings.inputDeviceUID) {
                    Text("System default (\(AudioDevices.defaultInputName()))").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                }
                HStack {
                    Button("Test microphone (3 s)") { status.runMicTest?() }
                    Spacer()
                    ProgressView(value: Double(status.micLevel)).frame(width: 140)
                }
                if !status.micTest.isEmpty {
                    Text(status.micTest).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("Speech model (runs on this Mac)") {
                Picker("Model", selection: $settings.model) {
                    ForEach(WhisperModel.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("Status").foregroundStyle(.secondary)
                    Spacer()
                    Text(status.modelStatus)
                }
                TextField("Language code (blank = auto-detect)", text: $settings.language)
            }
            Section {
                Toggle("Always show the small pill at the bottom of the screen", isOn: $settings.showIdlePill)
                Toggle("Play sounds on start / stop", isOn: $settings.playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { NSLog("launch at login: %@", error.localizedDescription) }
                    }
            }
        }
        .formStyle(.grouped)
    }

    var cleanup: some View {
        Form {
            Section {
                Toggle("Polish transcript with Claude", isOn: $settings.cleanupEnabled)
                Text("Removes fillers and fixes punctuation. Falls back to the raw transcript if the request fails.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Model", text: $settings.cleanupModel)
                SecureField("Anthropic API key (or set ANTHROPIC_API_KEY)", text: $settings.anthropicKey)
            }
            Section("Dictionary — names and terms to spell exactly (one per line)") {
                TextEditor(text: $settings.dictionary).font(.system(.body, design: .monospaced)).frame(minHeight: 110)
            }
            Section("Style notes (optional)") {
                TextEditor(text: $settings.styleNotes).frame(minHeight: 70)
            }
        }
        .formStyle(.grouped)
    }

    var permissions: some View {
        Form {
            Section {
                row("Microphone", ok: status.micOK) {
                    Task { if await AudioRecorder.requestPermission() == false { Paster.openMicrophonePane() } }
                }
                row("Accessibility (hotkey + paste)", ok: status.axOK) {
                    Paster.promptAccessibility(); Paster.openAccessibilityPane()
                }
                Text("After granting Accessibility, quit and relaunch Speakhold if the hotkey does not respond.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func row(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            if !ok { Button("Grant…", action: action) }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var history = History.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.items.isEmpty {
                Text("Nothing dictated yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            if let app = item.app { Text("· \(app)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        }
                        Text(item.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack { Spacer(); Button("Clear history") { history.clear() } }.padding(8)
        }
        .frame(width: 520, height: 420)
    }
}


/// Captures a chord from the keyboard while the Settings window is key: hold modifiers (left/right-aware),
/// optionally press an F-key, release everything to finish. Esc cancels.
final class ShortcutRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var held: Set<ModKey> = []
    private var key: PlainKey = .none
    private var monitor: Any?
    private var onDone: ((HotkeyCombo) -> Void)?

    var previewLabel: String { HotkeyCombo(mods: held, key: key).label }

    func start(_ done: @escaping (HotkeyCombo) -> Void) {
        onDone = done; held = []; key = .none; isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] ev in
            self?.handle(ev); return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; isRecording = false; held = []; key = .none; onDone = nil
    }

    private func handle(_ ev: NSEvent) {
        let raw = ev.cgEvent?.flags.rawValue ?? UInt64(ev.modifierFlags.rawValue)
        let now = Set(ModKey.allCases.filter { raw & $0.deviceMask != 0 })
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stop(); return }                     // Esc cancels
            if let k = PlainKey.from(keyCode: ev.keyCode) { key = k; finish(); return }
            return                                                      // other keys are not supported as the trigger
        }
        held.formUnion(now)
        if now.isEmpty, !held.isEmpty { finish() }                      // everything released → done
    }

    private func finish() {
        let combo = HotkeyCombo(mods: held, key: key)
        let done = onDone
        stop()
        if combo.isValid { done?(combo) }
    }
}
