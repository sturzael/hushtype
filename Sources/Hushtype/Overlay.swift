import AppKit
import SwiftUI

/// Floating pill at the bottom of the screen, like Willow's. Non-activating so focus stays in the target app.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case hidden, listening, transcribing, cleaning, done(String), error(String) }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .padding(20)
        .animation(.easeInOut(duration: 0.18), value: model.phase)
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

    func hide() {
        model.phase = .hidden
        orderOut(nil)
    }

    private func layoutAtBottomCenter() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        if let host = contentView as? NSHostingView<OverlayView> {
            let size = host.fittingSize
            setContentSize(NSSize(width: max(size.width, 160), height: max(size.height, 60)))
        }
        let f = screen.visibleFrame
        let x = f.midX - frame.width / 2
        let y = f.minY + 24
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
