import SwiftUI
import ColimaKit

struct MenuBarLabel: View {
    @Environment(ColimaStore.self) private var store
    var body: some View {
        Image(systemName: store.selectedProfile?.isRunning == true ? "shippingbox.fill" : "shippingbox")
    }
}

struct MenuBarView: View {
    @Environment(ColimaStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var collapsed: Set<String> = []
    private let maxGroups = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Divider().padding(.vertical, 4)
            if let p = store.selectedProfile, p.isRunning {
                let groups = store.groups
                if groups.isEmpty {
                    Text("No containers").foregroundStyle(.secondary).padding(.vertical, 6).padding(.horizontal, 8)
                }
                ForEach(groups.prefix(maxGroups)) { group in groupSection(group) }
                if groups.count > maxGroups {
                    Button("Show all \(groups.count) groups…") { openMain() }.buttonStyle(.borderless).padding(8)
                }
            } else if store.toolMissing != nil {
                Text(store.toolMissing ?? "").foregroundStyle(.secondary).padding(8)
            } else {
                Text("Colima isn't running").foregroundStyle(.secondary).padding(8)
            }
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(8)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: store.selectedProfile?.status.color ?? .secondary)
            Text(store.selectedProfile.map { "\($0.name) · \($0.isRunning ? "running" : "stopped")" } ?? "No profile")
                .fontWeight(.medium)
            Spacer()
            if let p = store.selectedProfile {
                let busy = store.busyProfiles.contains(p.name)
                if busy { ProgressView().controlSize(.small) }
                Button(p.isRunning ? "Stop VM" : "Start VM") {
                    Task { p.isRunning ? await store.stopProfile(p.name) : await store.startProfile(p.name) }
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(busy)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder
    private func groupSection(_ group: ContainerGroup) -> some View {
        if group.kind == .flat || group.kind == .standalone {
            ForEach(group.containers) { containerRow($0, indent: false) }
        } else {
            HStack(spacing: 6) {
                Button { toggle(group.id) } label: {
                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").frame(width: 14)
                }.buttonStyle(.borderless)
                Text(group.title).fontWeight(.medium).lineLimit(1)
                Text(group.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if group.runningCount > 0 {
                    IconButton(systemName: "stop.fill", help: "Stop all") { Task { await store.perform(.stop, on: group) } }
                }
                if group.runningCount < group.containers.count {
                    IconButton(systemName: "play.fill", help: "Start all") { Task { await store.perform(.start, on: group) } }
                }
                IconButton(systemName: "arrow.clockwise", help: "Restart all") { Task { await store.perform(.restart, on: group) } }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            if !collapsed.contains(group.id) {
                ForEach(group.containers) { containerRow($0, indent: true) }
            }
        }
    }

    private func containerRow(_ c: Container, indent: Bool) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: c.state.color)
            Text(indent ? c.displayName : c.name).lineLimit(1)
            Spacer()
            if let url = c.ports.compactMap(\.browserURL).first, c.isRunning {
                IconButton(systemName: "arrow.up.right.square", help: "Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
            if c.isRunning {
                IconButton(systemName: "stop.fill", help: "Stop", disabled: store.busyContainerIDs.contains(c.id)) {
                    Task { await store.perform(.stop, on: [c.id]) }
                }
            } else {
                IconButton(systemName: "play.fill", help: "Start", disabled: store.busyContainerIDs.contains(c.id)) {
                    Task { await store.perform(.start, on: [c.id]) }
                }
            }
        }
        .padding(.leading, indent ? 30 : 8).padding(.trailing, 8).padding(.vertical, 1)
        .foregroundStyle(c.isRunning ? .primary : .secondary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Open ColimaBar") { openMain() }.keyboardShortcut("o")
            if store.profiles.count > 1 {
                Menu("Switch profile") {
                    ForEach(store.profiles) { p in
                        Button(p.name + (p.isRunning ? "" : " (stopped)")) {
                            store.selectedProfileName = p.name
                            Task { await store.refresh() }
                        }
                    }
                }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
