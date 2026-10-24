import Foundation

/// Cuts long audio into pieces at its quietest moments, so no engine sees more than about a minute at once.
public enum AudioChunker {
    /// Frames of 50 ms are compared to find the quietest.
    private static let frame = 800

    /// Consecutive ranges covering all of `samples`. Each is at most `maxSeconds` long, cut at the quietest
    /// frame in the last `searchSeconds`. The last piece is never shorter than `minTailSeconds`.
    public static func ranges(
        _ samples: [Float], maxSeconds: Double = 60, searchSeconds: Double = 10, minTailSeconds: Double = 1
    ) -> [Range<Int>] {
        let maxCount = Audio.sampleCount(maxSeconds)
        let search = min(Audio.sampleCount(searchSeconds), maxCount / 2)
        let minTail = Audio.sampleCount(minTailSeconds)
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxCount + minTail {
            let end = start + maxCount
            let cut = quietestPoint(samples, from: end - search, to: end)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    private static func quietestPoint(_ samples: [Float], from lo: Int, to hi: Int) -> Int {
        var best = (energy: Float.infinity, at: hi)
        var i = lo
        while i + frame <= hi {
            var energy: Float = 0
            for j in i..<(i + frame) { energy += samples[j] * samples[j] }
            if energy < best.energy { best = (energy, i + frame / 2) }
            i += frame
        }
        return best.at
    }
}

/// Transcribes long audio piece by piece and joins the results, reporting progress from 0 to 1.
public struct ChunkedTranscriber: Transcriber {
    let base: any Transcriber
    let onProgress: @Sendable (Double) -> Void

    public init(base: any Transcriber, onProgress: @escaping @Sendable (Double) -> Void) {
        self.base = base
        self.onProgress = onProgress
    }

    public func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        let ranges = AudioChunker.ranges(samples)
        var parts: [String] = []
        for (i, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let text = try await base.transcribe(Array(samples[range]), languageCode: languageCode, dictionary: dictionary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
            onProgress(Double(i + 1) / Double(ranges.count))
        }
        return parts.joined(separator: " ")
    }
}
