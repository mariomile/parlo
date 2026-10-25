import Testing
@testable import ParloEngines

@Test func systemPrefixRequiresExactTokenConcatenation() {
    #expect(LocalPromptCache<Int>.allows(prefix: [1, 2], fragment: [3, 4], full: [1, 2, 3, 4]))
    #expect(!LocalPromptCache<Int>.allows(prefix: [1, 2], fragment: [3, 4], full: [1, 5, 3, 4]))
    #expect(!LocalPromptCache<Int>.allows(prefix: [], fragment: [3], full: [3]))
    #expect(!LocalPromptCache<Int>.allows(prefix: [1], fragment: [], full: [1]))
    #expect(!LocalPromptCache<Int>.allows(prefix: Array(repeating: 1, count: 2049), fragment: [2],
                                          full: Array(repeating: 1, count: 2049) + [2]))
}

@Test func systemPrefixCacheReusesOnlyExactSystemAndContainer() {
    let first = NSObjectIdentity()
    let second = NSObjectIdentity()
    var cache = LocalPromptCache<Int>()
    let ticket = cache.select(container: ObjectIdentifier(first), system: "rules")
    cache.publish(42, ticket: ticket, isCancelled: false)
    #expect(cache.value(for: ticket) == 42)
    #expect(cache.select(container: ObjectIdentifier(first), system: "rules") == ticket)
    let changedRules = cache.select(container: ObjectIdentifier(first), system: "rules ")
    #expect(cache.value(for: changedRules) == nil)
    cache.publish(43, ticket: changedRules, isCancelled: false)
    let changedModel = cache.select(container: ObjectIdentifier(second), system: "rules ")
    #expect(cache.value(for: changedModel) == nil)
}

@Test func invalidatedOrCancelledPrefixCannotPublish() {
    let model = NSObjectIdentity()
    var cache = LocalPromptCache<Int>()
    let old = cache.select(container: ObjectIdentifier(model), system: "rules")
    cache.clear()
    let current = cache.select(container: ObjectIdentifier(model), system: "rules")
    cache.publish(1, ticket: old, isCancelled: false)
    #expect(cache.value(for: current) == nil)
    cache.publish(2, ticket: current, isCancelled: true)
    #expect(cache.value(for: current) == nil)
    cache.publish(3, ticket: current, isCancelled: false)
    #expect(cache.value(for: current) == 3)
    #expect(cache.value(for: old) == nil)
}

private final class NSObjectIdentity {}
