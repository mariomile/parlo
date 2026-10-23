@preconcurrency import AVFoundation
import Foundation
import ParloCore
import Speech

/// Apple's on-device SpeechAnalyzer with the dictation model, the one macOS dictation uses, so its
/// assets are often already installed. No auto-detect: uses the configured language, else the system locale.
/// Missing assets download in the background; until then dictation fails fast with `assetsInstalling`
/// instead of waiting on a download of unknown length.
struct AppleSpeechTranscriber: Transcriber {
    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String {
        // A bare "it" would match it_CH; pin the usual region.
        let requested = NemotronBackend.regionalCode(languageCode).map(Locale.init(identifier:)) ?? Locale.current
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLanguage(requested.identifier)
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            await AssetInstalls.shared.start(for: transcriber, locale: locale)
            throw TranscriptionError.assetsInstalling(locale.identifier)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let buffer = try AudioBuffers.make(samples: samples, format: format)

        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let collector = Task {
            var parts: [String] = []
            for try await result in transcriber.results {
                parts.append(String(result.text.characters))
            }
            return parts
        }
        _ = try await analyzer.analyzeSequence(inputs)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return AudioBuffers.join(try await collector.value)
    }
}

/// Starts at most one system asset download per locale, in the background.
actor AssetInstalls {
    static let shared = AssetInstalls()
    private var started: Set<String> = []

    func start(for transcriber: DictationTranscriber, locale: Locale) async {
        guard started.insert(locale.identifier).inserted else { return }
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        Task.detached {
            do { try await request.downloadAndInstall() } catch {}
            await self.finished(locale.identifier)
        }
    }

    private func finished(_ id: String) { started.remove(id) }
}

enum AudioBuffers {
    static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    /// 16 kHz mono Float32 samples converted to `format` (or left as is when nil).
    static func make(samples: [Float], format: AVAudioFormat?) throws -> AVAudioPCMBuffer {
        let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            source.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        guard let format, format != sourceFormat else { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw NSError(domain: "Parlo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return output
    }

    static func join(_ parts: [String]) -> String {
        parts.reduce("") { acc, part in
            if acc.isEmpty { return part }
            if acc.last?.isWhitespace == true || part.first?.isWhitespace == true { return acc + part }
            return acc + " " + part
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
