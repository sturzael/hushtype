import AVFoundation
import CoreAudio
import Foundation

/// Captures the default microphone as 16 kHz mono Float32, which is what Whisper wants.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Called on the audio thread with a 0...1 level, throttled by the caller.
    var levelHandler: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Device UID to capture from; empty string means the system default input.
    var inputDeviceUID: String = ""

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        if !inputDeviceUID.isEmpty, let devID = AudioDevices.deviceID(forUID: inputDeviceUID), let unit = input.audioUnit {
            var id = devID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { NSLog("Speakhold: could not select input device (%d), using default", status) }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "Speakhold", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns the captured 16 kHz samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func handle(buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: n))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()

        if n > 0 {
            var sum: Float = 0
            for s in chunk { sum += s * s }
            let rms = (sum / Float(n)).squareRoot()
            // Map RMS to a pleasant 0...1 curve for the waveform.
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50))
            levelHandler?(level)
        }
    }
}
