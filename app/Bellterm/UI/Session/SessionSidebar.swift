import SwiftUI

/// Herdr's sidebar: every workspace with its branch and the daemon's status
/// dot, and every agent. Tabs are switched from the session's tab strip. Like
/// Herdr's own client, it also lists the host and the SSH machines its Herdr
/// saved, each a session of its own.
struct SessionSidebar: View {
    let node: Node
    let view: ShellView?
    let onWorkspace: (Workspace) -> Void
    let onRenameWorkspace: (Workspace) -> Void
    let onCloseWorkspace: (Workspace) -> Void
    let onAgent: (Agent) -> Void
    let onNewWorkspace: () -> Void
    /// The host first, then its machines; empty when it saved none.
    var machines: [MachineRow] = []
    var onMachine: (MachineRow) -> Void = { _ in }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    NodeAvatar(title: node.title, color: node.color, size: 44)
                    VStack(alignment: .leading) {
                        Text(node.title).font(.title3.weight(.semibold))
                        Text(node.destination + (node.session == "default" ? "" : " · \(node.session)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Workspaces") {
                ForEach(view?.workspaces ?? []) { workspace in
                    Button { onWorkspace(workspace) } label: {
                        HStack {
                            StatusDot(status: workspace.status)
                            VStack(alignment: .leading) {
                                Text(workspace.label).lineLimit(1)
                                if let detail = Self.detail(workspace) {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(workspace.number)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(workspace.focused ? Color.accentColor.opacity(0.15) : nil)
                    .contextMenu {
                        Button("Rename workspace", systemImage: "pencil") { onRenameWorkspace(workspace) }
                        Button("Close workspace", systemImage: "xmark.square", role: .destructive) { onCloseWorkspace(workspace) }
                    }
                }
                Button(action: onNewWorkspace) { Label("New workspace", systemImage: "plus") }
            }
            if let agents = view?.agents, !agents.isEmpty {
                Section("Agents") {
                    ForEach(agents) { agent in
                        Button { onAgent(agent) } label: {
                            HStack {
                                StatusDot(status: agent.status)
                                VStack(alignment: .leading) {
                                    Text(agent.displayName).lineLimit(1)
                                    let workspace = view?.workspaces.first { $0.id == agent.workspace }?.label
                                    Text([agent.status.label, workspace, agent.title].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .listRowBackground(agent.focused ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
            }
            if !machines.isEmpty {
                Section("Machines") {
                    ForEach(machines) { machine in
                        Button { onMachine(machine) } label: {
                            HStack(spacing: 12) {
                                NodeAvatar(title: machine.label, color: machine.color, size: 24)
                                VStack(alignment: .leading) {
                                    Text(machine.label).lineLimit(1)
                                    Text(machine.target + (machine.session == "default" ? "" : " · \(machine.session)"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .listRowBackground(machine.current ? Color.accentColor.opacity(0.15) : nil)
                        .accessibilityIdentifier("machine:\(machine.label)")
                    }
                }
            }
        }
        .tint(.primary)
    }

    private static func detail(_ workspace: Workspace) -> String? {
        var parts: [String] = []
        if let branch = workspace.branch { parts.append(branch) }
        if let ahead = workspace.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = workspace.behind, behind > 0 { parts.append("↓\(behind)") }
        if workspace.linkedWorktree, let worktree = workspace.worktree { parts.append("⎇ \(worktree)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

/// A host or one of its saved machines in the sidebar; `current` is this session's.
struct MachineRow: Identifiable, Equatable {
    var id: String
    var label: String
    var target: String
    var session: String
    var color: Int
    var current: Bool
}

extension AgentStatus {
    var label: String? {
        switch self {
        case .working: String(localized: "Working")
        case .blocked: String(localized: "Needs input")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Idle")
        case .unknown: nil
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .frame(width: 24)
            .accessibilityLabel(status.label ?? "")
    }
}

struct NodeAvatar: View {
    let title: String
    let color: Int
    var size: CGFloat = 40

    var body: some View {
        Text(title.prefix(1).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(NodeColors.of(color), in: .rect(cornerRadius: size * 0.3))
    }
}
