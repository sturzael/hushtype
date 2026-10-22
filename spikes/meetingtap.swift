// Spike: can a plain Swift CLI record BOTH sides of a call on macOS without BlackHole?
// System audio via a Core Audio process tap (macOS 14.2+, "System Audio Recording Only" permission),
// the microphone via AVAudioEngine. Writes two 16 kHz mono WAVs for `seconds`, then exits.
//   swiftc -O meetingtap.swift -o meetingtap && ./meetingtap 10 /tmp/out
import AVFoundation
import CoreAudio
import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let outDir = CommandLine.arguments.dropFirst(2).first ?? "/tmp/meetingtap"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func wav(_ samples: [Float], to path: String) {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try! AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
    try! file.write(from: buf)
    print("wrote", path, String(format: "%.1fs", Double(samples.count) / 16_000))
}

// ---- 1. System audio: a global tap over every process's output, mixed to mono.
var sysSamples: [Float] = []
let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
tapDesc.name = "meetingtap"
tapDesc.isPrivate = true
tapDesc.muteBehavior = .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard err == noErr else { print("process tap failed:", err, "(permission denied shows as", kAudioHardwareIllegalOperationError, ")"); exit(1) }
print("process tap created", tapID)

// Wrap the tap in an aggregate device so we can read it with a normal IOProc.
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "meetingtap-agg",
    kAudioAggregateDeviceUIDKey: "co.wildinteractive.meetingtap.agg",
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDesc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard err == noErr else { print("aggregate device failed:", err); exit(1) }

// Tap stream format (so we can convert to 16 kHz mono).
var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var asbd = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
guard err == noErr else { print("tap format failed:", err); exit(1) }
print("tap format:", asbd.mSampleRate, "Hz", asbd.mChannelsPerFrame, "ch")
let tapFormat = AVAudioFormat(streamDescription: &asbd)!
let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let sysConverter = AVAudioConverter(from: tapFormat, to: target)!

var procID: AudioDeviceIOProcID?
err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard let first = abl.first, first.mDataByteSize > 0 else { return }
    let frames = AVAudioFrameCount(first.mDataByteSize) / (tapFormat.streamDescription.pointee.mBytesPerFrame)
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inData, deallocator: nil) else { return }
    inBuf.frameLength = frames
    let outCap = AVAudioFrameCount(Double(frames) * 16_000 / tapFormat.sampleRate) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
    var consumed = false
    var cerr: NSError?
    sysConverter.convert(to: out, error: &cerr) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true; status.pointee = .haveData; return inBuf
    }
    if out.frameLength > 0 { sysSamples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))) }
}
guard err == noErr else { print("ioproc failed:", err); exit(1) }
err = AudioDeviceStart(aggID, procID)
guard err == noErr else { print("device start failed:", err); exit(1) }
print("system audio: recording")

// ---- 2. Microphone through AVAudioEngine.
var micSamples: [Float] = []
let engine = AVAudioEngine()
let input = engine.inputNode
let micFormat = input.outputFormat(forBus: 0)
let micConverter = AVAudioConverter(from: micFormat, to: target)!
input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buf, _ in
    let outCap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / micFormat.sampleRate) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
    var consumed = false
    var cerr: NSError?
    micConverter.convert(to: out, error: &cerr) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true; status.pointee = .haveData; return buf
    }
    if out.frameLength > 0 { micSamples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))) }
}
do { try engine.start(); print("microphone: recording") } catch { print("mic failed:", error) }

RunLoop.main.run(until: Date().addingTimeInterval(seconds))

AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
engine.stop()
let sysPeak = sysSamples.map(abs).max() ?? 0, micPeak = micSamples.map(abs).max() ?? 0
print(String(format: "system peak %.2f, mic peak %.2f", sysPeak, micPeak))
wav(sysSamples, to: outDir + "/system.wav")
wav(micSamples, to: outDir + "/mic.wav")
