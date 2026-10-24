@preconcurrency import AVFoundation
import Foundation

public enum AudioFileError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(name): "Couldn't read “\(name)” as audio"
        case let .empty(name): "“\(name)” has no audio"
        }
    }
}

/// Reads any audio file macOS can open (m4a, mp3, wav, aiff, caf...) as the 16 kHz mono Float32 the engines take.
public enum AudioFileDecoder {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Source frames read at a time, so a long file is never held in memory in its original format.
    private static let block: AVAudioFrameCount = 65_536

    public static func duration(of url: URL) throws -> Double {
        let file = try open(url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    @concurrent
    public static func decode(_ url: URL) async throws -> [Float] {
        let file = try open(url)
        let format = file.processingFormat
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let converter = format.sampleRate == target.sampleRate ? nil : AVAudioConverter(from: mono, to: target)
        if format.sampleRate != target.sampleRate, converter == nil { throw AudioFileError.unreadable(url.lastPathComponent) }

        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
        let downmixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: block)!
        /// The next block of the file as mono at the source rate, nil at the end.
        func nextBlock() throws -> AVAudioPCMBuffer? {
            guard file.framePosition < file.length else { return nil }
            try file.read(into: input, frameCount: block)
            guard input.frameLength > 0 else { return nil }
            downmix(input, into: downmixed)
            return downmixed
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * target.sampleRate / format.sampleRate) + 1)
        do {
            guard let converter else {
                while let buffer = try nextBlock() { append(buffer, to: &samples) }
                return try nonEmpty(samples, url)
            }
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768)!
            nonisolated(unsafe) var readError: (any Error)?
            while true {
                var convertError: NSError?
                let status = converter.convert(to: output, error: &convertError) { _, inputStatus in
                    do {
                        if let buffer = try nextBlock() {
                            inputStatus.pointee = .haveData
                            return buffer
                        }
                    } catch { readError = error }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let error = readError ?? convertError { throw error }
                append(output, to: &samples)
                if status == .endOfStream || status == .error { break }
            }
        } catch {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        return try nonEmpty(samples, url)
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do { return try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) } catch {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
    }

    private static func nonEmpty(_ samples: [Float], _ url: URL) throws -> [Float] {
        guard !samples.isEmpty else { throw AudioFileError.empty(url.lastPathComponent) }
        return samples
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Averages all channels.
    private static func downmix(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        output.frameLength = input.frameLength
        let out = output.floatChannelData![0]
        let first = input.floatChannelData![0]
        for i in 0..<frames { out[i] = first[i] }
        guard channels > 1 else { return }
        for c in 1..<channels {
            let data = input.floatChannelData![c]
            for i in 0..<frames { out[i] += data[i] }
        }
        let scale = 1 / Float(channels)
        for i in 0..<frames { out[i] *= scale }
    }
}
