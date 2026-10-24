@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

enum RecorderError: LocalizedError {
    case noMicrophone
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone available"
        case .unsupportedFormat: "This microphone's audio format isn't supported"
        }
    }
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

    /// The last `count` samples captured, without stopping.
    func tail(_ count: Int) -> [Float] {
        state.withLock { Array($0.samples.suffix(count)) }
    }

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
    private var deviceUID: String?
    private var configObserver: NSObjectProtocol?
    private let sink = SampleSink()
    private var isRecording = false

    /// RMS of the latest buffer, 0...~1.
    var level: Float { sink.level }

    /// The last `count` samples of the recording in progress, for the live preview.
    func recentSamples(_ count: Int) -> [Float] { sink.tail(count) }

    /// Called when the microphone stopped mid-recording and could not be restarted.
    var onFailure: (String) -> Void = { _ in }

    func start(deviceUID: String?) throws {
        _ = stop()
        sink.reset()
        self.deviceUID = deviceUID
        try startEngine()
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start`, even if the engine already died.
    func stop() -> [Float] {
        isRecording = false
        if let engine { teardown(engine) }
        return sink.drain()
    }

    /// Builds a fresh engine that appends to the current recording.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let deviceID = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw RecorderError.unsupportedFormat
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: Self.makeTap(converter: converter, ratio: Self.targetFormat.sampleRate / format.sampleRate, sink: sink))
        engine.prepare()
        try engine.start()
        self.engine = engine
        // AirPods switching profile, a mic plugged in, or another app taking the device stops the engine
        // silently. Restart on the new configuration and keep what was already captured.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    /// A device switch often reports an unusable format first, so try a few times before giving up.
    private func restart(attempt: Int = 1) {
        guard isRecording else { return }
        if let engine { teardown(engine) }
        do {
            try startEngine()
        } catch {
            guard attempt < 5 else { return onFailure(error.localizedDescription) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.restart(attempt: attempt + 1) }
            }
        }
    }

    private func teardown(_ engine: AVAudioEngine) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func makeTap(converter: AVAudioConverter, ratio: Double, sink: SampleSink) -> AVAudioNodeTapBlock {
        return { buffer, _ in
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
