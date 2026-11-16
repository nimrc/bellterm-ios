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
        // Only a window in a scene draws; the test host app has one.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 640)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: NavigationStack { sidebar.navigationTitle("e2e-host") })
        window.makeKeyAndVisible()
        RunLoop.main.run(until: .now + 2)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        #expect(Self.colours(in: image) > 2, "the sidebar drew nothing")
        let png = try #require(image.pngData())
        Attachment.record(png, named: "sidebar-machines-\(style == .dark ? "dark" : "light").png")
    }

    /// Distinct colours in `image`, sampled on a coarse grid.
    private static func colours(in image: UIImage) -> Int {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: cg.height, by: 16) {
            for x in stride(from: 0, to: cg.width, by: 16) {
                let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
                seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            }
        }
        return seen.count
    }
}
