import Foundation
import Network
import Observation
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
    let nodes = NodeStore()
    let keychain = Keychain()
    let settings = Settings()
    let fonts = FontManager()
    private(set) var connections: [String: Connection] = [:]
    /// Nodes attached when the app went to the background, to reattach.
    @ObservationIgnored private var suspended: [Node] = []
    /// Nodes being reattached on their own, and the pending attempt.
    @ObservationIgnored private var retries: [String: Retry] = [:]
    @ObservationIgnored private var active = true
    @ObservationIgnored private var dark = false
    private let monitor = NWPathMonitor()
    /// The interface the system routes through, to notice a switch.
    @ObservationIgnored private var interface: String?

    private struct Retry {
        var attempt = 0
        var task: Task<Void, Never>?
    }

    /// Delays before each attempt after a drop; then the user decides.
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interface = satisfied ? path.availableInterfaces.first?.name : nil
            MainActor.assumeIsolated { self?.pathChanged(satisfied: satisfied, interface: interface) }
        }
        monitor.start(queue: .main)
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
        connections[node.id]?.close()
        self.dark = dark
        let connection = Connection(node: node)
        connection.onDrop = { [weak self, weak connection] in
            if let connection { self?.dropped(connection) }
        }
        connections[node.id] = connection
        nodes.touch(node)
        let route: [Node]
        switch nodes.route(node) {
        case .success(let found): route = found
        case .failure(let problem):
            connection.fail(Self.message(problem))
            return connection
        }
        do {
            _ = try keychain.deviceIdentity(name: String(localized: "This device"))
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
            connection.start(configJson: document)
        } catch {
            connection.fail(String(localized: "A key on this route could not be read. Check Keys & certificates."))
        }
        return connection
    }

    /// Nodes on `node`'s route that sign in with a password and have none saved.
    func passwordsToAsk(_ node: Node) -> [Node] {
        guard case .success(let route) = nodes.route(node) else { return [] }
        return Routes.unsavedPasswordHops(route) { keychain.hasPassword(nodeId: $0.id) }
    }

    /// Retry after the user trusted a host key or changed credentials.
    @discardableResult
    func reconnect(_ node: Node, passwords: [String: String] = [:], dark: Bool, remember: Bool = false) -> Connection {
        disconnect(node.id)
        return connect(nodes.get(node.id) ?? node, passwords: passwords, dark: dark, remember: remember)
    }

    func disconnect(_ nodeId: String) {
        retries.removeValue(forKey: nodeId)?.task?.cancel()
        connections[nodeId]?.close()
        connections[nodeId] = nil
    }

    func disconnectAll() {
        connections.keys.forEach(disconnect)
    }

    func enterBackground() {
        active = false
        suspended = connections.values.filter { $0.isOpen || retries[$0.node.id] != nil }.map(\.node)
        retries.values.forEach { $0.task?.cancel() }
        retries = [:]
        connections.values.forEach { $0.close() }
    }

    func enterForeground(dark: Bool) {
        active = true
        let nodes = suspended
        suspended = []
        for node in nodes where connections[node.id] != nil {
            reconnect(node, dark: dark)
            // The network may not be back yet; a failure here retries too.
            retries[node.id] = Retry()
        }
    }

    // MARK: Reattaching

    /// Schedules the next attempt for a dropped attachment. A link that was
    /// attached starts afresh; a failed attempt only continues its own run,
    /// so a node that never connected is left to the user.
    private func dropped(_ connection: Connection) {
        let id = connection.node.id
        guard active, connections[id] === connection else { return }
        if connection.attached { retries[id] = Retry() }
        // Typed passwords are not kept, so only the user can supply them again.
        guard var retry = retries[id], passwordsToAsk(connection.node).isEmpty else {
            retries[id] = nil
            return
        }
        // Out of attempts: kept, so the network returning still reattaches.
        guard retry.attempt < Self.backoff.count else { return }
        let delay = Self.backoff[retry.attempt]
        retry.attempt += 1
        retry.task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { self?.reattach(id) }
        }
        retries[id] = retry
        connection.retrying = true
    }

    private func reattach(_ id: String) {
        guard var retry = retries[id], let node = connections[id]?.node else { return }
        retry.task?.cancel()
        retry.task = nil
        reconnect(nodes.get(id) ?? node, dark: dark)
        retries[id] = retry
    }

    private func pathChanged(satisfied: Bool, interface: String?) {
        let switched = interface != self.interface
        self.interface = interface
        guard satisfied, active else { return }
        // Links on the old route may be dead without a word; the probe ends
        // them in seconds rather than at the next routine health check.
        if switched { connections.values.forEach { $0.checkLiveness() } }
        for id in retries.keys where connections[id]?.isDropped == true {
            reattach(id)
        }
    }

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
