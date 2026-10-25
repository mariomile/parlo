/// One system-only prefix. Tickets prevent work started before invalidation from repopulating it.
/// The owner provides isolation; no model, user message, or conversation is retained in the key.
struct LocalPromptCache<Value> {
    private var container: ObjectIdentifier?
    private var system: String?
    private var generation: UInt64 = 0
    private var stored: Value?

    mutating func select(container: ObjectIdentifier, system: String) -> UInt64 {
        if self.container != container || self.system != system {
            clear()
            self.container = container
            self.system = system
        }
        return generation
    }

    func value(for ticket: UInt64) -> Value? {
        ticket == generation ? stored : nil
    }

    mutating func publish(_ value: Value, ticket: UInt64, isCancelled: Bool) {
        guard !isCancelled, ticket == generation, container != nil else { return }
        stored = value
    }

    mutating func clear() {
        generation &+= 1
        container = nil
        system = nil
        stored = nil
    }

    static func allows(prefix: [Int], fragment: [Int], full: [Int]) -> Bool {
        !prefix.isEmpty && prefix.count <= 2048 && !fragment.isEmpty && full == prefix + fragment
    }
}
