import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bellterm

@MainActor
struct MachineTests {
    private func node(_ id: String, auth: AuthMethod = .key, jump: String? = nil, machine: String? = nil) -> Node {
        var node = Node(name: id, address: id, user: "u")
        node.id = id
        node.auth = auth
        node.jumpId = jump
        node.machine = machine
        return node
    }

    @Test func aSavedMachineIsNoHopOfOurs() {
        let route = [node("jump", auth: .password), node("host", auth: .password, jump: "jump")]
        let relayed = route + [node("b", auth: .password, jump: "host", machine: "ssh://me@b:2222")]
        #expect(Routes.sshHops(relayed).map(\.id) == ["jump", "host"])
        #expect(Routes.sshHops(route).map(\.id) == ["jump", "host"])
        #expect(Routes.requiredPasswordHops(relayed) { _ in false }.map(\.id) == ["jump", "host"])
        #expect(!Routes.sameRoute(relayed, route + [node("b", auth: .password, jump: "host", machine: "c")]))
    }

    @Test func aSavedMachineSurvivesStorage() throws {
        let machine = node("b", jump: "host", machine: "ssh://me@b:2222")
        let decoded = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(machine))
        #expect(decoded.machine == "ssh://me@b:2222")
        #expect(decoded.destination == "ssh://me@b:2222")
        #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node("a"))).machine == nil)
    }

    @Test func parsesWhatTheCoreReturns() throws {
        let json = #"[{"id":"a1","label":"build","target":"me@build","session":"agents","enabled":true},"#
            + #"{"id":"b2","label":"","target":"ssh://box:2200","session":"","enabled":true}]"#
        #expect(try Machine.parse(json) == [
            Machine(label: "build", target: "me@build", session: "agents"),
            Machine(label: "ssh://box:2200", target: "ssh://box:2200", session: "default"),
        ])
    }

    @Test func deletingAHostDeletesItsMachines() {
        let file = FileManager.default.temporaryDirectory.appending(path: "nodes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = NodeStore(file: file)
        let host = node("host")
        let other = node("other", jump: "host")
        store.upsertAll([host, other])
        let machine = store.machine(host: host, label: "b", target: "me@b", session: "agents")
        #expect(store.machine(host: host, label: "b", target: "me@b", session: "agents").id == machine.id)
        #expect(!store.jumpCandidates(for: nil).contains { $0.id == machine.id })
        store.delete(host)
        #expect(store.nodes.map(\.id) == ["other"])
        #expect(store.nodes.first?.jumpId == nil)
    }

    /// The sidebar with a host's machines, as an image CI keeps; a List only
    /// draws inside a window.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func sidebarListsTheHostsMachines(style: UIUserInterfaceStyle) throws {
        let host = node("e2e-host")
        let rows = [
            MachineRow(id: host.id, label: "e2e-host", target: "runner@10.0.2.2:2222", session: "default", color: 0, current: true),
            MachineRow(id: "b", label: "b-machine", target: "ssh://runner@127.0.0.1:2222", session: "machine", color: 0, current: false),
        ]
        let sidebar = SessionSidebar(
            node: host, view: nil, onWorkspace: { _ in }, onRenameWorkspace: { _ in }, onCloseWorkspace: { _ in },
            onAgent: { _ in }, onNewWorkspace: {}, machines: rows
        )
        let drawn = try snapshot(
            NavigationStack { sidebar.navigationTitle("e2e-host") }, named: "sidebar-machines", style: style
        )
        #expect(drawn > 2, "the sidebar drew nothing")
    }
}
