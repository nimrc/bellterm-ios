import Foundation
import Testing
@testable import Bellterm

/// A session that never touches SSH, so the connection lifecycle can be
/// exercised on real routes without a host.
private final class FakeSession: SessionProtocol, @unchecked Sendable {
    private(set) var probes = 0

    func checkLiveness() { probes += 1 }
    func chord(pane: String?, codepoint: UInt32, meta: Int32) {}
    func disconnect() {}
    func key(pane: String?, keyCode: Int32, meta: Int32, unicode: UInt32, `repeat`: Bool) -> Bool { false }
    func nextEvent(timeoutMs: Int32) -> String? { nil }
    func paste(pane: String?, text: String) {}
    func request(method: String, paramsJson: String) throws -> String { "" }
    func resize(cols: Int32, rows: Int32, cellWidth: Int32, cellHeight: Int32) {}
    func selectionText(startColumn: Int32, startRow: Int32, endColumn: Int32, endRow: Int32) -> String { "" }
    func setTheme(themeJson: String) {}
    func takeFrame() -> Data? { nil }
    func takeView() -> String? { nil }
    func text(pane: String?, text: String) {}
    func touch(pane: String, kind: Int32, column: Int32, row: Int32, lines: Int32) {}
}

/// A delay that waits for the test to release it, deliberately ignoring
/// cancellation so post-wait ownership guards are exercised too.
private actor LifecycleClock {
    private var waits: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    func sleep() async {
        await withCheckedContinuation { continuation in
            waits.append(continuation)
            started?.resume()
            started = nil
        }
    }

    func waitUntilScheduled() async {
        if !waits.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func advance() {
        let pending = waits
        waits = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
struct ReconnectLifecycleTests {
    private func store() -> NodeStore {
        NodeStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    private func keyNode(_ name: String) -> Node {
        Node(name: name, address: "\(name).invalid", user: "test")
    }

    private func passwordNode(_ name: String) -> Node {
        var node = Node(name: name, address: "\(name).invalid", user: "test")
        node.auth = .password
        return node
    }

    private func makeModel(nodes: NodeStore, starts: @escaping () -> Void,
                           retrySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           pathSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> AppModel {
        AppModel(nodes: nodes, monitorNetwork: false, pathSleep: pathSleep, retrySleep: retrySleep,
                 prepareSession: { connection, _, _, _ in
                     starts()
                     connection.attachForTesting(FakeSession())
                 })
    }

    private func settle(_ count: Int = 50) async {
        for _ in 0..<count { await Task.yield() }
    }

    @Test func droppedSessionReattachesAfterBackoff() async throws {
        let nodes = store()
        let node = keyNode("drop")
        nodes.upsert(node)
        let clock = LifecycleClock()
        var starts = 0
        let model = makeModel(nodes: nodes, starts: { starts += 1 }, retrySleep: { _ in await clock.sleep() })

        let first = model.connect(node, dark: false)
        #expect(first.state == .connected(serverVersion: "test"))
        first.dropForTesting()
        #expect(first.retrying)
        #expect(model.hasPendingRetry(node.id))
        #expect(model.pendingRetryAttempts(node.id) == 1)

        await clock.waitUntilScheduled()
        await clock.advance()
        await settle()

        let second = try #require(model.connection(node.id))
        #expect(second !== first)
        #expect(second.state == .connected(serverVersion: "test"))
        #expect(!second.retrying)
        #expect(starts == 2)
    }

    @Test func foregroundReattachesSuspendedSession() throws {
        let nodes = store()
        let node = keyNode("foreground")
        nodes.upsert(node)
        var starts = 0
        let model = makeModel(nodes: nodes, starts: { starts += 1 })

        let first = model.connect(node, dark: false)
        model.enterBackground()
        #expect(!first.state.isOpen)

        model.enterForeground(dark: false)
        let second = try #require(model.connection(node.id))
        #expect(second !== first)
        #expect(second.state == .connected(serverVersion: "test"))
        #expect(!second.retrying)
        #expect(starts == 2)
    }

    @Test func networkReturnReattachesAndResetsBackoff() async throws {
        let nodes = store()
        let node = keyNode("network")
        nodes.upsert(node)
        let retryClock = LifecycleClock()
        let pathClock = LifecycleClock()
        var starts = 0
        let model = makeModel(nodes: nodes, starts: { starts += 1 },
                              retrySleep: { _ in await retryClock.sleep() },
                              pathSleep: { _ in await pathClock.sleep() })

        let first = model.connect(node, dark: false)
        first.dropForTesting()
        #expect(model.pendingRetryAttempts(node.id) == 1)

        model.pathChanged(NetworkSignature(satisfied: false, status: "unsatisfied"))
        model.pathChanged(NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true, endpoint: 1))
        await pathClock.waitUntilScheduled()
        await pathClock.advance()
        await settle()

        let second = try #require(model.connection(node.id))
        #expect(second !== first)
        #expect(second.state == .connected(serverVersion: "test"))
        #expect(!second.retrying)
        #expect(model.pendingRetryAttempts(node.id) == 0)
        #expect(starts == 2)

        // Let the cancelled backoff task finish its overridden sleep.
        await retryClock.advance()
        await settle(5)
    }

    @Test func pathChangeProbesOnlyEstablishedConnections() async {
        let nodes = store()
        let established = keyNode("established")
        let handshake = keyNode("handshake")
        nodes.upsertAll([established, handshake])
        let connectedFake = FakeSession()
        let connectingFake = FakeSession()
        let pathClock = LifecycleClock()
        let model = AppModel(nodes: nodes, monitorNetwork: false,
                             pathSleep: { _ in await pathClock.sleep() },
                             prepareSession: { connection, _, _, _ in
                                 if connection.node.id == established.id {
                                     connection.attachForTesting(connectedFake)
                                 } else {
                                     connection.holdForTesting(connectingFake)
                                 }
                             })

        _ = model.connect(established, dark: false)
        _ = model.connect(handshake, dark: false)
        model.pathChanged(NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true, endpoint: 1))
        await pathClock.waitUntilScheduled()
        await pathClock.advance()
        await settle()

        #expect(connectedFake.probes == 1)
        #expect(connectingFake.probes == 0)
    }

    @Test func otherNodesPromptSurvivesAutomaticReconnect() async throws {
        let nodes = store()
        let pending = passwordNode("pending")
        let reconnecting = keyNode("reconnecting")
        nodes.upsertAll([pending, reconnecting])
        let clock = LifecycleClock()
        var starts = 0
        let model = makeModel(nodes: nodes, starts: { starts += 1 },
                              retrySleep: { _ in await clock.sleep() })

        // A's prompt is open when B drops and reattaches on its own.
        let request = try #require(model.credentialRequest(pending))
        let first = model.connect(reconnecting, dark: false)
        #expect(first.state == .connected(serverVersion: "test"))
        first.dropForTesting()
        #expect(model.hasPendingRetry(reconnecting.id))

        await clock.waitUntilScheduled()
        await clock.advance()
        await settle()
        let second = try #require(model.connection(reconnecting.id))
        #expect(second !== first)
        #expect(second.state == .connected(serverVersion: "test"))

        let connected = try #require(model.submit(request, passwords: [pending.id: "a-secret"],
                                                  dark: false, remember: false))
        #expect(connected.state == .connected(serverVersion: "test"))
        #expect(model.connection(pending.id) === connected)
        #expect(starts == 3)
    }

    @Test func passwordRequiredOnRetryClearsRetryAndShowsReason() async throws {
        let nodes = store()
        var node = keyNode("password-required")
        nodes.upsert(node)
        let clock = LifecycleClock()
        let model = makeModel(nodes: nodes, starts: {}, retrySleep: { _ in await clock.sleep() })

        let connection = model.connect(node, dark: false)
        connection.dropForTesting()
        #expect(model.hasPendingRetry(node.id))
        await clock.waitUntilScheduled()

        node.auth = .password
        nodes.upsert(node)
        await clock.advance()
        await settle()

        #expect(!connection.retrying)
        #expect(!model.hasPendingRetry(node.id))
        guard case .failed(let reason) = connection.state else {
            Issue.record("retry must stop with a user-visible failure")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("password"))
    }

    @Test func routeChangeOnRetryClearsRetryAndShowsReason() async throws {
        let nodes = store()
        let firstJump = keyNode("first-jump")
        let secondJump = keyNode("second-jump")
        var target = keyNode("target")
        target.jumpId = firstJump.id
        nodes.upsertAll([firstJump, secondJump, target])
        let clock = LifecycleClock()
        let model = makeModel(nodes: nodes, starts: {}, retrySleep: { _ in await clock.sleep() })

        let connection = model.connect(target, dark: false)
        connection.dropForTesting()
        #expect(model.hasPendingRetry(target.id))
        await clock.waitUntilScheduled()

        target.jumpId = secondJump.id
        nodes.upsert(target)
        await clock.advance()
        await settle()

        #expect(!connection.retrying)
        #expect(!model.hasPendingRetry(target.id))
        guard case .failed(let reason) = connection.state else {
            Issue.record("retry must stop with a user-visible failure")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("route changed"))
    }
}
