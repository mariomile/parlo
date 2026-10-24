@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import ParloCore

@Suite struct AudioFileDecoderTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-audio-\(UUID().uuidString)")

    /// A sine written in `settings`' format, `channels` identical channels.
    func write(_ name: String, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, settings: [String: Any]? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate)) }
        }
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func resamplesStereo44kToMono16k() async throws {
        let url = try write("a.caf", sampleRate: 44_100, channels: 2, seconds: 3)
        let samples = try await AudioFileDecoder.decode(url)
        #expect(abs(samples.count - 48_000) < 400)
        // A 0.5 sine has an RMS of 0.354; both channels were identical so the average keeps it.
        #expect(abs(rms(samples) - 0.354) < 0.03)
        #expect(try AudioFileDecoder.duration(of: url) == 3)
    }

    @Test func keeps16kMonoAsIs() async throws {
        let url = try write("b.wav", sampleRate: 16_000, channels: 1, seconds: 1)
        let samples = try await AudioFileDecoder.decode(url)
        #expect(samples.count == 16_000)
    }

    @Test func decodesAAC() async throws {
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ]
        let url = try write("c.m4a", sampleRate: 48_000, channels: 1, seconds: 2, settings: aac)
        let samples = try await AudioFileDecoder.decode(url)
        #expect(abs(samples.count - 32_000) < 1_000)
        #expect(rms(samples) > 0.25)
    }

    @Test func longFileKeepsItsLength() async throws {
        let url = try write("d.caf", sampleRate: 22_050, channels: 1, seconds: 125)
        let samples = try await AudioFileDecoder.decode(url)
        #expect(abs(samples.count - 2_000_000) < 2_000)
    }

    @Test func notAudioThrows() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "e.txt")
        try Data("hello".utf8).write(to: url)
        await #expect(throws: AudioFileError.unreadable("e.txt")) { try await AudioFileDecoder.decode(url) }
    }
}

@Suite struct ChunkedTranscriberTests {
    @Test func shortAudioIsOnePiece() {
        #expect(AudioChunker.ranges([Float](repeating: 0.1, count: 16_000 * 59)) == [0..<(16_000 * 59)])
    }

    @Test func cutsAtTheQuietestMoment() {
        // 130 s of loud audio with a short gap at 55 s, inside the last 10 s before the 60 s limit.
        var samples = [Float](repeating: 0.5, count: 130 * 16_000)
        for i in (55 * 16_000)..<(55 * 16_000 + 1_600) { samples[i] = 0 }
        let ranges = AudioChunker.ranges(samples)
        #expect(ranges.count == 3)
        let cut = ranges[0].upperBound
        #expect(cut >= 55 * 16_000 && cut <= 55 * 16_000 + 1_600)
    }

    @Test func rangesCoverEverythingWithoutTinyTails() {
        for seconds in [60.0, 61, 61.5, 62, 119, 120, 121, 125.3, 600] {
            let count = Int(seconds * 16_000)
            let ranges = AudioChunker.ranges([Float](repeating: 0.1, count: count))
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == count)
            for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
            for r in ranges { #expect(r.count <= 61 * 16_000, "\(seconds)") }
            #expect((ranges.last?.count ?? 0) >= 16_000 || ranges.count == 1)
        }
    }

    @Test func joinsPiecesAndReportsProgress() async throws {
        let progress = LockedBox<[Double]>([])
        let t = ChunkedTranscriber(base: FakeTranscriber(text: " piece "), onProgress: { progress.value.append($0) })
        let text = try await t.transcribe([Float](repeating: 0.1, count: 130 * 16_000), languageCode: nil, dictionary: [])
        #expect(text == "piece piece piece")
        #expect(progress.value.last == 1)
        #expect(progress.value.count == 3)
    }
}
