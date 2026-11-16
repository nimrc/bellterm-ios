import Foundation
import Network
import Observation
import OSLog
import SwiftUI

/// Process-wide state. Connections outlive screens, as Herdr sessions outlive
/// clients: leaving a session keeps the attachment, and only an explicit
/// disconnect ends it. Disconnecting never stops the daemon.
///
/// iOS suspends apps in the background, so attachments are closed there and
/// reopened on return; Herdr keeps everything running meanwhile. A dropped
/// attachment is reopened with backoff, and at once when the network returns.
@MainActor
@Observable
final class AppModel {
    let nodes: NodeStore
    let keychain = Keychain()
    let settings = Settings()
    let fonts = FontManager()
    private(set) var connections: [String: Connection] = [:]
    /// Nodes attached when the app went to the background, to reattach.
    @ObservationIgnored private var suspended: [Node] = []
    /// Nodes being reattached on their own, and the pending attempt.
    @ObservationIgnored private var retries: [String: Retry] = [:]
    @ObservationIgnored private var active = true
    @ObservationIgnored private var interactive = true
    @ObservationIgnored private var dark = false
    private let monitor = NWPathMonitor()
    @ObservationIgnored private var lifecycle = UUID()
    /// Per-node prompt epochs, so disconnecting one node cannot invalidate
    /// another node's in-flight connect request.
    @ObservationIgnored private var requestEpochs: [String: UUID] = [:]
    @ObservationIgnored private var pathTask: Task<Void, Never>?
    @ObservationIgnored private var pathGeneration = UUID()
    private static let log = Logger(subsystem: "app.bellterm", category: "reconnect")
    /// The interface the system routes through, to notice a switch.
    @ObservationIgnored private var pathSignature: NetworkSignature?

    private struct Retry {
        var attempt = 0
        var task: Task<Void, Never>?
    }

    /// Delays before each attempt after a drop; then the user decides.
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]

    /// Injectable delay keeps retry ownership tests deterministic without SSH.
    @ObservationIgnored private let pathSleep: (Duration) async throws -> Void
    @ObservationIgnored private let networkSettled: () -> Void
    @ObservationIgnored private let retrySleep: (Duration) async throws -> Void
    @ObservationIgnored private let startSession: (Connection, String) -> Void
    /// Test seam: adopts a fake session instead of reading keys and building
    /// a route document. Production leaves this nil.
    @ObservationIgnored private let prepareSession: ((Connection, [Node], [String: String], Bool) -> Void)?

    init(nodes: NodeStore = NodeStore(), monitorNetwork: Bool = true,
         networkSettled: @escaping () -> Void = {},
         pathSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         retrySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         prepareSession: ((Connection, [Node], [String: String], Bool) -> Void)? = nil,
         startSession: @escaping (Connection, String) -> Void = { $0.start(configJson: $1) }) {
        self.pathSleep = pathSleep
        self.networkSettled = networkSettled
        self.nodes = nodes
        self.retrySleep = retrySleep
        self.startSession = startSession
        self.prepareSession = prepareSession
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkSignature(path)
            MainActor.assumeIsolated { self?.pathChanged(signature) }
        }
        if monitorNetwork { monitor.start(queue: .main) }
    }

    func connection(_ nodeId: String) -> Connection? { connections[nodeId] }

    /// Attach to `node` along its jump hosts, reusing a live connection.
    /// `passwords` maps node IDs on the route to passwords typed for this
    /// connection; `remember` saves them to the keychain, else any saved
    /// password for those hops is forgotten. Hops without one use their saved
    /// password.
    @discardableResult
    func connect(_ node: Node, passwords: [String: String] = [:], dark: Bool, remember: Bool = false) -> Connection {
        if let live = connections[node.id], live.isOpen { return live }
        cancelCredentialRequests(for: node.id)
        suspended.removeAll { $0.id == node.id }
        retries.removeValue(forKey: node.id)?.task?.cancel()
        connections[node.id]?.close()
        self.dark = dark
        let connection = Connection(node: node)
        connection.onDrop = { [weak self, weak connection] in
            if let connection { self?.dropped(connection) }
        }
        connection.onStop = { [weak self, weak connection] in
            guard let self, let connection, self.connections[node.id] === connection else { return }
            self.retries.removeValue(forKey: node.id)?.task?.cancel()
            connection.retrying = false
            Self.log.info("connect stopped id=\(connection.diagnosticID) category=\(connection.diagnosticCategory)")
        }
        connection.onConnected = { [weak self, weak connection] in
            guard let self, let connection, self.connections[node.id] === connection else { return }
            self.retries.removeValue(forKey: node.id)?.task?.cancel()
            connection.retrying = false
        }
        if case .success(let route) = nodes.route(node) { connection.routeSnapshot = route }
        connections[node.id] = connection
        nodes.touch(node)
        let route: [Node]
        switch nodes.route(node) {
        case .success(let found): route = found
        case .failure(let problem):
            connection.fail(Self.message(problem))
            return connection
        }
        let missing = Routes.requiredPasswordHops(route, supplied: passwords) { keychain.password(nodeId: $0.id)?.isEmpty == false }
        guard active, missing.isEmpty else {
            connection.fail(String(localized: "Passwords are required. Choose Reconnect to enter them."))
            Self.log.info("connect waiting_credentials hops=\(route.count)")
            return connection
        }
        if let prepareSession {
            prepareSession(connection, route, passwords, dark)
            return connection
        }
        do {
            if route.contains(where: { $0.auth == .key }) {
                _ = try keychain.deviceIdentity(name: String(localized: "This device"))
            }
            // A password typed but not remembered also clears any saved one,
            // which is how a rejected saved password is replaced or dropped.
            for (id, password) in passwords {
                if remember { try keychain.savePassword(nodeId: id, password) } else { keychain.forgetPassword(nodeId: id) }
            }
            let scheme = settings.scheme(dark: dark).withCursor(NodeColors.rgb(node.color))
            let document = try Routes.document(
                route: route, nodes: nodes, keychain: keychain, passwords: passwords,
                grid: settings.lastGrid, scheme: scheme
            )
            startSession(connection, document)
        } catch {
            connection.fail(String(localized: "A key on this route could not be read. Check Keys & certificates."))
        }
        return connection
    }

    /// The machines Herdr on `host` saved, listed over a connection of their
    /// own with saved passwords only.
    func machines(host: Node) async throws -> [Machine] {
        let route = try nodes.route(host).get()
        if route.contains(where: { $0.auth == .key }) {
            _ = try keychain.deviceIdentity(name: String(localized: "This device"))
        }
        let document = try Routes.document(
            route: route, nodes: nodes, keychain: keychain, passwords: [:],
            grid: settings.lastGrid, scheme: settings.scheme(dark: dark)
        )
        let json = try await Task.detached { try listMachines(configJson: document) }.value
        return try Machine.parse(json)
    }

    /// Nodes on `node`'s route that sign in with a password and have none saved.
    func passwordsToAsk(_ node: Node, rejectedHop: Int? = nil) -> [Node] {
        guard case .success(let route) = nodes.route(node) else { return [] }
        return Routes.requiredPasswordHops(route, rejectedHop: rejectedHop) { keychain.password(nodeId: $0.id)?.isEmpty == false }
    }

    /// A prompt holds route metadata, never secrets; submitting must still own
    /// the same attachment, lifecycle and route. An edit cannot redirect a password.
    struct CredentialRequest {
        let route: [Node]
        let hops: [Node]
        let lifecycle: UUID
        let nodeId: String
        let epoch: UUID
        let owner: Connection?
        let savedTarget: Bool
    }

    private func requestEpoch(_ nodeId: String) -> UUID {
        if let epoch = requestEpochs[nodeId] { return epoch }
        let epoch = UUID()
        requestEpochs[nodeId] = epoch
        return epoch
    }

    func credentialRequest(_ node: Node, rejectedHop: Int? = nil) -> CredentialRequest? {
        guard active, interactive, case .success(let route) = nodes.route(nodes.get(node.id) ?? node), let target = route.last else { return nil }
        return CredentialRequest(route: route, hops: passwordsToAsk(target, rejectedHop: rejectedHop),
                                 lifecycle: lifecycle, nodeId: target.id, epoch: requestEpoch(target.id),
                                 owner: connections[target.id], savedTarget: nodes.get(target.id) != nil)
    }

    func submit(_ request: CredentialRequest, passwords: [String: String], dark: Bool, remember: Bool) -> Connection? {
        guard active, interactive, lifecycle == request.lifecycle,
              requestEpochs[request.nodeId] == request.epoch, let target = request.route.last,
              !request.savedTarget || nodes.get(target.id) != nil,
              connections[target.id] === request.owner,
              case .success(let current) = nodes.route(nodes.get(target.id) ?? target),
              Routes.sameRoute(current, request.route),
              request.hops.allSatisfy({ passwords[$0.id]?.isEmpty == false }) else { return nil }
        return reconnect(target, passwords: passwords, dark: dark, remember: remember)
    }

    /// Inactive invalidates visible credentials without closing attachments.
    func enterInactive() { interactive = false; cancelCredentialRequests() }

    /// With a node, invalidates only that node's prompt; without one, every
    /// prompt (app lifecycle changes invalidate all of them).
    func cancelCredentialRequests(for nodeId: String? = nil) {
        if let nodeId {
            requestEpochs[nodeId] = nil
        } else {
            lifecycle = UUID()
            requestEpochs.removeAll()
        }
    }

    /// Retry after the user trusted a host key or changed credentials.
    @discardableResult
    func reconnect(_ node: Node, passwords: [String: String] = [:], dark: Bool, remember: Bool = false) -> Connection {
        disconnect(node.id)
        return connect(nodes.get(node.id) ?? node, passwords: passwords, dark: dark, remember: remember)
    }

    func disconnect(_ nodeId: String) {
        cancelCredentialRequests(for: nodeId)
        suspended.removeAll { $0.id == nodeId }
        retries.removeValue(forKey: nodeId)?.task?.cancel()
        connections[nodeId]?.close()
        connections[nodeId] = nil
    }

    func disconnectAll() {
        connections.keys.forEach(disconnect)
    }

    func enterBackground() {
        guard active else { return }
        active = false
        cancelCredentialRequests()
        pathTask?.cancel()
        pathGeneration = UUID()
        Self.log.info("lifecycle background")
        suspended = connections.values.filter { $0.isOpen || retries[$0.node.id] != nil }.map(\.node)
        retries.values.forEach { $0.task?.cancel() }
        retries = [:]
        connections.values.forEach { $0.close() }
    }

    func enterForeground(dark: Bool) {
        interactive = true
        guard !active else { self.dark = dark; return }
        active = true
        self.dark = dark
        Self.log.info("lifecycle foreground")
        let nodes = suspended
        suspended = []
        for node in nodes where connections[node.id] != nil {
            guard let old = connections[node.id] else { continue }
            let current = self.nodes.get(node.id) ?? node
            let snapshotIntact = old.routeSnapshot.allSatisfy { self.nodes.get($0.id) != nil }
            if case .success(let route) = self.nodes.route(current),
               !old.routeSnapshot.isEmpty,
               snapshotIntact,
               !Routes.sameRoute(route, old.routeSnapshot) {
                old.fail(String(localized: "The route changed. Choose Reconnect to connect again."))
                continue
            }
            // A missing jump or deleted old hop falls through to a real attempt
            // so its route error reaches the user.
            let connection = reconnect(current, dark: dark)
            // Missing credentials/invalid routes require user action, not an empty attempt.
            if case .connecting = connection.state {
                retries[node.id] = Retry()
            } else if connection.isDropped {
                retries[node.id] = Retry()
                dropped(connection)
            }
        }
    }

    // MARK: Reattaching

    /// Schedules the next attempt for a dropped attachment. A link that was
    /// attached starts afresh; a failed attempt only continues its own run,
    /// so a node that never connected is left to the user.
    private func dropped(_ connection: Connection) {
        let id = connection.node.id
        guard active, connections[id] === connection, connection.isDropped else { return }
        if connection.attached { retries[id] = Retry() }
        // Typed passwords are not kept, so only the user can supply them again.
        guard var retry = retries[id], passwordsToAsk(connection.node).isEmpty else {
            retries[id]?.task?.cancel()
            retries[id] = nil
            connection.retrying = false
            return
        }
        // Out of attempts: kept, so the network returning still reattaches.
        guard retry.attempt < Self.backoff.count else { connection.retrying = false; return }
        let delay = Self.backoff[retry.attempt]
        Self.log.info("retry scheduled id=\(connection.diagnosticID) attempt=\(retry.attempt + 1)")
        retry.attempt += 1
        retries[id] = retry
        scheduleReattach(connection, after: delay)
        connection.retrying = true
    }

    /// A delayed retry belongs to this exact dropped attachment, never its replacement.
    @discardableResult
    func scheduleReattach(_ connection: Connection, after delay: Duration) -> Task<Void, Never>? {
        let id = connection.node.id
        guard active, connections[id] === connection else { return nil }
        var retry = retries[id] ?? Retry()
        retry.task?.cancel()
        retry.task = Task { [weak self, weak connection] in
            guard let self else { return }
            try? await self.retrySleep(delay)
            guard !Task.isCancelled, let connection,
                  self.active, self.connections[id] === connection else { return }
            self.reattach(id)
        }
        retries[id] = retry
        return retry.task
    }

    private func reattach(_ id: String) {
        guard active, var retry = retries[id], let old = connections[id], old.isDropped else { return }
        let missing = passwordsToAsk(nodes.get(id) ?? old.node)
        guard missing.isEmpty else {
            // A jump password was deleted or the node switched to password auth.
            // Stop the spinner and let the user supply it; an empty retry cannot.
            retries.removeValue(forKey: id)?.task?.cancel()
            old.retrying = false
            old.fail(String(localized: "Passwords are required. Choose Reconnect to enter them."))
            Self.log.info("reattach waiting_credentials id=\(old.diagnosticID) hops=\(missing.count)")
            return
        }
        let node = nodes.get(id) ?? old.node
        // A deleted jump host must surface its real route error, not look like
        // a user edit. Only a live route that changed while all old hops still
        // exist is a route edit worth stopping for.
        let snapshotIntact = old.routeSnapshot.allSatisfy { nodes.get($0.id) != nil }
        if case .success(let route) = nodes.route(node),
           snapshotIntact,
           !Routes.sameRoute(route, old.routeSnapshot) {
            retries.removeValue(forKey: id)?.task?.cancel()
            old.retrying = false
            old.fail(String(localized: "The route changed. Choose Reconnect to connect again."))
            return
        }
        retry.task?.cancel()
        retry.task = nil
        let connection = reconnect(node, dark: dark)
        // A synchronous start failure must participate in backoff, but a route
        // failure, host trust, rejected credentials or incompatibility must not.
        if case .connected = connection.state {
            retries.removeValue(forKey: id)?.task?.cancel()
            connection.retrying = false
        } else if connection.isDropped {
            retries[id] = retry
            dropped(connection)
        } else if connection.state.isOpen {
            retries[id] = retry
        } else {
            connection.retrying = false
        }
    }

    func pathChanged(_ signature: NetworkSignature) {
        guard signature != pathSignature else { return }
        pathSignature = signature
        pathTask?.cancel()
        let generation = UUID()
        pathGeneration = generation
        guard signature.satisfied, active else { return }
        pathTask = Task { [weak self] in
            guard let self else { return }
            try? await self.pathSleep(.milliseconds(500))
            guard !Task.isCancelled, self.active, self.pathGeneration == generation else { return }
            self.networkSettled()
            Self.log.info("network changed ipv4=\(signature.ipv4) ipv6=\(signature.ipv6) tunnel=\(signature.tunnel)")
            // This is a fresh route, not a continuation of the old link's backoff.
            for id in Array(self.retries.keys) { self.retries[id]?.attempt = 0 }
            // Only an established attachment has a live link to prove. A
            // handshake in progress is bounded by Connection's timeout instead.
            for connection in self.connections.values where connection.attached {
                if case .connected = connection.state { connection.checkLiveness() }
            }
            for id in Array(self.retries.keys) where self.connections[id]?.isDropped == true {
                self.reattach(id)
            }
        }
    }

    /// Test/diagnostic view of the backoff state for a node.
    func pendingRetryAttempts(_ nodeId: String) -> Int? { retries[nodeId]?.attempt }
    func hasPendingRetry(_ nodeId: String) -> Bool { retries[nodeId] != nil }

    private static func message(_ problem: RouteProblem) -> String {
        switch problem {
        case .missingJump(let node):
            String(localized: "The jump host of \(node.title) was deleted. Edit the node to choose another.")
        case .loop(let node):
            String(localized: "The jump hosts of \(node.title) form a loop.")
        case .tooLong:
            String(localized: "A route may have at most \(Node.maxHops) hops.")
        }
    }
}
