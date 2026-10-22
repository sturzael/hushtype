import AppKit
import SwiftUI

/// Floating bar at the screen edge, modelled on Willow's: a tiny tab while idle, a dark pill that streams the
/// words as you speak while the hotkey is held. Non-activating so focus stays in the target app.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case hidden, idle, listening, transcribing, cleaning, done(String), error(String) }
    /// Speech model loaded.
    @Published var ready = false
    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0.05, count: 28)
    /// Partial transcript shown while recording and until the final text is pasted.
    @Published var liveText = ""
    /// Hands-free: the chord was released after a Space tap and recording continues.
    @Published var locked = false
    /// The last recording is still around, so an error can offer "Try again".
    @Published var canRetry = false
    /// Where the pill is, in the panel's SwiftUI coordinates, so the panel can take clicks on it and nothing else.
    @Published var pillFrame: CGRect = .zero
    var onUndo: (() -> Void)?
    var onRetry: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, level))
    }
    func resetLevels() { levels = Array(repeating: 0.05, count: 28) }
}

/// Palette lifted from the MorrisPill lozenge (navy-slate ink, hairline, mint / amber / red status colours).
enum Ink {
    static let bg = Color(red: 0.115, green: 0.125, blue: 0.185)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 0.91, green: 0.92, blue: 0.94)      // #E8EBF0
    static let muted = Color(red: 0.56, green: 0.59, blue: 0.66)     // #8E96A8
    static let mint = Color(red: 0.62, green: 0.91, blue: 0.69)      // #9FE7AF
    static let amber = Color(red: 0.91, green: 0.70, blue: 0.42)     // #E8B36A
    static let red = Color(red: 0.90, green: 0.54, blue: 0.50)       // #E58A80
    /// The MorrisPill open/close curve.
    static let morph = Animation.timingCurve(0.2, 0.9, 0.3, 1.0, duration: 0.24)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var position: PillPosition { Settings.shared.pillPosition }
    private var isIdle: Bool { model.phase == .idle }
    private var anchor: Alignment {
        switch position { case .bottomCenter: return .bottom; case .bottomRight: return .bottomTrailing; case .rightEdge: return .trailing }
    }
    private var unitAnchor: UnitPoint {
        switch position { case .bottomCenter: return .bottom; case .bottomRight: return .bottomTrailing; case .rightEdge: return .trailing }
    }

    var body: some View {
        ZStack(alignment: anchor) {
            Color.clear
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
    }

    private var isLit: Bool {
        switch model.phase { case .listening, .transcribing, .cleaning, .done, .error: return true; default: return false }
    }
    private var docked: Bool { position == .rightEdge }

    /// Rounded rect, squared on whichever screen edge it is docked against.
    private var shape: PillShape {
        switch position {
        case .bottomCenter: return PillShape(squareRight: false, squareBottom: isIdle)
        case .bottomRight: return PillShape(squareRight: true, squareBottom: isIdle)
        case .rightEdge: return PillShape(squareRight: true, squareBottom: false)
        }
    }

    private var pillBackground: some View {
        shape.fill(Ink.bg)
            .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
            .shadow(color: .black.opacity(isLit ? 0.4 : 0.3), radius: isLit ? 12 : 6, y: 2)
    }

    private var phaseKey: String {
        switch model.phase {
        case .hidden: return "hidden"; case .idle: return "idle"; case .listening: return "listening"
        case .transcribing: return "transcribing"; case .cleaning: return "cleaning"; case .done: return "done"; case .error: return "error"
        }
    }

    /// Mint action on the pill ("Undo", "Try again").
    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.mint)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().strokeBorder(Ink.mint.opacity(0.55), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func words(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13.5))
            .lineLimit(1)
            .truncationMode(.head)   // like Willow: the newest words stay visible, the start scrolls off
            .foregroundStyle(Ink.text)
    }

    /// Idle glyph: three still bars, mint once the model is loaded.
    private var glyph: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach([6, 12, 8], id: \.self) { h in
                RoundedRectangle(cornerRadius: 1.25).fill(model.ready ? Ink.mint : Ink.muted).frame(width: 2.5, height: CGFloat(h))
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                glyph.frame(width: docked ? 14 : 28, height: docked ? 36 : 12)
            case .listening:
                if model.locked {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.mint)
                }
                Waveform(levels: Array(model.levels.suffix(14))).frame(height: 18)
                if !model.liveText.isEmpty { words(model.liveText) }
            case .transcribing:
                ThinkingDots(color: Ink.mint)
                if !model.liveText.isEmpty { words(model.liveText + "…") }
            case .cleaning:
                ThinkingDots(color: Ink.amber)
                if !model.liveText.isEmpty { words(model.liveText + "…") }
            case .done(let text):
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.mint)
                words(text)
                if model.onUndo != nil { chip("Undo") { model.onUndo?() } }
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.red)
                Text(msg).font(.system(size: 13)).lineLimit(2).foregroundStyle(Ink.text)
                if model.canRetry { chip("Try again") { model.onRetry?() } }
            case .hidden:
                EmptyView()
            }
        }
        .id(phaseKey)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: unitAnchor)))
        .padding(.horizontal, isIdle ? 8 : 14)
        .padding(.vertical, isIdle ? 8 : 10)
        .background(pillBackground)
        .background(GeometryReader { g in Color.clear.preference(key: PillFrameKey.self, value: g.frame(in: .global)) })
        .onPreferenceChange(PillFrameKey.self) { model.pillFrame = $0 }
        .onHover { model.onHover?($0) }
        .animation(Ink.morph, value: model.liveText)
        .padding(.top, 20)
        .padding(.leading, 20)
        .padding(.bottom, (isIdle && !docked) ? 0 : 16)   // bottom tab sits on the edge; the pill floats above it
        .padding(.trailing, position == .bottomCenter ? 20 : 0)   // flush against the right screen edge
        .opacity(model.phase == .hidden ? 0 : 1)
    }
}

struct PillFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Capsule, with the corners squared off on whichever screen edges it is docked against.
struct PillShape: InsettableShape {
    var squareRight: Bool
    var squareBottom: Bool
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> PillShape { var c = self; c.inset += amount; return c }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(14, r.height / 2)
        return Path(roundedRect: r, cornerRadii: RectangleCornerRadii(
            topLeading: radius,
            bottomLeading: squareBottom ? 0 : radius,
            bottomTrailing: (squareRight || squareBottom) ? 0 : radius,
            topTrailing: squareRight ? 0 : radius))
    }
}

struct Waveform: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Ink.mint)
                    .frame(width: 2.5, height: max(3, CGFloat(l) * 18))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

/// MorrisPill's "thinking" dots: three dots breathing in sequence. Each animation is scoped to its own dot.
struct ThinkingDots: View {
    var color: Color
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in BreathingDot(color: color, delay: Double(i) * 0.18) }
        }
    }
}

struct BreathingDot: View {
    var color: Color
    var delay: Double
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 5, height: 5)
            .opacity(on ? 1 : 0.2)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(delay), value: on)
            .onAppear { on = true }
    }
}

/// Small white arc spinner; pure SwiftUI so it renders everywhere (ProgressView is AppKit-backed).
struct Spinner: View {
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

final class OverlayPanel: NSPanel {
    let model = OverlayModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 110),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.wantsLayer = true
        contentView = host
        // The panel is a wide transparent strip, so it must ignore the mouse except exactly over the pill while
        // the pill offers an action. A global monitor sees the mouse while other apps own it; onHover(false)
        // hands it back once the pointer leaves the pill.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.trackMouse() }
        model.onHover = { [weak self] inside in if !inside { self?.ignoresMouseEvents = true } }
    }

    private var mouseMonitor: Any?

    /// Phases with a clickable chip.
    private var interactive: Bool {
        switch model.phase {
        case .done: return model.onUndo != nil
        case .error: return model.canRetry
        default: return false
        }
    }

    private func trackMouse() {
        guard interactive, isVisible, model.pillFrame != .zero else { ignoresMouseEvents = true; return }
        let f = model.pillFrame, p = NSEvent.mouseLocation, w = frame
        // SwiftUI's global space is the window with a top-left origin; check the bottom-left reading too so a
        // coordinate-convention surprise degrades to a slightly larger hit area rather than a dead button.
        let topLeft = NSRect(x: w.minX + f.minX, y: w.maxY - f.maxY, width: f.width, height: f.height)
        let bottomLeft = NSRect(x: w.minX + f.minX, y: w.minY + f.minY, width: f.width, height: f.height)
        ignoresMouseEvents = !(topLeft.contains(p) || bottomLeft.contains(p))
    }

    private var placedOn: NSScreen?

    /// Settings changed position: re-pin the panel.
    func relayout() { placedOn = nil }

    func show(_ phase: OverlayModel.Phase) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if !isVisible || screen != placedOn { layout(on: screen); placedOn = screen }
        withAnimation(Ink.morph) {
            model.phase = phase
            if phase == .idle || phase == .hidden { model.liveText = ""; model.locked = false }
        }
        ignoresMouseEvents = true   // trackMouse re-enables over a chip
        if !isVisible { orderFrontRegardless() }
    }

    /// Returns to the idle state: a small always-on tab if enabled, otherwise fades out.
    func hide() {
        if Settings.shared.showIdlePill {
            show(.idle)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { model.phase = .hidden; model.liveText = "" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.model.phase == .hidden else { return }
                self.orderOut(nil)
            }
        }
    }

    /// The panel never resizes while showing; it is a fixed transparent box pinned to the chosen edge, wide enough
    /// for the live transcript (the Text truncates at the panel's edge, so the panel width is the pill's maximum).
    private func layout(on screen: NSScreen?) {
        guard let screen else { return }
        let f = screen.visibleFrame
        let width = min(f.width * 0.72, 980)
        let height: CGFloat = 110
        switch Settings.shared.pillPosition {
        case .bottomCenter:
            setFrame(NSRect(x: f.midX - width / 2, y: f.minY, width: width, height: height), display: false)
        case .bottomRight:
            setFrame(NSRect(x: f.maxX - width, y: f.minY, width: width, height: height), display: false)
        case .rightEdge:   // slightly above centre, where the MorrisPill lozenge sat
            setFrame(NSRect(x: f.maxX - width, y: f.midY + f.height * 0.05 - height / 2, width: width, height: height), display: false)
        }
    }
}
