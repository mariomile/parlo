@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

enum RecorderError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "No microphone available" }
}

/// Thread-safe sample accumulator written from the audio thread.
nonisolated final class SampleSink: Sendable {
    private let state = Mutex<(samples: [Float], level: Float)>(([], 0))

    func reset() {
        state.withLock { $0 = ([], 0) }
    }

    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()
        state.withLock {
            $0.samples.append(contentsOf: chunk)
            $0.level = rms
        }
    }

    var level: Float { state.withLock { $0.level } }

    func drain() -> [Float] {
        state.withLock { s in
            defer { s = ([], 0) }
            return s.samples
        }
    }
}

/// Captures the microphone as 16 kHz mono Float32, the format every engine expects.
final class AudioRecorder {
    nonisolated static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var engine: AVAudioEngine?
    private let sink = SampleSink()

    /// RMS of the latest buffer, 0...~1.
    var level: Float { sink.level }

    func start(deviceUID: String?) throws {
        _ = stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let deviceID = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        sink.reset()
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(from: format, sink: sink))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops capture and returns everything recorded since `start`.
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        return sink.drain()
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func makeTap(from format: AVAudioFormat, sink: SampleSink) -> AVAudioNodeTapBlock {
        let converter = AVAudioConverter(from: format, to: targetFormat)
        let ratio = targetFormat.sampleRate / format.sampleRate
        return { buffer, _ in
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData else { return }
            sink.append(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
        }
    }
}

/// Input devices via Core Audio.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: String // UID
        let name: String
    }

    static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
