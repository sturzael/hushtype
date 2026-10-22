import SwiftUI

/// The meeting window: your own notes while the call runs, the clock, mark-a-moment, catch-me-up, stop.
/// Same ink kit as Settings. Opens when a recording starts; closing it does not stop the recording.
struct MeetingView: View {
    @ObservedObject var state: MeetingState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RecordingDot()
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Meeting title", text: $state.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    if !state.attendees.isEmpty {
                        Text(state.attendees.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Ink.muted).lineLimit(1)
                    }
                }
                Spacer()
                Text(state.elapsedLabel).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(Ink.mint)
            }
            .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 14)
            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR NOTES").font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(Ink.muted)
                InkEditor(text: $state.notes, minHeight: 160)
                Text("Type what matters as it happens, or dictate into this box. The transcript expands these afterwards.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            if !state.marks.isEmpty {
                HStack(spacing: 8) {
                    Text("MARKED").font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(Ink.muted)
                    ForEach(state.marks.indices, id: \.self) { i in
                        Text(MeetingView.stamp(state.marks[i])).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Ink.text)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Ink.well)).overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }

            if state.catchingUp || !state.catchUp.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("THE LAST TWO MINUTES").font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(Ink.muted)
                        if state.catchingUp { ThinkingDots(color: Ink.mint) }
                    }
                    ScrollView {
                        Text(state.catchUp.isEmpty ? "Listening back…" : state.catchUp)
                            .font(.system(size: 12.5)).foregroundStyle(Ink.text).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).fill(Ink.well))
                    .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }

            Spacer(minLength: 0)
            Hairline()
            HStack(spacing: 10) {
                Button("Mark this moment") { state.onMark?() }.buttonStyle(InkButtonStyle())
                Button("Catch me up") { state.onCatchUp?() }.buttonStyle(InkButtonStyle()).disabled(state.catchingUp)
                Spacer()
                if !state.status.isEmpty { Text(state.status).font(.system(size: 12)).foregroundStyle(Ink.muted) }
                Button(state.active ? "Stop & write notes" : "Done") { state.onStop?() }.buttonStyle(InkButtonStyle(primary: true))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(Ink.bg)
        .tint(Ink.mint)
        .preferredColorScheme(.dark)
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
