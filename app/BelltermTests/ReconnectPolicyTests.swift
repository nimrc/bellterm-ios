import Foundation
import Testing
@testable import Bellterm

@MainActor
struct ReconnectPolicyTests {
    private func store() -> NodeStore {
        NodeStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func rejectedSavedHopStillCollectsEntireUnsavedRoute() {
        var a = Node(name: "a", address: "a.invalid", user: "test")
        var b = Node(name: "b", address: "b.invalid", user: "test")
        var c = Node(name: "c", address: "c.invalid", user: "test")
        a.auth = .password; b.auth = .password; c.auth = .password
        let required = Routes.requiredPasswordHops([a, b, c], rejectedHop: 1) { $0.id == b.id }
        #expect(required.map(\.id) == [a.id, b.id, c.id])
        #expect(Routes.requiredPasswordHops([a, b, c], supplied: [a.id: "one", c.id: "three"]) { $0.id == b.id }.isEmpty)
        #expect(Routes.requiredPasswordHops([a], supplied: [a.id: ""]) { _ in false } == [a])
    }

    @Test func missingPasswordsFailBeforeSSHAndDoNotRetry() {
        let model = AppModel(nodes: store(), monitorNetwork: false)
        var node = Node(name: "missing", address: "unused.invalid", user: "test")
        node.auth = .password
        let connection = model.connect(node, dark: false)
        guard case .failed = connection.state else { Issue.record("Must require user action"); return }
        #expect(!connection.isOpen)
        #expect(!connection.retrying)
        model.enterBackground(); model.enterBackground(); model.enterForeground(dark: false)
        #expect(model.connection(node.id) === connection)
    }

    @Test func inactivePromptCannotSubmitAfterResume() throws {
        let model = AppModel(nodes: store(), monitorNetwork: false)
        var node = Node(name: "prompt", address: "unused.invalid", user: "test")
        node.auth = .password
        let request = try #require(model.credentialRequest(node))
        model.enterInactive()
        #expect(model.submit(request, passwords: [node.id: "not-a-real-secret"], dark: false, remember: false) == nil)
        model.enterForeground(dark: false)
        #expect(model.submit(request, passwords: [node.id: "not-a-real-secret"], dark: false, remember: false) == nil)
        #expect(model.connection(node.id) == nil)
    }

    @Test func promptCannotConnectEditedRouteOrManualReplacement() throws {
        let nodes = store()
        let model = AppModel(nodes: nodes, monitorNetwork: false)
        var node = Node(name: "prompt", address: "unused.invalid", user: "test")
        node.auth = .password
        nodes.upsert(node)
        let request = try #require(model.credentialRequest(node))
        node.address = "edited.invalid"
        nodes.upsert(node)
        #expect(model.submit(request, passwords: [node.id: "fixture"], dark: false, remember: false) == nil)
        let currentRequest = try #require(model.credentialRequest(node))
        let replacement = model.connect(node, dark: false)
        #expect(model.submit(currentRequest, passwords: [node.id: "fixture"], dark: false, remember: false) == nil)
        #expect(model.connection(node.id) === replacement)
    }

    @Test func duplicateBackgroundPreservesResumeAndDisconnectRevokesIt() throws {
        let model = AppModel(nodes: store(), monitorNetwork: false)
        var node = Node(name: "ownership", address: "unused.invalid", user: "test")
        node.jumpId = "missing"
        let connection = model.connect(node, dark: false)
        let task = try #require(model.scheduleReattach(connection, after: .seconds(60)))
        model.enterBackground(); model.enterBackground()
        #expect(task.isCancelled)
        model.enterForeground(dark: false)
        let resumed = try #require(model.connection(node.id))
        #expect(resumed === connection) // invalid route cannot be automatically resumed
        model.enterForeground(dark: false)
        #expect(model.connection(node.id) === resumed)
        _ = model.scheduleReattach(resumed, after: .seconds(60))
        model.enterBackground(); model.disconnect(node.id); model.enterForeground(dark: false)
        #expect(model.connection(node.id) == nil)
    }

    @Test func pathSignaturesRepresentCapabilitiesAndActualInterfaceSet() {
        let wifi = NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true)
        #expect(wifi == NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true))
        #expect(wifi != NetworkSignature(satisfied: true, interfaces: ["cellular"], ipv4: true))
        #expect(wifi != NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true, ipv6: true))
        #expect(wifi != NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true, expensive: true))
        #expect(wifi != NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true, constrained: true))
        #expect(wifi != NetworkSignature(satisfied: false, status: "unsatisfied"))
    }
}

@MainActor
struct NetworkDebounceTests {
    private actor Clock {
        var waits: [CheckedContinuation<Void, Never>] = []
        var started: CheckedContinuation<Void, Never>?
        func sleep() async { await withCheckedContinuation { waits.append($0); started?.resume(); started = nil } }
        func wait() async { if !waits.isEmpty { return }; await withCheckedContinuation { started = $0 } }
        func release() { let pending = waits; waits = []; pending.forEach { $0.resume() } }
    }

    @Test func meaningfulChangeDebouncesAndBackgroundCancelsGeneration() async {
        let clock = Clock()
        var probes = 0
        let model = AppModel(monitorNetwork: false, networkSettled: { probes += 1 }, pathSleep: { _ in await clock.sleep() })
        let wifi = NetworkSignature(satisfied: true, interfaces: ["wifi"], ipv4: true)
        model.pathChanged(wifi)
        await clock.wait()
        model.pathChanged(wifi)
        await clock.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(probes == 1)
        model.pathChanged(NetworkSignature(satisfied: true, interfaces: ["cellular"], ipv4: true, expensive: true))
        await clock.wait()
        model.enterBackground()
        await clock.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(probes == 1)
    }
}
