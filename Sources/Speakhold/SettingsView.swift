import SwiftUI
import ServiceManagement

// MARK: - Ink design kit for windows
// The pill in Overlay.swift owns the palette (`Ink`). Everything the settings window draws is built from the same
// six colours, the same 14 pt radius and the same morph curve, so the window reads as the pill's bigger sibling.

extension Ink {
    /// Cards sit one step lighter than the window; wells (the pill preview, the chord chip) one step darker.
    static let card = Color.white.opacity(0.045)
    static let well = Color.black.opacity(0.24)
    static let field = Color.white.opacity(0.06)
    /// Text on a mint fill.
    static let onMint = Color(red: 0.07, green: 0.10, blue: 0.09)
    static let radius: CGFloat = 14
    static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev build"
    }()
}

/// The idle-tab glyph from the pill, reused as the app mark.
struct SpeakholdGlyph: View {
    var lit = true
    var scale: CGFloat = 1
    var body: some View {
        HStack(alignment: .center, spacing: 2.5 * scale) {
            ForEach([6, 12, 8], id: \.self) { h in
                RoundedRectangle(cornerRadius: 1.25 * scale)
                    .fill(lit ? Ink.mint : Ink.muted)
                    .frame(width: 2.5 * scale, height: CGFloat(h) * scale)
            }
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1) }
}

/// A titled group of rows. Rows are separated by hairlines, like the pill's border.
struct InkCard<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(Ink.muted)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).fill(Ink.card))
                .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Ink.muted).lineSpacing(2).padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Label on the left, control on the right. `hint` sits under the label in muted text.
struct InkRow<Control: View>: View {
    var label: String
    var hint: String? = nil
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            if divider { Hairline() }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 13)).foregroundStyle(Ink.text)
                    if let hint { Text(hint).font(.system(size: 11.5)).foregroundStyle(Ink.muted).lineSpacing(2) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                control.fixedSize()
            }
            .padding(.vertical, 11)
        }
    }
}

/// A full-width row (text editors, notes) with no trailing control.
struct InkBlock<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if divider { Hairline() }
            content.padding(.vertical, 12)
        }
    }
}

/// Switch in the pill's language: a mint capsule when on, a hairline well when off. System switches go grey in
/// an inactive window and ignore the tint in places; this one never does.
struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Ink.mint : Ink.field)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Ink.line, lineWidth: 1))
                Circle().fill(configuration.isOn ? Ink.onMint : Ink.muted)
                    .frame(width: 14, height: 14)
                    .padding(3)
            }
            .frame(width: 38, height: 20)
            .animation(Ink.morph, value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct InkButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(primary ? Ink.onMint : Ink.text)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Capsule().fill(primary ? Ink.mint : Ink.field))
            .overlay(Capsule().strokeBorder(primary ? Color.clear : Ink.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Text field in a hairline box, matching the chord chip.
struct InkField: View {
    var placeholder: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 260
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(Ink.text)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
    }
}

struct InkEditor: View {
    @Binding var text: String
    var mono = false
    var minHeight: CGFloat = 90
    var body: some View {
        TextEditor(text: $text)
            .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
            .foregroundStyle(Ink.text)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
    }
}

/// Mint status chip: a dot and a word, the pill's "done" tick in miniature.
struct StatusChip: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Ink.well))
        .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
    }
}

/// The microphone meter, drawn with the pill's waveform bars.
struct LevelMeter: View {
    var level: Float
    var bars = 22
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                let lit = Float(i) / Float(bars) < level
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? Ink.mint : Ink.muted.opacity(0.35))
                    .frame(width: 2.5, height: lit ? 14 : 6)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

// MARK: - Live pill preview
// Drives an OverlayModel through idle → listening → transcribing → done so the settings window shows the real
// pill, honouring the position / idle-tab / live-words choices as they change.

@MainActor final class PillPreview: ObservableObject {
    let model = OverlayModel()
    private var timer: Timer?
    private var t: Double = 0
    private let sample = "Can you check the sync before standup?"
    private let step = 0.08

    func start() {
        stop(); model.ready = true; t = 0
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        t += step
        let s = Settings.shared
        let cycle = t.truncatingRemainder(dividingBy: 8.4)
        let words = sample.split(separator: " ")
        var phase: OverlayModel.Phase
        var text = ""
        switch cycle {
        case ..<1.6:
            phase = s.showIdlePill ? .idle : .hidden
        case ..<5.0:
            phase = .listening
            let n = min(words.count, Int((cycle - 1.6) / 3.4 * Double(words.count + 1)))
            text = s.livePreview ? words.prefix(n).joined(separator: " ") : ""
            model.push(level: Float.random(in: 0.12...1))
        case ..<6.0:
            phase = .transcribing
            text = s.livePreview ? words.dropLast().joined(separator: " ") : ""
        default:
            phase = .done(sample)
        }
        if model.phase != phase { withAnimation(Ink.morph) { model.phase = phase } }
        if model.liveText != text { model.liveText = text }
    }
}

// MARK: - Settings window

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, cleanup, permissions
    var id: String { rawValue }
    var title: String {
        switch self { case .general: return "General"; case .cleanup: return "Cleanup"; case .permissions: return "Permissions" }
    }
    var icon: String {
        switch self { case .general: return "keyboard"; case .cleanup: return "sparkles"; case .permissions: return "lock.shield" }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var status: AppStatus
    @State private var tab: SettingsTab
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var inputs = AudioDevices.inputs()
    @State private var fineTune = false
    @StateObject private var recorder = ShortcutRecorder()
    @StateObject private var preview = PillPreview()

    static let size = CGSize(width: 760, height: 700)

    /// `scrolls: false` lays the tab out at full height (used by `--render-settings`, whose offscreen capture
    /// cannot draw an NSScrollView's document view).
    private let scrolls: Bool

    init(status: AppStatus, tab: SettingsTab = .general, scrolls: Bool = true) {
        self.status = status
        self.scrolls = scrolls
        _tab = State(initialValue: tab)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch tab {
            case .general: general
            case .cleanup: cleanup
            case .permissions: permissions
            }
        }
        .padding(.horizontal, 26).padding(.top, 44).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(tab)
        .transition(.opacity)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 176)
            Rectangle().fill(Ink.line).frame(width: 1)
            if scrolls {
                ScrollView { column }.animation(Ink.morph, value: tab)
            } else {
                column
            }
        }
        .frame(width: Self.size.width, height: scrolls ? Self.size.height : nil)
        .background(Ink.bg)
        .tint(Ink.mint)
        .preferredColorScheme(.dark)
        .onAppear { inputs = AudioDevices.inputs(); preview.start() }
        .onDisappear { preview.stop() }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SpeakholdGlyph(lit: status.modelStatus == "Ready", scale: 1.15)
                    .frame(width: 18, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speakhold").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(Ink.version).font(.system(size: 10.5)).foregroundStyle(Ink.muted)
                }
            }
            .padding(.leading, 18).padding(.top, 46).padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { t in
                    Button { tab = t } label: {
                        HStack(spacing: 9) {
                            Image(systemName: t.icon).font(.system(size: 12, weight: .semibold)).frame(width: 16)
                            Text(t.title).font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(tab == t ? Ink.mint : Ink.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tab == t ? Ink.mint.opacity(0.13) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text(settings.mode == .hold ? "HOLD TO TALK" : "PRESS TO TALK")
                    .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Ink.muted)
                Text(settings.hotkey.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(settings.hotkey.isValid ? Ink.mint : Ink.red)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: general

    private var general: some View {
        Group {
            InkCard(title: "Your pill") {
                InkBlock(divider: false) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).fill(Ink.well)
                        OverlayView(model: preview.model)
                    }
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                }
                InkRow(label: "Position") {
                    Picker("", selection: $settings.pillPosition) {
                        ForEach(PillPosition.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 230)
                }
                InkRow(label: "Keep a small tab on screen while idle") {
                    Toggle("", isOn: $settings.showIdlePill).toggleStyle(InkToggleStyle()).labelsHidden()
                }
                InkRow(label: "Show words in the pill while you speak") {
                    Toggle("", isOn: $settings.livePreview).toggleStyle(InkToggleStyle()).labelsHidden()
                }
            }

            InkCard(title: "Hotkey", note: "Click Record, hold the keys you want (e.g. Control + Option) and let go. Left and right keys are told apart. Add an F-key by pressing it while the modifiers are held.") {
                InkRow(label: "Shortcut", divider: false) {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            if recorder.isRecording { ThinkingDots(color: Ink.mint) }
                            Text(recorder.isRecording ? (recorder.held.isEmpty ? "Press your keys…" : recorder.previewLabel) : settings.hotkey.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(recorder.isRecording ? Ink.mint : (settings.hotkey.isValid ? Ink.text : Ink.red))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Ink.well))
                        .overlay(Capsule().strokeBorder(recorder.isRecording ? Ink.mint.opacity(0.6) : Ink.line, lineWidth: 1))
                        .animation(Ink.morph, value: recorder.isRecording)
                        Button(recorder.isRecording ? "Cancel" : "Record…") {
                            if recorder.isRecording { recorder.stop(); status.suspendHotkey?(false) }
                            else { status.suspendHotkey?(true); recorder.start { combo in settings.hotkey = combo; status.suspendHotkey?(false) } }
                        }
                        .buttonStyle(InkButtonStyle(primary: !recorder.isRecording))
                    }
                }
                InkRow(label: "Behaviour") {
                    Picker("", selection: $settings.mode) {
                        ForEach(HotkeyMode.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Hairline()
                    Button {
                        withAnimation(Ink.morph) { fineTune.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(fineTune ? 90 : 0))
                            Text("Fine-tune individual keys").font(.system(size: 13))
                            Spacer()
                        }
                        .foregroundStyle(Ink.text)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if fineTune {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(ModKey.allCases) { m in
                                Toggle(m.label, isOn: Binding(
                                    get: { settings.hotkey.mods.contains(m) },
                                    set: { on in var c = settings.hotkey; if on { c.mods.insert(m) } else { c.mods.remove(m) }; settings.hotkey = c }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12.5)).foregroundStyle(Ink.text)
                            }
                        }
                        .padding(.bottom, 6)
                        HStack {
                            Text("Plus key").font(.system(size: 13)).foregroundStyle(Ink.text)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { settings.hotkey.key },
                                set: { k in var c = settings.hotkey; c.key = k; settings.hotkey = c }
                            )) {
                                ForEach(PlainKey.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 200)
                        }
                        .padding(.bottom, 12)
                    }
                }
                if settings.hotkey.mods.contains(.fn) {
                    InkBlock {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.amber).font(.system(size: 11))
                            Text("Set System Settings → Keyboard → “Press 🌐 key to” = Do Nothing, or macOS will open emoji / dictation too.")
                                .font(.system(size: 11.5)).foregroundStyle(Ink.muted)
                        }
                    }
                }
            }

            InkCard(title: "Microphone") {
                InkRow(label: "Input device", divider: false) {
                    Picker("", selection: $settings.inputDeviceUID) {
                        Text("System default (\(AudioDevices.defaultInputName()))").tag("")
                        ForEach(inputs) { Text($0.name).tag($0.uid) }
                    }.labelsHidden().frame(width: 260)
                }
                InkRow(label: "Level") {
                    HStack(spacing: 14) {
                        LevelMeter(level: status.micLevel)
                        Button("Test (3 s)") { status.runMicTest?() }.buttonStyle(InkButtonStyle())
                    }
                }
                if !status.micTest.isEmpty {
                    InkBlock {
                        Text(status.micTest).font(.system(size: 12.5)).foregroundStyle(Ink.muted).textSelection(.enabled)
                    }
                }
            }

            InkCard(title: "Speech model", note: "Runs on this Mac's Neural Engine. Your voice never leaves the machine.") {
                InkRow(label: "Model", divider: false) {
                    Picker("", selection: $settings.model) {
                        ForEach(WhisperModel.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 290)
                }
                InkRow(label: "Status") {
                    StatusChip(text: status.modelStatus, color: modelColor)
                }
                InkRow(label: "Language", hint: "Two-letter code. Leave blank to auto-detect.") {
                    InkField(placeholder: "en", text: $settings.language, width: 80)
                }
            }

            InkCard(title: "Sounds & startup") {
                InkRow(label: "Play sounds on start / stop", divider: false) {
                    Toggle("", isOn: $settings.playSounds).toggleStyle(InkToggleStyle()).labelsHidden()
                }
                InkRow(label: "Launch at login") {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(InkToggleStyle()).labelsHidden()
                        .onChange(of: launchAtLogin) { _, on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { NSLog("launch at login: %@", error.localizedDescription) }
                        }
                }
            }
        }
    }

    private var modelColor: Color {
        let s = status.modelStatus
        if s == "Ready" { return Ink.mint }
        if s.hasPrefix("Failed") { return Ink.red }
        if s == "Not loaded" { return Ink.muted }
        return Ink.amber
    }

    // MARK: cleanup

    private var cleanup: some View {
        Group {
            InkCard(title: "Polish with Claude", note: "Removes fillers and fixes punctuation. Only the transcript text is sent, never audio. Falls back to the raw transcript if the request fails.") {
                InkRow(label: "Polish transcript with Claude", divider: false) {
                    Toggle("", isOn: $settings.cleanupEnabled).toggleStyle(InkToggleStyle()).labelsHidden()
                }
                InkRow(label: "Model") {
                    InkField(placeholder: "claude-haiku-5-5", text: $settings.cleanupModel, width: 220)
                }
                InkRow(label: "Anthropic API key", hint: "Or set ANTHROPIC_API_KEY before launch.") {
                    InkField(placeholder: "sk-ant-…", text: $settings.anthropicKey, secure: true, width: 260)
                }
            }
            InkCard(title: "Dictionary", note: "Names and terms to spell exactly. One per line. These also prime the on-device model.") {
                InkBlock(divider: false) { InkEditor(text: $settings.dictionary, mono: true, minHeight: 120) }
            }
            InkCard(title: "Style notes", note: "Optional. How you like things written: “keep it casual”, “never use semicolons”.") {
                InkBlock(divider: false) { InkEditor(text: $settings.styleNotes, minHeight: 80) }
            }
        }
    }

    // MARK: permissions

    private var permissions: some View {
        Group {
            InkCard(title: "macOS permissions", note: "After granting Accessibility, quit and relaunch Speakhold if the hotkey does not respond.") {
                permissionRow("Microphone", hint: "To hear you.", ok: status.micOK, divider: false) {
                    Task { if await AudioRecorder.requestPermission() == false { Paster.openMicrophonePane() } }
                }
                permissionRow("Accessibility", hint: "For the global hotkey and to paste where your cursor is.", ok: status.axOK) {
                    Paster.promptAccessibility(); Paster.openAccessibilityPane()
                }
            }
            InkCard(title: "Privacy") {
                InkBlock(divider: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        privacyLine("Audio is transcribed on this Mac and never uploaded.")
                        privacyLine("Only the transcript text goes to Claude, and only if polishing is on.")
                        privacyLine("History lives in your user folder. Clear it any time from the menu.")
                    }
                }
            }
        }
    }

    private func privacyLine(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.mint).padding(.top, 3)
            Text(s).font(.system(size: 12.5)).foregroundStyle(Ink.text)
        }
    }

    private func permissionRow(_ title: String, hint: String, ok: Bool, divider: Bool = true, action: @escaping () -> Void) -> some View {
        InkRow(label: title, hint: hint, divider: divider) {
            HStack(spacing: 10) {
                StatusChip(text: ok ? "Granted" : "Not granted", color: ok ? Ink.mint : Ink.red)
                if !ok { Button("Grant…", action: action).buttonStyle(InkButtonStyle(primary: true)) }
            }
        }
    }
}

// MARK: - History window

struct HistoryView: View {
    @ObservedObject var history = History.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SpeakholdGlyph(scale: 1.15).frame(width: 18, height: 16)
                Text("History").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                Spacer()
                Text("\(history.items.count)").font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 14)
            Hairline()
            if history.items.isEmpty {
                VStack(spacing: 10) {
                    SpeakholdGlyph(lit: false, scale: 1.6)
                    Text("Nothing dictated yet.").font(.system(size: 13)).foregroundStyle(Ink.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(item.date, style: .time).font(.system(size: 11)).foregroundStyle(Ink.muted)
                                    if let app = item.app { Text("· \(app)").font(.system(size: 11)).foregroundStyle(Ink.muted) }
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.text, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.mint)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy")
                                }
                                Text(item.text).font(.system(size: 13)).foregroundStyle(Ink.text).lineSpacing(2).textSelection(.enabled)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            Hairline().padding(.horizontal, 20)
                        }
                    }
                }
            }
            Hairline()
            HStack {
                Spacer()
                Button("Clear history") { history.clear() }.buttonStyle(InkButtonStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Ink.bg)
        .preferredColorScheme(.dark)
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
