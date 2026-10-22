import AppKit
import EventKit
import Foundation

/// A transcription engine for long recordings. Whisper is the default (already loaded for dictation); Parakeet is
/// the faster option in `MeetingASR.swift`.
protocol MeetingTranscriber {
    func segments(_ samples: [Float], language: String, promptTerms: [String]) async throws -> [Transcriber.Segment]
}

struct WhisperMeetingTranscriber: MeetingTranscriber {
    let transcriber: Transcriber
    func segments(_ samples: [Float], language: String, promptTerms: [String]) async throws -> [Transcriber.Segment] {
        try await transcriber.transcribeSegments(samples, language: language, promptTerms: promptTerms)
    }
}

/// Who spoke when on the far side. Supplied by `MeetingDiarizer` (FluidAudio); nil means everyone is "Them".
struct SpeakerTurn { var speaker: Int; var start: Double; var end: Double }
protocol MeetingDiarizer {
    func turns(_ samples: [Float]) async throws -> [SpeakerTurn]
}

/// Live state the meeting-notes window binds to. Mutated on the main thread only.
final class MeetingState: ObservableObject {
    @Published var active = false
    @Published var title = ""
    @Published var attendees: [String] = []
    @Published var elapsedLabel = "0:00"
    @Published var notes = ""
    @Published var marks: [TimeInterval] = []
    @Published var catchUp = ""
    @Published var catchingUp = false
    @Published var status = ""
    /// Set by the app: stop & write, mark a moment, catch me up.
    var onStop: (() -> Void)?
    var onMark: (() -> Void)?
    var onCatchUp: (() -> Void)?
}

/// One recorded meeting: both sides captured on this Mac, transcribed on the Neural Engine, written as one
/// markdown file. Nothing leaves the machine unless Claude is the notes engine, and then only text.
@available(macOS 14.2, *)
final class MeetingSession {
    let capture = MeetingCapture()
    let started = Date()
    var title: String
    var attendees: [String] = []
    var calendarTitle: String?
    var marks: [TimeInterval] = []
    var userNotes = ""

    static var folder: URL {
        let custom = Settings.shared.meetingsFolder
        let dir = custom.isEmpty
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Speakhold Meetings")
            : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(title: String? = nil) {
        self.title = title ?? "Meeting \(Self.shortDate(Date()))"
    }

    func start() throws { try capture.start() }

    var elapsed: TimeInterval { Date().timeIntervalSince(started) }
    var elapsedLabel: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func mark() { marks.append(elapsed) }

    /// Fill title + attendees from the calendar event happening now, if the user allows it.
    func adoptCalendar() async {
        guard let ev = await MeetingCalendar.current() else { return }
        calendarTitle = ev.title
        if !ev.title.isEmpty { title = ev.title + " " + Self.shortDate(started) }
        attendees = ev.attendees
    }

    static func shortDate(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"; return f.string(from: d) }

    struct Line { var time: Double; var speaker: String; var text: String }

    /// "Catch me up": the last couple of minutes of both streams as text.
    func catchUp(transcriber: Transcriber, settings: Settings, seconds: Double = 120) async -> String {
        let r = capture.recent(seconds: seconds)
        let me = Self.myName
        var lines: [Line] = []
        let offset = max(0, capture.seconds - seconds)
        if let mine = try? await transcriber.transcribeSegments(r.mic, language: settings.language, promptTerms: settings.dictionaryTerms) {
            lines += mine.map { Line(time: offset + $0.start, speaker: me, text: $0.text) }
        }
        if let theirs = try? await transcriber.transcribeSegments(r.system, language: settings.language, promptTerms: settings.dictionaryTerms) {
            lines += theirs.map { Line(time: offset + $0.start, speaker: "Them", text: $0.text) }
        }
        lines.sort { $0.time < $1.time }
        return lines.isEmpty ? "Nothing said in the last \(Int(seconds / 60)) minutes." : Self.merge(lines).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
    }

    static var myName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me" }

    static func merge(_ lines: [Line], gap: Double = 8) -> [Line] {
        var merged: [Line] = []
        for l in lines {
            if var last = merged.last, last.speaker == l.speaker, l.time - last.time < gap {
                last.text += " " + l.text; merged[merged.count - 1] = last
            } else { merged.append(l) }
        }
        return merged
    }

    /// Stop capturing, transcribe both streams, diarise the far side, write notes + transcript, return the file.
    func finish(transcriber: MeetingTranscriber, diarizer: MeetingDiarizer?, settings: Settings, progress: @escaping (String) -> Void) async throws -> URL {
        capture.stop()
        if capture.mic.isEmpty && capture.system.isEmpty { capture.loadFromDisk() }
        defer { capture.discard() }
        let duration = Double(max(capture.mic.count, capture.system.count)) / 16_000
        let me = Self.myName

        progress("Transcribing your side…")
        let mine = try await transcriber.segments(capture.mic, language: settings.language, promptTerms: settings.dictionaryTerms)
        progress("Transcribing the other side…")
        let theirs = try await transcriber.segments(capture.system, language: settings.language, promptTerms: settings.dictionaryTerms)

        // Far-side speakers: label each segment by the diarisation turn it overlaps most.
        var turns: [SpeakerTurn] = []
        if let diarizer, settings.meetingDiarise, !theirs.isEmpty {
            progress("Telling the other voices apart…")
            do { turns = try await diarizer.turns(capture.system) } catch { NSLog("Speakhold: diarisation failed: %@", error.localizedDescription) }
        }
        var order: [Int] = []   // speaker ids in order of first appearance → "Speaker 1", "Speaker 2"…
        func label(_ seg: Transcriber.Segment) -> String {
            guard !turns.isEmpty else { return "Them" }
            var best: (id: Int, overlap: Double)? = nil
            for t in turns {
                let o = min(seg.end, t.end) - max(seg.start, t.start)
                if o > 0, o > (best?.overlap ?? 0) { best = (t.speaker, o) }
            }
            guard let id = best?.id else { return "Them" }
            if !order.contains(id) { order.append(id) }
            return "Speaker \(order.firstIndex(of: id)! + 1)"
        }

        var lines = mine.map { Line(time: $0.start, speaker: me, text: $0.text) } + theirs.map { Line(time: $0.start, speaker: label($0), text: $0.text) }
        lines.sort { $0.time < $1.time }
        let merged = Self.merge(lines)
        let transcript = merged.map { "**\($0.speaker)** (\(Self.stamp($0.time))): \($0.text)" }.joined(separator: "\n\n")
        let words = merged.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }

        // Marked moments: the transcript around each mark.
        var marked = ""
        for m in marks {
            let around = merged.filter { abs($0.time - m) < 25 }.map { "\($0.speaker): \($0.text)" }.joined(separator: " ")
            marked += "- **\(Self.stamp(m))**: \(around.isEmpty ? "_(nothing transcribed near this moment)_" : around)\n"
        }

        progress("Writing notes…")
        let notes = words < 25 ? "_Too little speech to summarise._"
            : await MeetingNotes.write(transcript: transcript, userNotes: userNotes, marked: marked, settings: settings)
        var followUp = ""
        if settings.meetingFollowUp, words >= 25 {
            progress("Drafting the follow-up…")
            followUp = await MeetingNotes.followUp(notes: notes, me: me, settings: settings)
        }

        let df = DateFormatter(); df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var speakers = "\(me) (microphone)"
        speakers += order.isEmpty ? ", Them (the call)" : ", " + order.indices.map { "Speaker \($0 + 1)" }.joined(separator: ", ") + " (the call)"
        var md = "# \(title)\n\n"
        md += "- **When:** \(df.string(from: started))\n- **Length:** \(Self.stamp(duration))\n"
        if let calendarTitle, !calendarTitle.isEmpty { md += "- **Calendar event:** \(calendarTitle)\n" }
        if !attendees.isEmpty { md += "- **Invited:** \(attendees.joined(separator: ", "))\n" }
        md += "- **Speakers:** \(speakers)"
        if !order.isEmpty { md += ". Speaker numbers are voices told apart on the call; rename them from the invite list." }
        md += "\n- **Recorded on this Mac by Speakhold.** Audio was transcribed locally and discarded.\n\n"
        if !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "## Your notes\n\n\(userNotes.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        if !marked.isEmpty { md += "## Marked moments\n\n\(marked)\n" }
        md += "## Notes\n\n\(notes)\n\n"
        if !followUp.isEmpty { md += "## Follow-up draft\n\n\(followUp)\n\n" }
        md += "## Transcript\n\n\(transcript.isEmpty ? "_Nothing recognised._" : transcript)\n"

        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        var url = Self.folder.appendingPathComponent(safe + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = Self.folder.appendingPathComponent("\(safe) (\(n)).md"); n += 1 }
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The calendar event happening now: title and attendee names. Read-only; asks for calendar access once.
enum MeetingCalendar {
    struct Event { var title: String; var attendees: [String] }

    static func current() async -> Event? {
        guard Settings.shared.meetingCalendar else { return nil }
        let store = EKEventStore()
        let ok: Bool
        if #available(macOS 14.0, *) { ok = (try? await store.requestFullAccessToEvents()) ?? false }
        else { ok = (try? await store.requestAccess(to: .event)) ?? false }
        guard ok else { return nil }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-45 * 60), end: now.addingTimeInterval(15 * 60), calendars: nil)
        let events = store.events(matching: pred).filter { !$0.isAllDay }
        let pick = events.first { $0.startDate <= now && $0.endDate >= now } ?? events.min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
        guard let ev = pick else { return nil }
        let names = (ev.attendees ?? []).compactMap { $0.name }.filter { !$0.contains("@") }
        return Event(title: ev.title ?? "", attendees: names)
    }
}

/// Notes from a transcript: Claude when a key is set (long transcripts need its context), otherwise Apple's
/// on-device model over the most recent part of the transcript it can hold.
enum MeetingNotes {
    static let brief = """
    You write meeting notes for a small software agency from a transcript. Speakers are labelled as given; "Them" or "Speaker N" are people on the other side of the call. Output markdown with exactly these sections:

    ### Summary
    Three to six bullets. What the meeting was about and where it landed.

    ### Decisions
    Bullets. Choices made about direction or approach, not tasks. Only decisions actually made. "None recorded." if none.

    ### Action items
    One bullet per commitment, the person's name in bold then the task, e.g. "- **Brandon**: open the pull request this afternoon". Use the speaker's name as given; if a speaker is addressed by name in the transcript, use that name. Only commitments actually made. "None recorded." if none.

    ### Open questions
    Bullets. Things raised and not resolved. "None." if none.

    Use only what is in the transcript and the speaker's own notes. Never invent names, numbers or dates. Keep the speakers' wording for anything quoted. No preamble, no closing line.
    """

    static func write(transcript: String, userNotes: String, marked: String, settings s: Settings) async -> String {
        var user = ""
        if !userNotes.trimmingCharacters(in: .whitespaces).isEmpty {
            user += "The speaker's own notes, typed during the meeting. They know what mattered: expand and correct them from the transcript, keep their order and wording where it holds, and fold anything they flagged into Summary / Decisions / Action items:\n\n\(userNotes)\n\n"
        }
        if !marked.isEmpty { user += "Moments the speaker flagged as important:\n\n\(marked)\n\n" }
        user += "Transcript:\n\n" + transcript
        if !s.anthropicKey.isEmpty {
            if let out = await ClaudeClient(apiKey: s.anthropicKey, model: s.cleanupModel)
                .complete(system: brief, user: user, maxTokens: 2500, effort: "medium", timeout: 120) {
                return out
            }
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), Polish.appleAvailable {
            let words = user.split(separator: " ")
            let limit = 1800
            let clipped = words.count > limit
            let text = clipped ? words.suffix(limit).joined(separator: " ") : user
            if let out = await AppleNotes.write(brief: brief, user: text) {
                return (clipped ? "_Notes cover the last part of a long meeting (on-device model limit); set a Claude key under Cleanup for the whole thing._\n\n" : "") + out
            }
        }
        #endif
        return "_No notes engine available: set a Claude key under Settings → Cleanup, or turn on Apple Intelligence._"
    }

    static let followUpBrief = """
    Draft a short follow-up email from the meeting notes, written by the person named as the sender, to the other people in the meeting. Plain, friendly, no fluff: one line of thanks, what was agreed, who is doing what by when, one question if something is open. Under 150 words. Output only the email body, starting with a greeting line.
    """

    static func followUp(notes: String, me: String, settings s: Settings) async -> String {
        let user = "Sender: \(me)\n\nNotes:\n\n\(notes)"
        if !s.anthropicKey.isEmpty, let out = await ClaudeClient(apiKey: s.anthropicKey, model: s.cleanupModel).complete(system: followUpBrief, user: user, maxTokens: 600, effort: "low", timeout: 60) {
            return out
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), Polish.appleAvailable, let out = await AppleNotes.write(brief: followUpBrief, user: user) { return out }
        #endif
        return ""
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum AppleNotes {
    static func write(brief: String, user: String) async -> String? {
        let session = LanguageModelSession(instructions: brief)
        do {
            let r = try await session.respond(to: user, options: GenerationOptions(temperature: 0))
            let out = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        } catch {
            NSLog("Speakhold: Apple notes failed: %@", error.localizedDescription)
            return nil
        }
    }
}
#endif
