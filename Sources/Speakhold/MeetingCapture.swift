import AVFoundation
import CoreAudio
import Foundation

/// Records both sides of a call: everything the Mac is playing (a Core Audio process tap, macOS 14.2+, behind the
/// "System Audio Recording Only" permission, no virtual driver needed) and the microphone, as two separate
/// 16 kHz mono streams. The foundation for a meetings mode; `--record-meeting` exercises it headless.
@available(macOS 14.2, *)
final class MeetingCapture {
    private(set) var system: [Float] = []
    private(set) var mic: [Float] = []
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var sysConverter: AVAudioConverter?
    private let engine = AVAudioEngine()
    private var micConverter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    enum CaptureError: LocalizedError {
        case tap(OSStatus), aggregate(OSStatus), format(OSStatus), ioProc(OSStatus), start(OSStatus)
        var errorDescription: String? {
            switch self {
            case .tap(let e): return "process tap failed (\(e))"
            case .aggregate(let e): return "aggregate device failed (\(e))"
            case .format(let e): return "tap format failed (\(e))"
            case .ioProc(let e): return "IO proc failed (\(e))"
            case .start(let e): return "device start failed (\(e))"
            }
        }
    }

    /// Sample rate and channels the tap delivers, for diagnostics.
    private(set) var tapDescription = ""

    func start() throws {
        // 1. System audio: a global mono tap over every process's output.
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.name = "Speakhold meeting"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CaptureError.tap(err) }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Speakhold meeting tap",
            kAudioAggregateDeviceUIDKey: "co.wildinteractive.speakhold.meetingtap",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard err == noErr else { throw CaptureError.aggregate(err) }

        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.format(err) }
        tapFormat = fmt
        tapDescription = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch"
        sysConverter = AVAudioConverter(from: fmt, to: target)

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, inData, _, _, _ in
            self?.ingestSystem(inData)
        }
        guard err == noErr else { throw CaptureError.ioProc(err) }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { throw CaptureError.start(err) }

        // 2. Microphone.
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        micConverter = AVAudioConverter(from: micFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buf, _ in
            guard let self, let conv = self.micConverter else { return }
            if let out = self.convert(buf, with: conv) { self.lock.lock(); self.mic.append(contentsOf: out); self.lock.unlock() }
        }
        try engine.start()
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        procID = nil; aggID = kAudioObjectUnknown; tapID = kAudioObjectUnknown
    }

    private func ingestSystem(_ inData: UnsafePointer<AudioBufferList>) {
        guard let fmt = tapFormat, let conv = sysConverter else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = abl.first, first.mDataByteSize > 0 else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize) / fmt.streamDescription.pointee.mBytesPerFrame
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil) else { return }
        inBuf.frameLength = frames
        if let out = convert(inBuf, with: conv) { lock.lock(); system.append(contentsOf: out); lock.unlock() }
    }

    private func convert(_ buf: AVAudioPCMBuffer, with conv: AVAudioConverter) -> [Float]? {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Test hook: stand in for a recording with two files on disk (any format AVFoundation reads).
    func load(micPath: String, systemPath: String) {
        mic = MeetingCapture.samples(fromFile: micPath)
        system = MeetingCapture.samples(fromFile: systemPath)
    }

    static func samples(fromFile path: String) -> [Float] {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return [] }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: inBuf)) != nil else { return [] }
        if file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: Int(inBuf.frameLength)))
        }
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate) + 16) else { return [] }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func writeWAV(_ samples: [Float], to path: String) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in if let b = p.baseAddress { buf.floatChannelData![0].update(from: b, count: samples.count) } }
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
        try file.write(from: buf)
    }
}
