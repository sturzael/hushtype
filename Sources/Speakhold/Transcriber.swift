import Foundation
import WhisperKit

/// Wraps WhisperKit: downloads the model on first use, then transcribes 16 kHz float samples.
actor Transcriber {
    enum State: Equatable { case idle, downloading(Double), loading, ready, failed(String) }

    private var kit: WhisperKit?
    private var loadedModel: String?
    private(set) var state: State = .idle
    private var onState: (@Sendable (State) -> Void)?
    func setStateHandler(_ h: @escaping @Sendable (State) -> Void) { onState = h; h(state) }

    private func set(_ s: State) { state = s; onState?(s) }

    func prepare(model: String) async {
        if kit != nil, loadedModel == model { return }
        kit = nil
        set(.downloading(0))
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Speakhold/models")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let folder = try await WhisperKit.download(
                variant: model,
                downloadBase: base,
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml",
                token: nil,
                progressCallback: { [weak self] p in
                    guard let self else { return }
                    Task { await self.set(.downloading(p.fractionCompleted)) }
                }
            )
            set(.loading)
            // Keep the tokenizer next to the model: WhisperKit's default is ~/Documents/huggingface, which
            // needs the Files & Folders permission for a bundled app and fails with "could not remove corrupted metadata".
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: base,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            kit = try await WhisperKit(config)
            loadedModel = model
            set(.ready)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    /// `fast` is the live preview while recording: no temperature fallback, so a tick costs one decoder pass.
    /// Dictation calls in flight. A background meeting pass waits between regions while this is non-zero, so a
    /// hold-to-talk never queues behind a twenty-minute recording.
    private var dictating = 0

    func transcribe(_ samples: [Float], language: String, promptTerms: [String], fast: Bool = false) async throws -> String {
        guard let kit else { throw NSError(domain: "Speakhold", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded yet."]) }
        dictating += 1
        defer { dictating -= 1 }
        // Whisper needs at least ~1 s; pad very short clips with silence.
        var audio = samples
        if audio.count < 16_000 { audio.append(contentsOf: [Float](repeating: 0, count: 16_000 - audio.count)) }

        let env = ProcessInfo.processInfo.environment
        var options = DecodingOptions()
        options.language = language.isEmpty ? nil : language
        options.detectLanguage = language.isEmpty
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.temperatureFallbackCount = fast ? 0 : 2
        options.chunkingStrategy = .vad
        // Bias the decoder toward names it would otherwise mangle.
        if env["DICTATE_NO_PROMPT"] == nil, !promptTerms.isEmpty, let tok = kit.tokenizer {
            let prompt = " " + promptTerms.joined(separator: ", ") + "."
            options.promptTokens = tok.encode(text: prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
        }
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        if env["DICTATE_DEBUG"] != nil { NSLog("DEBUG samples=%d results=%d segs=%d text=%@", audio.count, results.count, results.first?.segments.count ?? 0, text) }
        return Transcriber.tidy(text)
    }

    struct Segment: Sendable { var start: Double; var end: Double; var text: String }

    /// Timestamped segments for long recordings (meetings). Speech regions are found first with an energy gate,
    /// each region is decoded on its own and its offset added back, so times stay absolute. Whisper reports a
    /// leading-silence segment as starting at 0 and VAD chunking resets times per chunk, so neither can be trusted alone.
    /// `progress` is the fraction of speech decoded so far (0–1), by samples, so long regions weigh what they cost.
    func transcribeSegments(_ samples: [Float], language: String, promptTerms: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Segment] {
        guard let kit else { throw NSError(domain: "Speakhold", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded yet."]) }
        var options = DecodingOptions()
        options.language = language.isEmpty ? nil : language
        options.detectLanguage = language.isEmpty
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.temperatureFallbackCount = 2
        options.chunkingStrategy = .none
        if !promptTerms.isEmpty, let tok = kit.tokenizer {
            let prompt = " " + promptTerms.joined(separator: ", ") + "."
            options.promptTokens = tok.encode(text: prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
        }
        var out: [Segment] = []
        let regions = Transcriber.speechRegions(samples)
        let total = max(1, regions.reduce(0) { $0 + $1.count })
        var done = 0
        for region in regions {
            while dictating > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
            var audio = Array(samples[region])
            if audio.count < 16_000 { audio.append(contentsOf: [Float](repeating: 0, count: 16_000 - audio.count)) }
            let offset = Double(region.lowerBound) / 16_000
            let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
            done += region.count
            progress?(Double(done) / Double(total))
            for r in results {
                for seg in r.segments {
                    let text = Transcriber.tidy(seg.text)
                    guard !text.isEmpty, seg.noSpeechProb < 0.8 else { continue }
                    out.append(Segment(start: offset + Double(seg.start), end: offset + Double(seg.end), text: text))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Energy gate: 20 ms frames, threshold a few times the quietest fifth of the recording, regions merged across
    /// gaps under 0.8 s and padded by 0.25 s. Cheap, and it also means silence is never sent to the decoder.
    static func speechRegions(_ samples: [Float]) -> [Range<Int>] {
        let frame = 320, rate = 16_000
        guard samples.count >= frame else { return samples.isEmpty ? [] : [0..<samples.count] }
        let n = samples.count / frame
        var rms = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for j in 0..<frame { let v = samples[i * frame + j]; acc += v * v }
            rms[i] = (acc / Float(frame)).squareRoot()
        }
        let sorted = rms.sorted()
        let floor = sorted[sorted.count / 5]
        let threshold = max(floor * 4, 0.006)
        var regions: [Range<Int>] = []
        var start: Int? = nil
        var silent = 0
        let maxGap = Int(0.8 * Double(rate)) / frame, pad = Int(0.25 * Double(rate))
        for i in 0..<n {
            if rms[i] >= threshold {
                if start == nil { start = i }
                silent = 0
            } else if let s = start {
                silent += 1
                if silent > maxGap {
                    regions.append(max(0, s * frame - pad)..<min(samples.count, (i - silent) * frame + pad))
                    start = nil; silent = 0
                }
            }
        }
        if let s = start { regions.append(max(0, s * frame - pad)..<samples.count) }
        return regions.filter { $0.count >= rate / 2 }
    }

    /// Test hook: transcribe an audio file on disk (any format AVFoundation reads).
    func transcribeFile(_ path: String, language: String, promptTerms: [String]) async throws -> String {
        guard let kit else { throw NSError(domain: "Speakhold", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded yet."]) }
        let buffer = try AudioProcessor.loadAudio(fromPath: path)
        let samples = AudioProcessor.convertBufferToArray(buffer: buffer)
        return try await transcribe(samples, language: language, promptTerms: promptTerms)
    }

    /// Whisper's raw output has doubled spaces and the occasional hallucinated tag; squash them.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
