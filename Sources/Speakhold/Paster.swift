import AppKit
import Carbon.HIToolbox

/// Puts text on the pasteboard, sends ⌘V to the frontmost app, then restores what was there.
enum Paster {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the target app time to read the pasteboard before restoring the user's clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if pb.string(forType: .string) == text, let previous {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }

    /// ⌘Z to the frontmost app: the standard undo of the paste we just sent.
    static func undo() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let z = CGKeyCode(kVK_ANSI_Z)
        let down = CGEvent(keyboardEventSource: src, virtualKey: z, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: z, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilityPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openMicrophonePane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
