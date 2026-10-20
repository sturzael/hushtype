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
    for i in 0..<48 {
        let t = Double(i) / 6
        m.push(level: Float(0.25 + 0.7 * abs(sin(t * 1.3) * cos(t * 0.7))) + Float.random(in: 0...0.2))
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
        ("listening", .listening), ("transcribing", .transcribing), ("cleaning", .cleaning),
        ("done", .done("Hey Smriti, can you check the Pinnacle HubSpot sync before standup?")),
        ("error", .error("Speech model is still loading. Try again in a moment."))]
    for (name, phase) in states {
        let m = OverlayModel(); m.phase = phase
        m.levels = (0..<28).map { _ in Float.random(in: 0.1...1) }
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

// `Speakhold --transcribe file.wav [--no-cleanup]` runs the pipeline headless and prints the result.
let args = CommandLine.arguments
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
            if !args.contains("--no-cleanup"), s.cleanupEnabled, !s.anthropicKey.isEmpty {
                let clean = await Cleanup(apiKey: s.anthropicKey, model: s.cleanupModel)
                    .clean(raw, dictionary: s.dictionaryTerms, style: s.styleNotes, appName: "Test")
                print("CLEAN:", clean)
            }
        } catch { print("ERROR:", error.localizedDescription) }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `Speakhold --render-overlay dir` renders the pill in each state to PNGs (layout check without screen access).
if let i = args.firstIndex(of: "--render-overlay"), i + 1 < args.count {
    MainActor.assumeIsolated { renderOverlay(dir: args[i + 1]) }
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
