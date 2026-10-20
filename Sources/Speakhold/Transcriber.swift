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
    func transcribe(_ samples: [Float], language: String, promptTerms: [String], fast: Bool = false) async throws -> String {
        guard let kit else { throw NSError(domain: "Speakhold", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded yet."]) }
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
