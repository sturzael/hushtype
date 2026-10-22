import AppKit
import Foundation

/// One recorded meeting: both sides captured on this Mac, transcribed on the Neural Engine, written as one
/// markdown file (notes first, full transcript after). Nothing leaves the machine unless Claude is the notes
/// engine, and then only the transcript text.
@available(macOS 14.2, *)

final class MeetingSession {
    let capture = MeetingCapture()
    let started = Date()
    private(set) var title: String

    static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Speakhold Meetings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(title: String? = nil) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        self.title = title ?? "Meeting \(f.string(from: Date()))"
    }

    func start() throws { try capture.start() }

    var elapsed: TimeInterval { Date().timeIntervalSince(started) }
    var elapsedLabel: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    struct Line { var time: Double; var speaker: String; var text: String }

    /// Stop capturing, transcribe both streams, write notes + transcript, return the file.
    func finish(transcriber: Transcriber, settings: Settings, progress: @escaping (String) -> Void) async throws -> URL {
        capture.stop()
        let duration = Double(max(capture.mic.count, capture.system.count)) / 16_000
        let me = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
        let them = "Them"

        progress("Transcribing your side…")
        let mine = try await transcriber.transcribeSegments(capture.mic, language: settings.language, promptTerms: settings.dictionaryTerms)
        progress("Transcribing the other side…")
        let theirs = try await transcriber.transcribeSegments(capture.system, language: settings.language, promptTerms: settings.dictionaryTerms)

        var lines = mine.map { Line(time: $0.start, speaker: me, text: $0.text) } + theirs.map { Line(time: $0.start, speaker: them, text: $0.text) }
        lines.sort { $0.time < $1.time }
        // Merge consecutive lines from the same speaker that run on within a few seconds.
        var merged: [Line] = []
        for l in lines {
            if var last = merged.last, last.speaker == l.speaker, l.time - last.time < 8 {
                last.text += " " + l.text; merged[merged.count - 1] = last
            } else { merged.append(l) }
        }
        let transcript = merged.map { "**\($0.speaker)** (\(MeetingSession.stamp($0.time))): \($0.text)" }.joined(separator: "\n\n")
        let words = merged.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }

        progress("Writing notes…")
        let notes = words < 25 ? "_Too little speech to summarise._" : await MeetingNotes.write(transcript: transcript, settings: settings)

        let df = DateFormatter(); df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var md = "# \(title)\n\n"
        md += "- **When:** \(df.string(from: started))\n- **Length:** \(MeetingSession.stamp(duration))\n- **Speakers:** \(me) (microphone), \(them) (the call)\n- **Recorded on this Mac by Speakhold.** Audio was transcribed locally and discarded.\n\n"
        md += "## Notes\n\n\(notes)\n\n## Transcript\n\n\(transcript.isEmpty ? "_Nothing recognised._" : transcript)\n"

        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = MeetingSession.folder.appendingPathComponent(safe + ".md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Notes from a transcript: Claude when a key is set (long transcripts need its context), otherwise Apple's
/// on-device model over the most recent part of the transcript it can hold.
enum MeetingNotes {
    static let brief = """
    You write meeting notes for a small software agency from a transcript. Speakers are labelled as given; "Them" is everyone on the other side of the call. Output markdown with exactly these sections:

    ### Summary
    Three to six bullets. What the meeting was about and where it landed.

    ### Decisions
    Bullets. Choices made about direction or approach, not tasks. Only decisions actually made. "None recorded." if none.

    ### Action items
    One bullet per commitment, the person's name in bold then the task, e.g. "- **Brandon**: open the pull request this afternoon". Use the speaker's name as given in the transcript; if "Them" speaks, use the name they are addressed by when the transcript makes it clear, otherwise "Them". Only commitments actually made. "None recorded." if none.

    ### Open questions
    Bullets. Things raised and not resolved. "None." if none.

    Use only what is in the transcript. Never invent names, numbers or dates. Keep the speakers' wording for anything quoted. No preamble, no closing line.
    """

    static func write(transcript: String, settings s: Settings) async -> String {
        if !s.anthropicKey.isEmpty {
            if let out = await ClaudeClient(apiKey: s.anthropicKey, model: s.cleanupModel)
                .complete(system: brief, user: transcript, maxTokens: 2000, effort: "medium", timeout: 90) {
                return out
            }
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), Polish.appleAvailable {
            // The on-device model holds about 4k tokens: take the tail of a long transcript and say so.
            let words = transcript.split(separator: " ")
            let limit = 1800
            let clipped = words.count > limit
            let text = clipped ? words.suffix(limit).joined(separator: " ") : transcript
            if let out = await AppleNotes.write(brief: brief, transcript: text) {
                return (clipped ? "_Notes cover the last part of a long meeting (on-device model limit); set a Claude key under Cleanup for the whole thing._\n\n" : "") + out
            }
        }
        #endif
        return "_No notes engine available: set a Claude key under Settings → Cleanup, or turn on Apple Intelligence._"
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum AppleNotes {
    static func write(brief: String, transcript: String) async -> String? {
        let session = LanguageModelSession(instructions: brief)
        do {
            let r = try await session.respond(to: "Transcript:\n\n" + transcript, options: GenerationOptions(temperature: 0))
            let out = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        } catch {
            NSLog("Speakhold: Apple notes failed: %@", error.localizedDescription)
            return nil
        }
    }
}
#endif
