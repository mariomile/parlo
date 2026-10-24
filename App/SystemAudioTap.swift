@preconcurrency import AVFoundation
import CoreAudio
import ParloCore

enum SystemAudioError: LocalizedError {
    case failed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .failed(step, status): "Couldn't capture the Mac's audio (\(step), error \(status))"
        }
    }
}

/// Everything the Mac plays except Parlo itself, as 16 kHz mono Float32: the other side of a call.
/// A Core Audio process tap feeds a private aggregate device built on the current output. The first start
/// asks for System Audio Recording; when it's denied the buffers are silent and nothing reports an error.
final class SystemAudioTap {
    /// What Core Audio's listeners point to. It holds the tap weakly, so a late notification finds nothing.
    private final class Listener {
        weak var tap: SystemAudioTap?
        init(_ tap: SystemAudioTap) { self.tap = tap }
    }

    private let sink: any AudioSink
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    /// The tap's format the capture was built for; set once its listener is on.
    private var builtFormat: AudioStreamBasicDescription?
    /// Set while capturing.
    private var listener: Unmanaged<Listener>?
    /// Bumped on every rebuild, so a retry scheduled for an older one does nothing.
    private var generation = 0
    private let queue = DispatchQueue(label: "parlo.system-audio", qos: .userInitiated)

    /// Called when the capture stopped and could not be rebuilt.
    var onFailure: (String) -> Void = { _ in }

    init(sink: any AudioSink) {
        self.sink = sink
    }

    func start() throws {
        let listener = Unmanaged.passRetained(Listener(self))
        self.listener = listener
        // Headphones plugged in or AirPods connected move the output, and the tap with it.
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.changed, listener.toOpaque())
        do { try build() } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let listener else { return teardown() }
        self.listener = nil
        generation += 1
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.changed, listener.toOpaque())
        teardown(listener)
        // A notification already on its way to the main queue still finds the object, with no tap in it.
        DispatchQueue.main.async { listener.release() }
    }

    /// Right after an output switch the new device often refuses to be used for a moment: a few tries, as the
    /// microphone does.
    private func rebuild(attempt: Int = 1) {
        guard let listener else { return }
        if attempt == 1 { generation += 1 }
        teardown(listener)
        do { try build() } catch {
            guard attempt < 5 else {
                stop()
                return onFailure(error.localizedDescription)
            }
            let scheduled = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == scheduled else { return }
                    self.rebuild(attempt: attempt + 1)
                }
            }
        }
    }

    /// The tap reports its format when it attaches and starts too: only a real change is worth a rebuild.
    private func formatChanged() {
        guard let built = builtFormat, let now = tapFormat(),
              now.mSampleRate != built.mSampleRate || now.mChannelsPerFrame != built.mChannelsPerFrame
        else { return }
        rebuild()
    }

    private nonisolated static let changed: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let listener = Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { listener.tap?.rebuild() } }
        return noErr
    }

    private nonisolated static let formatChangedProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let listener = Unmanaged<Listener>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { listener.tap?.formatChanged() } }
        return noErr
    }

    private func build() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("tap", AudioHardwareCreateProcessTap(description, &tapID))

        guard let outputUID = Self.defaultOutputUID else {
            teardown(listener)
            throw SystemAudioError.failed("no output device", kAudioHardwareBadDeviceError)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Parlo meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        try check("device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        guard var stream = tapFormat() else {
            teardown(listener)
            throw SystemAudioError.failed("format", kAudioHardwareUnspecifiedError)
        }
        guard let format = AVAudioFormat(streamDescription: &stream),
              let converter = AVAudioConverter(from: format, to: Audio.format)
        else {
            teardown(listener)
            throw SystemAudioError.failed("format", kAudioHardwareUnsupportedOperationError)
        }
        let block = Self.makeIOBlock(format: format, converter: converter, sink: sink)
        try check("reader", AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue, block))
        try check("start", AudioDeviceStart(aggregateID, ioProc))
        // The output's sample rate can change under the same device: AirPods switching to their headset profile.
        if let listener {
            var address = Self.tapFormatAddress
            AudioObjectAddPropertyListener(tapID, &address, Self.formatChangedProc, listener.toOpaque())
            builtFormat = stream
        }
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.tapFormatAddress
        return AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream) == noErr ? stream : nil
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status != noErr else { return }
        teardown(listener)
        throw SystemAudioError.failed(step, status)
    }

    private func teardown(_ listener: Unmanaged<Listener>? = nil) {
        if builtFormat != nil, let listener {
            var address = Self.tapFormatAddress
            AudioObjectRemovePropertyListener(tapID, &address, Self.formatChangedProc, listener.toOpaque())
        }
        builtFormat = nil
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Built outside the main actor: it runs on the capture queue.
    private nonisolated static func makeIOBlock(
        format: AVAudioFormat, converter: AVAudioConverter, sink: any AudioSink
    ) -> AudioDeviceIOBlock {
        let ratio = Audio.format.sampleRate / format.sampleRate
        return { _, input, _, _, _ in
            // An output with a microphone of its own (a headset, an audio interface) brings its input stream into
            // the aggregate ahead of the tap's: the tap is the last buffer.
            guard let tap = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).last,
                  let samples = tap.mData, tap.mDataByteSize > 0
            else { return }
            let frames = AVAudioFrameCount(tap.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData
            else { return }
            buffer.frameLength = frames
            channel[0].update(from: samples.assumingMemoryBound(to: Float.self), count: Int(frames))
            guard frames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
            else { return }
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

    private static let tapFormatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Parlo's own sounds stay out of the meeting.
    private static var ownProcess: AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static var defaultOutputUID: String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
