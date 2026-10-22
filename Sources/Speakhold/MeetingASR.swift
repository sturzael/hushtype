import FluidAudio
import Foundation

/// Parakeet (NVIDIA, CoreML via FluidAudio): much faster than Whisper on long recordings, English-first.
/// Models download on first use (~600 MB) into FluidAudio's cache. Speech regions are found the same way as
/// for Whisper, so segment times stay absolute and silence is never decoded.
actor ParakeetMeetingTranscriber: MeetingTranscriber {
    private var manager: UnifiedAsrManager?
    private(set) var status = "Not loaded"

    func prepare(progress: ((String) -> Void)? = nil) async throws {
        if manager != nil { return }
        status = "Downloading Parakeet…"; progress?(status)
        let m = UnifiedAsrManager()
        try await m.loadModels()
        manager = m
        status = "Ready"; progress?(status)
    }

    func segments(_ samples: [Float], language: String, promptTerms: [String]) async throws -> [Transcriber.Segment] {
        try await prepare()
        guard let manager else { return [] }
        var out: [Transcriber.Segment] = []
        for region in Transcriber.speechRegions(samples) {
            var audio = Array(samples[region])
            if audio.count < 16_000 { audio.append(contentsOf: [Float](repeating: 0, count: 16_000 - audio.count)) }
            let text = try await manager.transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(Transcriber.Segment(start: Double(region.lowerBound) / 16_000, end: Double(region.upperBound) / 16_000, text: text))
        }
        return out
    }
}

/// Offline speaker diarisation (pyannote community pipeline on CoreML, via FluidAudio). Models download on
/// first use. Returns turns with integer speaker ids.
actor FluidMeetingDiarizer: MeetingDiarizer {
    private var manager: OfflineDiarizerManager?

    func prepare() async throws {
        if manager != nil { return }
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels()
        manager = m
    }

    func turns(_ samples: [Float]) async throws -> [SpeakerTurn] {
        try await prepare()
        guard let manager, samples.count >= 16_000 * 2 else { return [] }
        let result = try await manager.process(audio: samples)
        var ids: [String: Int] = [:]
        return result.segments.map { seg in
            if ids[seg.speakerId] == nil { ids[seg.speakerId] = ids.count + 1 }
            return SpeakerTurn(speaker: ids[seg.speakerId]!, start: Double(seg.startTimeSeconds), end: Double(seg.endTimeSeconds))
        }
    }
}
