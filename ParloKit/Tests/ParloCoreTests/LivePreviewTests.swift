import Testing
@testable import ParloCore

@Suite struct LivePreviewTests {
    @Test func previewsOnlyFastModels() {
        #expect(LivePreview.supports(ModelCatalog.info(.parakeetV3)))
        #expect(LivePreview.supports(ModelCatalog.info(.appleSpeech)))
        // About 0.8 s per preview tick on a 10 s window: it would never rest, and the final would wait for it.
        #expect(!LivePreview.supports(ModelCatalog.info(.qwen3ASR)))
        #expect(!LivePreview.supports(ModelCatalog.info(.cohereTranscribe)))
    }
}
