import AppKit
import SwiftUI

/// Floating pill at the bottom of the screen, like Willow's. Non-activating so focus stays in the target app.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case hidden, idle, listening, transcribing, cleaning, done(String), error(String) }
    /// Speech model loaded; the idle dot turns from grey to coral.
    @Published var ready = false
    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0.05, count: 28)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, level))
    }
    func resetLevels() { levels = Array(repeating: 0.05, count: 28) }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let flush = Settings.shared.pillPosition != .bottomCenter
        ZStack(alignment: flush ? .bottomTrailing : .bottom) {
            Color.clear
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: flush ? .bottomTrailing : .bottom)
    }

    private var isLit: Bool {
        switch model.phase { case .listening, .transcribing, .cleaning, .done: return true; default: return false }
    }
    private var pillBackground: some View {
        let flush = Settings.shared.pillPosition != .bottomCenter
        let accent = Color(red: 1, green: 0.42, blue: 0.3)
        let fill: Color = isLit ? Color(red: 0.16, green: 0.08, blue: 0.06) : Color(red: 0.42, green: 0.42, blue: 0.46)
        return PillShape(flushRight: flush).fill(fill.opacity(isLit ? 0.95 : 0.55))
            .overlay(PillShape(flushRight: flush).strokeBorder(isLit ? accent.opacity(0.9) : Color.white.opacity(0.08), lineWidth: isLit ? 1.5 : 1))
            .shadow(color: isLit ? accent.opacity(0.55) : .black.opacity(0.2), radius: isLit ? 16 : 6, y: 2)
    }

    private var phaseKey: String {
        switch model.phase {
        case .hidden: return "hidden"; case .idle: return "idle"; case .listening: return "listening"
        case .transcribing: return "transcribing"; case .cleaning: return "cleaning"; case .done: return "done"; case .error: return "error"
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .idle:
                Color.clear.frame(width: 34, height: 6)
            case .listening:
                Waveform(levels: model.levels).frame(width: 96, height: 18)
            case .transcribing, .cleaning:
                Spinner().frame(width: 96, height: 18)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 96, height: 18)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.system(size: 12)).lineLimit(2).frame(maxWidth: 320)
            case .hidden:
                EmptyView()
            }
        }
        .id(phaseKey)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: Settings.shared.pillPosition == .bottomCenter ? .bottom : .bottomTrailing)))
        .foregroundStyle(.white)
        .padding(.horizontal, model.phase == .idle ? 10 : 14)
        .padding(.vertical, model.phase == .idle ? 6 : 9)
        .background(pillBackground)
        .padding(.vertical, 20)
        .padding(.leading, 20)
        .padding(.trailing, Settings.shared.pillPosition == .bottomCenter ? 20 : 0)   // flush against the right screen edge
        .opacity(model.phase == .hidden ? 0 : 1)
    }
}

/// Capsule normally; square right corners when attached to the screen edge.
struct PillShape: InsettableShape {
    var flushRight: Bool
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> PillShape { var c = self; c.inset += amount; return c }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = r.height / 2
        return Path(roundedRect: r, cornerRadii: RectangleCornerRadii(topLeading: radius, bottomLeading: radius,
                                                                         bottomTrailing: flushRight ? 0 : radius, topTrailing: flushRight ? 0 : radius))
    }
}

struct Waveform: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 1, green: 0.42, blue: 0.3))
                    .frame(width: 2.5, height: max(2, CGFloat(l) * 18))
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
            .frame(width: 12, height: 12)
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
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.phase = phase }
        if !isVisible { orderFrontRegardless() }
    }

    /// Returns to the idle state: a small always-on pill if enabled, otherwise fades out.
    func hide() {
        if Settings.shared.showIdlePill {
            show(.idle)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { model.phase = .hidden }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.model.phase == .hidden else { return }
                self.orderOut(nil)
            }
        }
    }

    /// The panel never resizes; it is a fixed transparent box pinned to the chosen corner.
    private func layout(on screen: NSScreen?) {
        guard let screen else { return }
        let f = screen.visibleFrame
        switch Settings.shared.pillPosition {
        case .bottomCenter:
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 4))
        case .bottomRight:
            setFrameOrigin(NSPoint(x: f.maxX - frame.width, y: f.minY + 4))
        case .rightEdge:
            setFrameOrigin(NSPoint(x: f.maxX - frame.width, y: f.midY - frame.height / 2))
        }
    }
}
