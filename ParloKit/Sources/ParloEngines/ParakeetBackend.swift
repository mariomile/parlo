import FluidAudio
import Foundation
import ParloCore

/// Parakeet TDT models via FluidAudio. Files live in FluidAudio's shared cache, so models
/// already downloaded by FluidVoice are picked up as installed.
enum ParakeetBackend {
    static let vocabularyFiles = VocabularyModelFiles(directory: CtcModels.defaultCacheDirectory(for: .ctc110m))
    static func version(_ id: ModelID) -> AsrModelVersion {
        switch id {
        case .parakeetUltra: .ultra
        case .parakeetRedux: .redux
        case .parakeetV2: .v2
        default: .v3
        }
    }

    static func directory(_ id: ModelID) -> URL {
        AsrModels.defaultCacheDirectory(for: version(id))
    }

    static func isInstalled(_ id: ModelID) -> Bool {
        AsrModels.modelsExist(at: directory(id), version: version(id))
    }

    static func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: version(id)) { progress($0.fractionCompleted) }
    }

    static func makeTranscriber(_ id: ModelID) async throws -> any Transcriber {
        let v = version(id)
        let models = try await AsrModels.load(from: directory(id), version: v)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetTranscriber(manager: manager)
    }
}

/// With a dictionary, the transcript is rescored against a small CTC model run over the same audio,
/// which swaps in dictionary terms where the acoustics support them.
actor ParakeetTranscriber: Transcriber {
    let manager: AsrManager
    private var ctcModels: CtcModels?
    private var loadingCtc = false
    private var ctcGeneration = 0
    /// After a failed download, wait before trying again rather than retrying on every dictation.
    private var ctcRetryAfter = Date.distantPast
    private var session: (key: [String], boosting: VocabularyBoostingSession)?

    init(manager: AsrManager) {
        self.manager = manager
    }

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        refreshCtcState()
        if !dictionary.terms.isEmpty { startLoadingCtcModels() }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language = languageCode.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        guard let timings = result.tokenTimings, let boosting = await boostingSession(for: dictionary) else {
            return result.text
        }
        return await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)?.text
            ?? result.text
    }

    /// Nil when the dictionary is empty or the CTC model can't load: boosting never blocks a dictation.
    private func boostingSession(for dictionary: [DictionaryEntry]) async -> VocabularyBoostingSession? {
        refreshCtcState()
        let entries = dictionary.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !entries.isEmpty else { return nil }
        let key = entries.map { ([$0.term] + $0.heardAs).joined(separator: "\u{1F}") }
        if let session, session.key == key { return session.boosting }

        guard let models = ctcModels else { return nil }
        let terms = entries.map { entry in
            CustomVocabularyTerm(
                text: entry.term.trimmingCharacters(in: .whitespaces),
                aliases: entry.heardAs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            )
        }
        let generation = ctcGeneration
        guard let boosting = try? await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: terms), ctcModels: models
        ) else { return nil }
        refreshCtcState()
        guard generation == ctcGeneration, ctcModels != nil else { return nil }
        session = (key, boosting)
        return boosting
    }

    /// The CTC model (~100 MB) downloads and loads in the background: dictations made before it is
    /// ready skip boosting instead of waiting for it.
    private func startLoadingCtcModels() {
        guard ctcModels == nil, !loadingCtc, Date() >= ctcRetryAfter else { return }
        guard let generation = ParakeetBackend.vocabularyFiles.beginLoad() else { return }
        loadingCtc = true
        Task {
            let models = try? await Self.loadCtcModels()
            ParakeetBackend.vocabularyFiles.finishLoad()
            ctcLoaded(models, generation: generation)
        }
    }

    private static func loadCtcModels() async throws -> CtcModels {
        let directory = ParakeetBackend.vocabularyFiles.directory
        // Upstream's modelsExist does not include the tokenizer read by VocabularyBoostingSession.
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) {
            try await ModelHub.download(.parakeetCtc110m, to: directory.deletingLastPathComponent(), additionalModelNames: ["tokenizer.json"])
        }
        return try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }

    private func ctcLoaded(_ models: CtcModels?, generation: Int) {
        loadingCtc = false
        let files = ParakeetBackend.vocabularyFiles
        guard generation == files.generation, files.assetsExist else {
            ctcModels = nil
            session = nil
            ctcRetryAfter = Date().addingTimeInterval(300)
            return
        }
        ctcGeneration = generation
        ctcModels = models
        if models == nil { ctcRetryAfter = Date().addingTimeInterval(300) }
    }

    private func refreshCtcState() {
        let files = ParakeetBackend.vocabularyFiles
        if ctcGeneration != files.generation || (ctcModels != nil && !files.assetsExist) {
            ctcGeneration = files.generation
            ctcModels = nil
            session = nil
            ctcRetryAfter = .distantPast
        }
    }
}
