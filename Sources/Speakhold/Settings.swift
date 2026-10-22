import Foundation
import AppKit
import Combine

/// A single physical modifier key. Device-specific CGEventFlags bits let us tell left from right.
enum ModKey: String, CaseIterable, Codable, Identifiable {
    case lctrl, lopt, lshift, lcmd, rctrl, ropt, rshift, rcmd, fn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lctrl: return "Left ⌃ Control"
        case .lopt: return "Left ⌥ Option"
        case .lshift: return "Left ⇧ Shift"
        case .lcmd: return "Left ⌘ Command"
        case .rctrl: return "Right ⌃ Control"
        case .ropt: return "Right ⌥ Option"
        case .rshift: return "Right ⇧ Shift"
        case .rcmd: return "Right ⌘ Command"
        case .fn: return "fn / 🌐"
        }
    }
    var short: String {
        switch self {
        case .lctrl: return "L⌃"; case .lopt: return "L⌥"; case .lshift: return "L⇧"; case .lcmd: return "L⌘"
        case .rctrl: return "R⌃"; case .ropt: return "R⌥"; case .rshift: return "R⇧"; case .rcmd: return "R⌘"
        case .fn: return "fn"
        }
    }
    /// NX_DEVICE* masks from IOKit/hidsystem/IOLLEvent.h, present in CGEventFlags.rawValue.
    var deviceMask: UInt64 {
        switch self {
        case .lctrl: return 0x0000_0001
        case .lshift: return 0x0000_0002
        case .rshift: return 0x0000_0004
        case .lcmd: return 0x0000_0008
        case .rcmd: return 0x0000_0010
        case .lopt: return 0x0000_0020
        case .ropt: return 0x0000_0040
        case .rctrl: return 0x0000_2000
        case .fn: return 0x0080_0000
        }
    }
}

/// Optional non-modifier key that completes the chord.
enum PlainKey: String, CaseIterable, Codable, Identifiable {
    case none, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    var id: String { rawValue }
    var label: String { self == .none ? "None (modifiers only)" : rawValue.uppercased() }
    static func from(keyCode: UInt16) -> PlainKey? { allCases.first { $0.keyCode == keyCode } }
    var keyCode: UInt16? {
        switch self {
        case .none: return nil
        case .f1: return 122; case .f2: return 120; case .f3: return 99; case .f4: return 118
        case .f5: return 96; case .f6: return 97; case .f7: return 98; case .f8: return 100
        case .f9: return 101; case .f10: return 109; case .f11: return 103; case .f12: return 111
        }
    }
}

struct HotkeyCombo: Codable, Equatable {
    var mods: Set<ModKey>
    var key: PlainKey
    static let standard = HotkeyCombo(mods: [.lctrl, .lopt], key: .none)
    var isValid: Bool { !mods.isEmpty || key != .none }
    var label: String {
        let parts = ModKey.allCases.filter { mods.contains($0) }.map(\.short) + (key == .none ? [] : [key.label])
        return parts.isEmpty ? "Not set" : parts.joined(separator: " + ")
    }
}

enum PillPosition: String, CaseIterable, Identifiable {
    case bottomCenter, bottomRight, rightEdge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter: return "Bottom centre"
        case .bottomRight: return "Bottom right, flush to the edge"
        case .rightEdge: return "Right edge, mid-height"
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case hold, toggle
    var id: String { rawValue }
    var label: String { self == .hold ? "Hold to talk" : "Press to start / stop" }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3 = "openai_whisper-large-v3-v20240930_626MB"
    case distil = "distil-whisper_distil-large-v3_turbo_600MB"
    case base = "openai_whisper-base.en"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .turbo: return "Large v3 Turbo (recommended, ~630 MB)"
        case .largeV3: return "Large v3 (most accurate, slower)"
        case .distil: return "Distil Large v3 (fastest large)"
        case .base: return "Base English (tiny, quick test)"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var hotkey: HotkeyCombo {
        didSet { if let data = try? JSONEncoder().encode(hotkey) { d.set(data, forKey: "hotkeyCombo") } }
    }
    @Published var mode: HotkeyMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var model: WhisperModel { didSet { d.set(model.rawValue, forKey: "model") } }
    @Published var cleanupEnabled: Bool { didSet { d.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var cleanupModel: String { didSet { d.set(cleanupModel, forKey: "cleanupModel") } }
    @Published var anthropicKey: String { didSet { d.set(anthropicKey, forKey: "anthropicKey") } }
    @Published var dictionary: String { didSet { d.set(dictionary, forKey: "dictionary") } }
    @Published var styleNotes: String { didSet { d.set(styleNotes, forKey: "styleNotes") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var inputDeviceUID: String { didSet { d.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    @Published var showIdlePill: Bool { didSet { d.set(showIdlePill, forKey: "showIdlePill") } }
    @Published var livePreview: Bool { didSet { d.set(livePreview, forKey: "livePreview") } }
    @Published var pillPosition: PillPosition { didSet { d.set(pillPosition.rawValue, forKey: "pillPosition") } }
    /// Keep an icon in the Dock (click it to open Settings; right-click for the menu). Off = menu-bar only.
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }

    private init() {
        if let data = d.data(forKey: "hotkeyCombo"), let c = try? JSONDecoder().decode(HotkeyCombo.self, from: data), c.isValid {
            hotkey = c
        } else {
            hotkey = .standard
        }
        mode = HotkeyMode(rawValue: d.string(forKey: "mode") ?? "") ?? .hold
        model = WhisperModel(rawValue: d.string(forKey: "model") ?? "") ?? .turbo
        cleanupEnabled = d.object(forKey: "cleanupEnabled") as? Bool ?? true
        cleanupModel = d.string(forKey: "cleanupModel") ?? "claude-haiku-5-5"
        anthropicKey = d.string(forKey: "anthropicKey") ?? Settings.keyFromEnvironment()
        dictionary = d.string(forKey: "dictionary") ?? ""
        styleNotes = d.string(forKey: "styleNotes") ?? ""
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        language = d.string(forKey: "language") ?? "en"
        inputDeviceUID = d.string(forKey: "inputDeviceUID") ?? ""
        showIdlePill = d.object(forKey: "showIdlePill") as? Bool ?? true
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
        pillPosition = PillPosition(rawValue: d.string(forKey: "pillPosition") ?? "") ?? .rightEdge
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
    }

    /// Picks up ANTHROPIC_API_KEY from the environment on first launch so there is nothing to paste.
    static func keyFromEnvironment() -> String {
        let v = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        return v.hasPrefix("sk-ant-api") ? v : ""
    }

    var dictionaryTerms: [String] {
        dictionary.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
