import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// `Speakhold --render-gif out.gif` writes an animated demo of the pill for the README.
@MainActor func renderGif(path: String) {
    let m = OverlayModel()
    var frames: [CGImage] = []
    func snap() {
        let r = ImageRenderer(content: OverlayView(model: m).frame(width: 520, height: 90)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.24), Color(red: 0.10, green: 0.11, blue: 0.16)], startPoint: .top, endPoint: .bottom)))
        r.scale = 2
        if let cg = r.cgImage { frames.append(cg) }
    }
    m.phase = .listening
    for i in 0..<28 { m.push(level: Float(0.25 + 0.7 * abs(sin(Double(i) / 4)))) }
    let spoken = "Can you check the HubSpot sync before standup?".split(separator: " ")
    for i in 0..<60 {
        let t = Double(i) / 6
        m.push(level: Float(0.25 + 0.7 * abs(sin(t * 1.3) * cos(t * 0.7))) + Float.random(in: 0...0.2))
        if i >= 8, i % 6 == 2 { m.liveText = spoken.prefix(min(spoken.count, (i - 8) / 6 + 1)).joined(separator: " ") }
        snap()
    }
    m.phase = .transcribing
    for _ in 0..<12 { snap() }
    m.phase = .done("Can you check the HubSpot sync before standup?")
    for _ in 0..<24 { snap() }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for f in frames {
        CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.06]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    print("wrote", path, frames.count, "frames")
}

@MainActor func renderOverlay(dir: String) {
    let states: [(String, OverlayModel.Phase)] = [
        ("idle", .idle), ("listening", .listening), ("transcribing", .transcribing), ("cleaning", .cleaning),
        ("done", .done("Can you check the sync before standup?")),
        ("error", .error("Speech model is still loading. Try again in a moment."))]
    for (name, phase) in states {
        let m = OverlayModel(); m.phase = phase
        m.levels = (0..<28).map { _ in Float.random(in: 0.1...1) }
        if phase == .listening || phase == .transcribing { m.liveText = "Can you check the sync before" }
        let r = ImageRenderer(content: OverlayView(model: m).background(Color(red: 0.93, green: 0.93, blue: 0.95)))
        r.scale = 2
        guard let cg = r.cgImage else { print("render failed", name); continue }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/pill-\(name).png"))
            print("wrote", name, cg.width, cg.height)
        }
    }
}

/// `Speakhold --render-settings dir` draws each settings tab (and History) through AppKit's offscreen cache so the
/// window layout can be checked without a display grant. ImageRenderer cannot draw native controls, hence the window.
@MainActor func renderSettings(dir: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let status = AppStatus()
    status.modelStatus = "Ready"; status.micOK = true; status.axOK = false; status.micLevel = 0.62
    status.micTest = "Heard: “testing one two three”"
    var shots: [(String, NSWindow)] = SettingsTab.allCases.map {
        ($0.rawValue, AppDelegate.inkWindow(title: "Speakhold Settings", root: SettingsView(status: status, tab: $0, scrolls: false)))
    }
    shots.append(("history", AppDelegate.inkWindow(title: "Dictation History", root: HistoryView(), resizable: true)))
    for (name, w) in shots {
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let v = w.contentView, let layer = v.layer else { print("no view", name); continue }
        let scale = w.backingScaleFactor
        let size = CGSize(width: v.bounds.width * scale, height: v.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
        ctx.translateBy(x: 0, y: size.height)   // CALayer renders flipped into a CG context
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { continue }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/settings-\(name).png"))
            print("wrote", name, rep.pixelsWide, rep.pixelsHigh)
        }
        w.close()
    }
}

let args = CommandLine.arguments

// `Speakhold --toggle | --start | --stop | --cancel | --settings | --history` controls the running copy
// (same as `open speakhold://toggle`), for SketchyBar, Raycast, Shortcuts and scripts.
if let cmd = ["--toggle", "--start", "--stop", "--cancel", "--settings", "--history", "--meeting", "--mark", "--catchup"].first(where: { args.contains($0) }) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("co.wildinteractive.speakhold.command"), object: String(cmd.dropFirst(2)), userInfo: nil, deliverImmediately: true)
    exit(0)
}

// `Speakhold --transcribe file.wav [--no-cleanup]` runs the pipeline headless and prints the result.
if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    let path = args[i + 1]
    let s = Settings.shared
    let t = Transcriber()
    let sem = DispatchSemaphore(value: 0)
    Task {
        await t.setStateHandler { st in print("model:", st) }
        await t.prepare(model: s.model.rawValue)
        do {
            let raw = try await t.transcribeFile(path, language: s.language, promptTerms: s.dictionaryTerms)
            print("RAW:", raw)
            if !args.contains("--no-cleanup") {
                print("CLEAN (\(s.cleanupEngine.rawValue)):", await Polish.run(raw, settings: s, appName: "Test"))
            }
        } catch { print("ERROR:", error.localizedDescription) }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `Speakhold --polish "raw text"` runs the polish pipeline (spoken commands → model → replacements) on a string.
if let i = args.firstIndex(of: "--polish"), i + 1 < args.count {
    let s = Settings.shared
    let sem = DispatchSemaphore(value: 0)
    Task {
        print("engine:", s.cleanupEngine.rawValue, "apple available:", Polish.appleAvailable)
        print("commands:", SpokenCommands.apply(args[i + 1]))
        let t = Date()
        print("polished:", await Polish.run(args[i + 1], settings: s, appName: "Test"), String(format: "(%.2fs)", Date().timeIntervalSince(t)))
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `Speakhold --record-meeting seconds dir` records system audio + mic for `seconds` and writes system.wav, mic.wav
// and result.txt into dir. Run as the app bundle (`open -n -a Speakhold --args --record-meeting 12 /tmp/x`) so
// macOS attributes the "System Audio Recording Only" and microphone prompts to Speakhold.
if let i = args.firstIndex(of: "--record-meeting"), i + 2 < args.count {
    let seconds = Double(args[i + 1]) ?? 10
    let dir = args[i + 2]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var log: [String] = []
    func note(_ s: String) { log.append(s); print(s); try? log.joined(separator: "\n").write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8) }
    let sem = DispatchSemaphore(value: 0)
    Task {
        let ok = await AudioRecorder.requestPermission()
        note("mic permission: \(ok)")
        guard #available(macOS 14.2, *) else { note("needs macOS 14.2"); sem.signal(); return }
        let cap = MeetingCapture()
        do { try cap.start(); note("capturing \(seconds)s, tap \(cap.tapDescription)") }
        catch { note("capture failed: \(error.localizedDescription)"); sem.signal(); return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        cap.stop()
        cap.loadFromDisk()
        let recent = cap.recent(seconds: 5)
        note("ring: mic \(recent.mic.count) system \(recent.system.count) samples in the last 5 s")
        let sysPeak = cap.system.map(abs).max() ?? 0, micPeak = cap.mic.map(abs).max() ?? 0
        note(String(format: "system %.1fs peak %.3f | mic %.1fs peak %.3f", Double(cap.system.count) / 16_000, sysPeak, Double(cap.mic.count) / 16_000, micPeak))
        try? MeetingCapture.writeWAV(cap.system, to: dir + "/system.wav")
        try? MeetingCapture.writeWAV(cap.mic, to: dir + "/mic.wav")
        note("wrote system.wav + mic.wav")
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `Speakhold --meeting-from-files me.wav them.wav` runs the meeting pipeline (segments → merge → notes → markdown)
// on two recordings, for testing without a call.
if let i = args.firstIndex(of: "--meeting-from-files"), i + 2 < args.count {
    guard #available(macOS 14.2, *) else { exit(1) }
    let s = Settings.shared
    let t = Transcriber()
    let sem = DispatchSemaphore(value: 0)
    Task {
        await t.prepare(model: s.model.rawValue)
        let session = MeetingSession(title: "Test meeting")
        session.capture.load(micPath: args[i + 1], systemPath: args[i + 2])
        if args.contains("--marks") { session.marks = [5, 12] }
        if let n = args.firstIndex(of: "--notes"), n + 1 < args.count { session.userNotes = args[n + 1] }
        let engine: MeetingTranscriber = args.contains("--parakeet") ? ParakeetMeetingTranscriber() : WhisperMeetingTranscriber(transcriber: t)
        let dia: MeetingDiarizer? = args.contains("--diarise") ? FluidMeetingDiarizer() : nil
        do {
            let url = try await session.finish(transcriber: engine, diarizer: dia, settings: s) { print("…", $0) }
            print("WROTE", url.path)
            print(try String(contentsOf: url, encoding: .utf8))
        } catch { print("ERROR", error.localizedDescription) }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `Speakhold --calls` lists apps currently using the microphone (the auto-offer signal).
if args.contains("--calls") {
    if #available(macOS 14.2, *) { for c in CallDetector.activeCalls() { print(c.pid, c.name) } }
    print("done")
    exit(0)
}

// `Speakhold --render-overlay dir` renders the pill in each state to PNGs (layout check without screen access).
if let i = args.firstIndex(of: "--render-overlay"), i + 1 < args.count {
    MainActor.assumeIsolated { renderOverlay(dir: args[i + 1]) }
    exit(0)
}

// `Speakhold --render-settings dir` renders the settings window tabs to PNGs.
if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
    MainActor.assumeIsolated { renderSettings(dir: args[i + 1]) }
    exit(0)
}

// `Speakhold --test-hotkey` feeds synthetic flag events through the chord matcher.
if args.contains("--test-hotkey") {
    let m = HotkeyMonitor()
    m.combo = HotkeyCombo(mods: [.lctrl, .lopt], key: .none)
    var log: [String] = []
    m.onPress = { log.append("press") }
    m.onRelease = { log.append("release") }
    func flags(_ raw: UInt64) {
        let e = CGEvent(source: nil)!
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: raw)
        _ = m.handleChord(type: .flagsChanged, event: e, keyCode: 59)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let ctrl: UInt64 = 0x40001, opt: UInt64 = 0x80020, ropt: UInt64 = 0x80040
    flags(ctrl)              // left ctrl only → nothing
    flags(ctrl | opt)        // both → press
    flags(ctrl | opt | 0x2)  // extra shift → still held
    flags(opt)               // ctrl up → release
    flags(0)
    flags(ctrl | ropt)       // right option does not count
    flags(0)
    print("hotkey events:", log)
    exit(log == ["press", "release"] ? 0 : 1)
}

if let i = args.firstIndex(of: "--render-gif"), i + 1 < args.count {
    MainActor.assumeIsolated { renderGif(path: args[i + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
