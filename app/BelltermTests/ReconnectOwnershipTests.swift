import Foundation
import Testing
@testable import Bellterm

@MainActor
struct ReconnectOwnershipTests {
    /// A fake clock intentionally ignores cancellation, exercising the post-wait guard too.
    private actor RetryClock {
        var waiting: CheckedContinuation<Void, Never>?
        var didStart: CheckedContinuation<Void, Never>?

        func sleep() async {
            await withCheckedContinuation { continuation in
                waiting = continuation
                didStart?.resume()
                didStart = nil
            }
        }

        func waitUntilScheduled() async {
            if waiting != nil { return }
            await withCheckedContinuation { didStart = $0 }
        }

        func advance() {
            waiting?.resume()
            waiting = nil
        }
    }

    @Test func oldRetryCannotDisconnectManualReplacement() async throws {
        let clock = RetryClock()
        let model = AppModel(monitorNetwork: false, retrySleep: { _ in await clock.sleep() })
        // Invalid routes fail before Keychain or SSH: connection ownership stays real.
        var node = Node(name: "retry ownership", address: "example.invalid", user: "test")
        node.jumpId = "missing-test-hop"
        let old = model.connect(node, dark: false)
        let pending = try #require(model.scheduleReattach(old, after: .seconds(1)))
        await clock.waitUntilScheduled()
        let replacement = model.connect(node, dark: false)
        #expect(old !== replacement)
        #expect(pending.isCancelled)
        await clock.advance()
        await pending.value
        #expect(model.connection(node.id) === replacement)
        #expect(model.scheduleReattach(old, after: .seconds(1)) == nil)
        model.disconnectAll()
    }
}
