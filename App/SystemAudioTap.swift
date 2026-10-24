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
    private let sink: any AudioSink
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "parlo.system-audio", qos: .userInitiated)

    /// Called when the capture stopped and could not be rebuilt.
    var onFailure: (String) -> Void = { _ in }

    init(sink: any AudioSink) {
        self.sink = sink
    }

    func start() throws {
        try build()
        // Headphones plugged in or AirPods connected move the output, and the tap with it.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuild() } }
        }
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        outputListener = listener
    }

    func stop() {
        if let outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, outputListener)
        }
        outputListener = nil
        teardown()
    }

    private func rebuild() {
        guard outputListener != nil else { return }
        teardown()
        do { try build() } catch {
            stop()
            onFailure(error.localizedDescription)
        }
    }

    private func build() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("tap", AudioHardwareCreateProcessTap(description, &tapID))

        guard let outputUID = Self.defaultOutputUID else {
            teardown()
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

        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        try check("format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream))
        guard let format = AVAudioFormat(streamDescription: &stream),
              let converter = AVAudioConverter(from: format, to: Audio.format)
        else {
            teardown()
            throw SystemAudioError.failed("format", kAudioHardwareUnsupportedOperationError)
        }
        let block = Self.makeIOBlock(format: format, converter: converter, sink: sink)
        try check("reader", AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue, block))
        try check("start", AudioDeviceStart(aggregateID, ioProc))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status != noErr else { return }
        teardown()
        throw SystemAudioError.failed(step, status)
    }

    private func teardown() {
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
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0,
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
