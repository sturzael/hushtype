import AppKit
import CoreGraphics

/// Global key watcher built on a CGEvent tap (needs Accessibility). Reports press/release of the
/// configured hotkey and swallows Escape while a recording is active.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Bool)?   // return true to swallow
    /// Space tapped while the chord is held: hands-free lock. Return true to swallow the Space.
    var onLock: (() -> Bool)?
    var combo: HotkeyCombo = .standard
    /// While true (Settings is recording a shortcut) the chord never fires.
    var suspended = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var active = false

    func start() -> Bool {
        stop()
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown, keyCode == 53 {   // Escape
            if let onEscape, onEscape() { return nil }
            return Unmanaged.passUnretained(event)
        }

        if suspended { return Unmanaged.passUnretained(event) }
        if type == .keyDown, keyCode == 49, active, let onLock {   // Space while the chord is down
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            var swallow = false
            DispatchQueue.main.sync { swallow = onLock() }
            if swallow { return nil }
        }
        if type == .keyUp, keyCode == 49, active, onLock != nil { return nil }   // and its key-up
        return handleChord(type: type, event: event, keyCode: keyCode)
    }

    /// Chord logic, split out so it can be exercised with synthetic events.
    func handleChord(type: CGEventType, event: CGEvent, keyCode: UInt16) -> Unmanaged<CGEvent>? {
        let flags = event.flags.rawValue
        let modsDown = combo.mods.allSatisfy { flags & $0.deviceMask != 0 }

        if let key = combo.key.keyCode {
            if type == .keyDown, keyCode == key, modsDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !active {
                    active = true; DispatchQueue.main.async { self.onPress?() }
                }
                return nil
            }
            if type == .keyUp, keyCode == key, active {
                active = false; DispatchQueue.main.async { self.onRelease?() }
                return nil
            }
            if type == .flagsChanged, active, !modsDown {
                active = false; DispatchQueue.main.async { self.onRelease?() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard !combo.mods.isEmpty, type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        if modsDown, !active { active = true; DispatchQueue.main.async { self.onPress?() } }
        else if !modsDown, active { active = false; DispatchQueue.main.async { self.onRelease?() } }
        return Unmanaged.passUnretained(event)
    }
}
