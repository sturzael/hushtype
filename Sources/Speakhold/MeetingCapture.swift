import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Records both sides of a call: everything the Mac is playing (a Core Audio process tap, macOS 14.2+, behind the
/// "System Audio Recording Only" permission, no virtual driver needed) and the microphone, as two separate
/// 16 kHz mono streams. Audio streams to two temp files so a three-hour meeting costs no memory; a short ring of
/// the most recent audio stays in memory for "catch me up".
@available(macOS 14.2, *)
final class MeetingCapture {
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "co.wildinteractive.speakhold.meeting-write")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var sysConverter: AVAudioConverter?
    private let engine = AVAudioEngine()
    private var micConverter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private(set) var tempDir: URL?
    private var micFile: AVAudioFile?
    private var sysFile: AVAudioFile?
    private(set) var micFrames = 0
    private(set) var sysFrames = 0

    /// Rolling tail of each stream, for catch-me-up. 3 minutes.
    private let ringLength = 16_000 * 180
    private var micRing: [Float] = []
    private var sysRing: [Float] = []

    /// Loaded from disk by `loadFromDisk` (or set directly by the file-based test hook).
    var mic: [Float] = []
    var system: [Float] = []

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

    private(set) var tapDescription = ""

    func start() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speakhold-meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        micFile = try AVAudioFile(forWriting: dir.appendingPathComponent("mic.wav"), settings: target.settings)
        sysFile = try AVAudioFile(forWriting: dir.appendingPathComponent("system.wav"), settings: target.settings)

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
            if let out = self.convert(buf, with: conv) { self.append(out, mic: true) }
        }
        try engine.start()
    }

    /// Stop the hardware; the files stay until `discard()`.
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
        writeQueue.sync { micFile = nil; sysFile = nil }   // flush + close
    }

    /// Read both streams back from disk into `mic` / `system`.
    func loadFromDisk() {
        guard let dir = tempDir else { return }
        mic = MeetingCapture.samples(fromFile: dir.appendingPathComponent("mic.wav").path)
        system = MeetingCapture.samples(fromFile: dir.appendingPathComponent("system.wav").path)
    }

    /// Delete the temp recording. Audio never outlives the notes.
    func discard() {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        mic = []; system = []
        lock.lock(); micRing = []; sysRing = []; lock.unlock()
    }

    /// The most recent `seconds` of each stream, for catch-me-up.
    func recent(seconds: Double) -> (mic: [Float], system: [Float]) {
        let n = Int(seconds * 16_000)
        lock.lock(); defer { lock.unlock() }
        return (Array(micRing.suffix(n)), Array(sysRing.suffix(n)))
    }

    var seconds: Double { Double(max(micFrames, sysFrames)) / 16_000 }

    private func append(_ out: [Float], mic isMic: Bool) {
        lock.lock()
        if isMic {
            micRing.append(contentsOf: out); if micRing.count > ringLength { micRing.removeFirst(micRing.count - ringLength) }
            micFrames += out.count
        } else {
            sysRing.append(contentsOf: out); if sysRing.count > ringLength { sysRing.removeFirst(sysRing.count - ringLength) }
            sysFrames += out.count
        }
        lock.unlock()
        writeQueue.async { [weak self] in
            guard let self, let file = isMic ? self.micFile : self.sysFile,
                  let buf = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: AVAudioFrameCount(out.count)) else { return }
            buf.frameLength = AVAudioFrameCount(out.count)
            out.withUnsafeBufferPointer { p in if let b = p.baseAddress { buf.floatChannelData![0].update(from: b, count: out.count) } }
            try? file.write(from: buf)
        }
    }

    private func ingestSystem(_ inData: UnsafePointer<AudioBufferList>) {
        guard let fmt = tapFormat, let conv = sysConverter else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = abl.first, first.mDataByteSize > 0 else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize) / fmt.streamDescription.pointee.mBytesPerFrame
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil) else { return }
        inBuf.frameLength = frames
        if let out = convert(inBuf, with: conv) { append(out, mic: false) }
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
        micFrames = mic.count; sysFrames = system.count
        lock.lock(); micRing = Array(mic.suffix(ringLength)); sysRing = Array(system.suffix(ringLength)); lock.unlock()
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

/// Is anyone on a call? A process that has the microphone open is the signal (Zoom, Meet in a browser, Teams,
/// FaceTime, Slack huddles). Core Audio exposes it per process on macOS 14.2+, no polling of window titles.
@available(macOS 14.2, *)
enum CallDetector {
    struct Call { var pid: pid_t; var name: String }

    static func activeCalls() -> [Call] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var calls: [Call] = []
        for id in ids {
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var paddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &paddr, 0, nil, &psize, &pid) == noErr, pid != me else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "an app"
            calls.append(Call(pid: pid, name: name))
        }
        return calls
    }
}
