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
                    try Self.write([Float](repeating: 0, count: gap), to: file)
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
    /// Without one, the track is cut every 30 s or so at its quietest moments.
    let segmenter: (any SpeechSegmenting)?
    let languageCode: String?
    let dictionary: [DictionaryEntry]

    public init(
        transcriber: any Transcriber, segmenter: (any SpeechSegmenting)?, languageCode: String?, dictionary: [DictionaryEntry]
    ) {
        self.transcriber = transcriber
        self.segmenter = segmenter
        self.languageCode = languageCode
        self.dictionary = dictionary
    }

    /// A stretch that fails is left out rather than costing the whole meeting; only when every one fails
    /// does the error come through.
    public func turns(
        _ samples: [Float], speaker: MeetingTurn.Speaker, onProgress: @Sendable (Double) -> Void
    ) async throws -> [MeetingTurn] {
        guard !RecordingGuard.isDigitalSilence(samples) else {
            onProgress(1)
            return []
        }
        let ranges = try await segmenter?.speechRanges(samples) ?? AudioChunker.ranges(samples, maxSeconds: 30)
        var turns: [MeetingTurn] = []
        var firstError: (any Error)?
        var attempted = 0
        for (i, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let piece = Array(samples[range.clamped(to: samples.indices)])
            if RecordingGuard.isLongEnough(sampleCount: piece.count), !RecordingGuard.isDigitalSilence(piece) {
                attempted += 1
                do {
                    let text = try await transcriber.transcribe(piece, languageCode: languageCode, dictionary: dictionary)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        turns.append(MeetingTurn(
                            speaker: speaker, start: Audio.seconds(range.lowerBound), end: Audio.seconds(range.upperBound), text: text
                        ))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    firstError = firstError ?? error
                }
            }
            onProgress(Double(i + 1) / Double(ranges.count))
        }
        if let firstError, turns.isEmpty, attempted > 0 { throw firstError }
        return turns
    }
}
