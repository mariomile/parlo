import Foundation
import Testing
@testable import ParloEngines

@Suite struct ModelStorageTests {
    @Test func topFolderIsTheChildOfAModelRoot() {
        let inner = ModelStorage.fluidAudioRoot.appendingPathComponent("cohere-transcribe/q8")
        #expect(ModelStorage.topFolder(inner).lastPathComponent == "cohere-transcribe")
        let outside = URL(fileURLWithPath: "/tmp/elsewhere")
        #expect(ModelStorage.topFolder(outside) == outside)
    }

    /// Reads this Mac's real model folders without changing them.
    @Test func scanListsEachFolderOnce() {
        let items = ModelStorage.scan()
        for item in items {
            print("[storage] \(item.name) · \(item.bytes / 1_000_000) MB · \(item.kind) · \(item.url.lastPathComponent)")
        }
        #expect(Set(items.map(\.id)).count == items.count)
        for a in items {
            for b in items where a.id != b.id {
                #expect(!b.id.hasPrefix(a.id + "/"))
            }
        }
    }
}
