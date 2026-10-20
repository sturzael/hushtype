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
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                Circle().fill(model.ready ? Color(red: 1, green: 0.42, blue: 0.3) : Color.gray).frame(width: 7, height: 7)
                HStack(spacing: 2) {
                    ForEach(0..<9, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.7))
                            .frame(width: 2, height: [4, 8, 12, 7, 10, 6, 11, 8, 4][i])
                    }
                }.frame(height: 12)
            case .listening:
                PulsingDot()
                Waveform(levels: model.levels)
                    .frame(width: 120, height: 22)
                Text("Listening").font(.system(size: 13, weight: .medium))
                Text("esc to cancel").font(.system(size: 11)).foregroundStyle(.secondary)
            case .transcribing:
                Spinner()
                Text("Transcribing…").font(.system(size: 13, weight: .medium))
            case .cleaning:
                Spinner()
                Text("Polishing…").font(.system(size: 13, weight: .medium))
            case .done(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.system(size: 13)).lineLimit(2).frame(maxWidth: 360)
            case .hidden:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, model.phase == .idle ? 11 : 16)
        .padding(.vertical, model.phase == .idle ? 7 : 10)
        .background(
            PillShape(flushRight: Settings.shared.pillPosition != .bottomCenter).fill(Color.black.opacity(0.82))
                .overlay(PillShape(flushRight: Settings.shared.pillPosition != .bottomCenter).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .padding(.vertical, 20)
        .padding(.leading, 20)
        .padding(.trailing, Settings.shared.pillPosition == .bottomCenter ? 20 : 0)   // flush against the right screen edge
        .animation(.easeInOut(duration: 0.18), value: model.phase)
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
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2.5, height: max(3, CGFloat(l) * 22))
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
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

final class OverlayPanel: NSPanel {
    let model = OverlayModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
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

    func show(_ phase: OverlayModel.Phase) {
        model.phase = phase
        layoutAtBottomCenter()
        if !isVisible { orderFrontRegardless() }
    }

    /// Returns to the idle state: a small always-on pill if enabled, otherwise hidden.
    func hide() {
        if Settings.shared.showIdlePill {
            show(.idle)
        } else {
            model.phase = .hidden
            orderOut(nil)
        }
    }

    private func layoutAtBottomCenter() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        if let host = contentView as? NSHostingView<OverlayView> {
            let size = host.fittingSize
            setContentSize(NSSize(width: ceil(size.width), height: ceil(size.height)))
        }
        let f = screen.visibleFrame
        switch Settings.shared.pillPosition {
        case .bottomCenter:
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 24))
        case .bottomRight:
            setFrameOrigin(NSPoint(x: f.maxX - frame.width, y: f.minY + 24))
        case .rightEdge:
            setFrameOrigin(NSPoint(x: f.maxX - frame.width, y: f.midY - frame.height / 2))
        }
    }
}
