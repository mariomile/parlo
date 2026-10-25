@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Where captured audio goes, called from an audio thread with 16 kHz mono Float32 samples.
public protocol AudioSink: Sendable {
    func append(_ chunk: [Float])
}

/// Writes one meeting track to disk as it is captured, so an hour of audio is never held in memory and a crash
/// loses only the last moments. Gaps (a device switch, a late start) are filled with silence so that both
/// tracks keep the meeting's clock and their turns can be put in order.
public final class TrackWriter: AudioSink {
    private struct State: @unchecked Sendable {
        var file: AVAudioFile?
        var written = 0
        var error: (any Error)?
    }

    private let state: Mutex<State>
    /// Seconds since the meeting started.
    private let elapsed: @Sendable () -> Double
    /// Shorter gaps are timing jitter between buffers, not missing audio.
    private static let gapTolerance = Audio.sampleCount(0.5)

    /// 16-bit CAF: a quarter of the size of float WAV, and still readable when the app died mid-write.
    public init(url: URL, elapsed: @escaping @Sendable () -> Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(Audio.sampleRate), AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        state = Mutex(State(file: file))
        self.elapsed = elapsed
    }

    public func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let expectedStart = Audio.sampleCount(elapsed()) - chunk.count
        state.withLock { s in
            guard let file = s.file else { return }
            let gap = expectedStart - s.written
            do {
                if gap > Self.gapTolerance {
                    // A second at a time: a long stall must not allocate its whole length on the audio thread.
                    let second = [Float](repeating: 0, count: Audio.sampleRate)
                    for start in stride(from: 0, to: gap, by: second.count) {
                        try Self.write(Array(second.prefix(gap - start)), to: file)
                    }
                    s.written += gap
                }
                try Self.write(chunk, to: file)
                s.written += chunk.count
            } catch {
                s.error = s.error ?? error
            }
        }
    }

    /// Seconds written so far.
    public var duration: Double { state.withLock { Audio.seconds($0.written) } }

    /// Finishes the file. Returns the first write error, if any happened.
    @discardableResult
    public func close() -> (any Error)? {
        state.withLock { s in
            s.file?.close()
            s.file = nil
            return s.error
        }
    }

    private static func write(_ samples: [Float], to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}

/// Finds the stretches of speech in a track, each short enough to transcribe in one go.
public protocol SpeechSegmenting: Sendable {
    func speechRanges(_ samples: [Float]) async throws -> [Range<Int>]
}

/// Turns one meeting track into timed turns: speech is found, each stretch is transcribed on its own,
/// and its place in the recording becomes the turn's time.
public struct MeetingTrackTranscriber: Sendable {
    let transcriber: any Transcriber
    let segmenter: any SpeechSegmenting
    let languageCode: String?
    let dictionary: [DictionaryEntry]

    public init(
        transcriber: any Transcriber, segmenter: any SpeechSegmenting, languageCode: String?, dictionary: [DictionaryEntry]
    ) {
        self.transcriber = transcriber
        self.segmenter = segmenter
        self.languageCode = languageCode
        self.dictionary = dictionary
    }

    public struct Failure: Equatable, Sendable {
        public let speaker: MeetingTurn.Speaker
        public let start: Double
        public let end: Double
        public let reason: String

        public var warning: String {
            "\(speaker.label) [\(MeetingTranscript.timestamp(start))–\(MeetingTranscript.timestamp(end))]: Transcription missing (\(reason))."
        }
    }

    public struct Result: Sendable {
        public let turns: [MeetingTurn]
        public let failures: [Failure]
        public var warnings: [String] { failures.map(\.warning) }
        fileprivate let firstError: (any Error)?
    }

    /// Compatibility for callers needing only turns. Meeting processing should use `transcribe` and
    /// persist its warnings; the legacy API still throws when every attempted stretch fails.
    public func turns(
        _ samples: [Float], speaker: MeetingTurn.Speaker, cutAt cuts: [Double] = [], onProgress: @Sendable (Double) -> Void
    ) async throws -> [MeetingTurn] {
        let result = try await transcribe(samples, speaker: speaker, cutAt: cuts, onProgress: onProgress)
        if result.turns.isEmpty, let error = result.firstError { throw error }
        return result.turns
    }

    /// Keeps successful turns and reports every failed interval, including a wholly failed track, so
    /// the other side's transcript can still be used. Cancellation is never a partial success.
    /// `cuts`, in seconds, split stretches where the other side starts and stops: without headphones the microphone
    /// hears them too, and their words then land in a turn of their own that `MeetingTranscript.merge` can drop.
    public func transcribe(
        _ samples: [Float], speaker: MeetingTurn.Speaker, cutAt cuts: [Double] = [], onProgress: @Sendable (Double) -> Void
    ) async throws -> Result {
        try Task.checkCancellation()
        guard !RecordingGuard.isDigitalSilence(samples) else {
            onProgress(1)
            return Result(turns: [], failures: [], firstError: nil)
        }
        let found: [Range<Int>]
        do {
            found = try await segmenter.speechRanges(samples)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            onProgress(1)
            return Result(
                turns: [],
                failures: [Failure(speaker: speaker, start: 0, end: Audio.seconds(samples.count), reason: error.localizedDescription)],
                firstError: error
            )
        }
        let ranges = Self.split(found, at: cuts.map(Audio.sampleCount))
        var turns: [MeetingTurn] = []
        var failures: [Failure] = []
        var firstError: (any Error)?
        for (i, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let range = range.clamped(to: samples.indices)
            let piece = Array(samples[range])
            if RecordingGuard.isLongEnough(sampleCount: piece.count), !RecordingGuard.isDigitalSilence(piece) {
                do {
                    let text = try await transcriber.transcribe(piece, languageCode: languageCode, dictionary: dictionary)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    if !text.isEmpty {
                        turns.append(MeetingTurn(
                            speaker: speaker, start: Audio.seconds(range.lowerBound), end: Audio.seconds(range.upperBound), text: text
                        ))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    firstError = firstError ?? error
                    failures.append(Failure(
                        speaker: speaker, start: Audio.seconds(range.lowerBound), end: Audio.seconds(range.upperBound),
                        reason: error.localizedDescription
                    ))
                }
            }
            onProgress(Double(i + 1) / Double(ranges.count))
        }
        try Task.checkCancellation()
        if ranges.isEmpty { onProgress(1) }
        return Result(turns: turns, failures: failures, firstError: firstError)
    }

    static func split(_ ranges: [Range<Int>], at cuts: [Int]) -> [Range<Int>] {
        let cuts = cuts.sorted()
        return ranges.flatMap { range in
            let inside = cuts.filter { range.lowerBound < $0 && $0 < range.upperBound }
            let bounds = [range.lowerBound] + inside + [range.upperBound]
            return zip(bounds, bounds.dropFirst()).map { $0..<$1 }
        }
    }
}
