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

    func push(level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, level))
    }
    func resetLevels() { levels = Array(repeating: 0.05, count: 28) }
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

    /// The idle tab hugs the screen edge it is docked to; the active pill floats just off it.
    private var shape: PillShape {
        switch position {
        case .bottomCenter: return PillShape(squareRight: false, squareBottom: isIdle)
        case .bottomRight: return PillShape(squareRight: true, squareBottom: isIdle)
        case .rightEdge: return PillShape(squareRight: true, squareBottom: false)
        }
    }

    private var pillBackground: some View {
        let accent = Color(red: 1, green: 0.42, blue: 0.3)
        let fill: Color = isLit ? Color(red: 0.11, green: 0.10, blue: 0.11) : Color(red: 0.24, green: 0.24, blue: 0.27)
        return shape.fill(fill.opacity(isLit ? 0.96 : 0.85))
            .overlay(shape.strokeBorder(isLit ? accent.opacity(0.75) : Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: isLit ? accent.opacity(0.45) : .black.opacity(0.25), radius: isLit ? 14 : 4, y: 1)
    }

    private var phaseKey: String {
        switch model.phase {
        case .hidden: return "hidden"; case .idle: return "idle"; case .listening: return "listening"
        case .transcribing: return "transcribing"; case .cleaning: return "cleaning"; case .done: return "done"; case .error: return "error"
        }
    }

    private func words(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
            .truncationMode(.head)   // like Willow: the newest words stay visible, the start scrolls off
            .foregroundStyle(.white)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                Color.clear.frame(width: 36, height: 6)
            case .listening:
                Waveform(levels: Array(model.levels.suffix(14))).frame(height: 18)
                if !model.liveText.isEmpty { words(model.liveText) }
            case .transcribing, .cleaning:
                Spinner()
                if !model.liveText.isEmpty { words(model.liveText + "…") }
            case .done(let text):
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                words(text)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.system(size: 13)).lineLimit(2).foregroundStyle(.white)
            case .hidden:
                EmptyView()
            }
        }
        .id(phaseKey)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: unitAnchor)))
        .padding(.horizontal, isIdle ? 10 : 16)
        .padding(.vertical, isIdle ? 5 : 11)
        .background(pillBackground)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.liveText)
        .padding(.top, 20)
        .padding(.leading, 20)
        .padding(.bottom, (isIdle && position != .rightEdge) ? 0 : 16)   // tab sits on the edge; pill floats above it
        .padding(.trailing, position == .bottomCenter ? 20 : 0)           // flush against the right screen edge
        .opacity(model.phase == .hidden ? 0 : 1)
    }
}

/// Capsule, with the corners squared off on whichever screen edges it is docked against.
struct PillShape: InsettableShape {
    var squareRight: Bool
    var squareBottom: Bool
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> PillShape { var c = self; c.inset += amount; return c }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = r.height / 2
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
                    .fill(Color(red: 1, green: 0.42, blue: 0.3))
                    .frame(width: 2.5, height: max(3, CGFloat(l) * 18))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

/// Red recording dot that breathes. Animation is scoped to the dot so it cannot leak into siblings.
struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.red).frame(width: 8, height: 8)
            .opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
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
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.wantsLayer = true
        contentView = host
    }

    private var placedOn: NSScreen?

    /// Settings changed position: re-pin the panel.
    func relayout() { placedOn = nil }

    func show(_ phase: OverlayModel.Phase) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if !isVisible || screen != placedOn { layout(on: screen); placedOn = screen }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            model.phase = phase
            if phase == .idle || phase == .hidden { model.liveText = "" }
        }
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
        case .rightEdge:
            setFrame(NSRect(x: f.maxX - width, y: f.midY - height / 2, width: width, height: height), display: false)
        }
    }
}
