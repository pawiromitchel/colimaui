import SwiftUI
import ColimaKit

enum ContainerSelection: Hashable {
    case container(String)
    case group(String)
}

struct ContainersView: View {
    @Environment(ColimaStore.self) private var store
    @Environment(ComposeDropModel.self) private var compose
    @State private var selection: ContainerSelection?
    @State private var collapsed: Set<String> = []
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        @Bindable var store = store
        ZStack {
            if let selection, let detail = detail(for: selection) {
                detail
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(.smooth(duration: 0.3), value: selection)
        .navigationTitle("Containers")
        .searchable(text: $store.searchText, prompt: "Search")
        .toolbar {
            ToolbarItem {
                if selection == nil {
                    Button { ComposePicker.choose { compose.begin(urls: $0) } } label: { Label("Add stack", systemImage: "plus") }
                        .help("Start a stack from a compose file (or drop one on the window)")
                }
            }
            ToolbarItem {
                if selection == nil {
                Picker("Group by", selection: $store.groupMode) {
                    ForEach(GroupMode.allCases) { Text("Group: \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.menu)
                .help("Group containers")
                }
            }
        }
        .confirm($pendingDelete)
        .onAppear {
            applyRequestedSelection()
            // Lets the headless snapshot open a container: COLIMAUI_SELECT=<container name>.
            if selection == nil, let name = ProcessInfo.processInfo.environment["COLIMAUI_SELECT"],
               let match = store.containers.first(where: { $0.name == name }) {
                selection = .container(match.id)
            }
        }
        .onChange(of: store.requestedSelection) { applyRequestedSelection() }
        .onChange(of: store.containers) {
            if case .container(let id) = selection, store.container(id: id) == nil { selection = nil }
            if case .group(let id) = selection, !store.groups.contains(where: { $0.id == id }) { selection = nil }
        }
    }

    /// The dashboard asks to open a container or stack: `container:<id>` or `group:<id>`.
    private func applyRequestedSelection() {
        guard let request = store.requestedSelection else { return }
        store.requestedSelection = nil
        if request.hasPrefix("container:") {
            selection = .container(String(request.dropFirst("container:".count)))
        } else if request.hasPrefix("group:") {
            selection = .group(String(request.dropFirst("group:".count)))
        }
    }

    private var list: some View {
        let groups = store.groups
        return ZStack {
            if !store.hasLoaded {
                LoadingState(message: "Loading containers…")
            } else if store.selectedProfileIsBusy && store.containers.isEmpty {
                LoadingState(message: "Waiting for Colima…")
            } else if store.containers.isEmpty {
                EmptyState(systemImage: "shippingbox", title: "No containers",
                           message: "Drop a compose file on this window to start a stack, or run a container and it will show up here.") {
                    Button("Choose a compose file…") { ComposePicker.choose { compose.begin(urls: $0) } }
                }
            } else if groups.allSatisfy({ $0.containers.isEmpty }) {
                EmptyState(systemImage: "magnifyingglass", title: "No matches", message: "Try a different search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ContainerHeaderRow(compact: false)
                        ForEach(groups) { group in
                            if group.kind != .flat { groupRow(group) }
                            if !collapsed.contains(group.id) {
                                ForEach(group.containers) { container in
                                    ContainerRow(container: container, indent: group.kind != .flat,
                                                 compact: false,
                                                 selected: selection == .container(container.id),
                                                 pendingDelete: $pendingDelete)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                        .onTapGesture { selection = .container(container.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.hasLoaded)
    }

    private func groupRow(_ group: ContainerGroup) -> some View {
        GroupRow(group: group, compact: false, collapsed: collapsed.contains(group.id),
                 selected: selection == .group(group.id),
                 toggle: {
                withAnimation(.smooth(duration: 0.25)) {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                }
            },
                 pendingDelete: $pendingDelete)
            .onTapGesture { selection = .group(group.id) }
    }

    private func detail(for selection: ContainerSelection) -> AnyView? {
        switch selection {
        case .container(let id):
            guard let c = store.container(id: id) else { return nil }
            return AnyView(ContainerDetail(container: c, onClose: { self.selection = nil }, pendingDelete: $pendingDelete))
        case .group(let id):
            guard let g = store.groups.first(where: { $0.id == id }) else { return nil }
            return AnyView(GroupDetail(group: g, onClose: { self.selection = nil }, pendingDelete: $pendingDelete))
        }
    }
}

private struct ContainerHeaderRow: View {
    var compact: Bool
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 28)
            Text("Name").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if !compact { Text("Image").frame(width: 150, alignment: .leading) }
            Text("Ports").frame(width: 130, alignment: .leading)
            Text("CPU").frame(width: 50, alignment: .trailing)
            Text("Memory").frame(width: 70, alignment: .trailing)
            Color.clear.frame(width: 100)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}

private struct GroupRow: View {
    @Environment(ColimaStore.self) private var store
    var group: ContainerGroup
    var compact: Bool
    var collapsed: Bool
    var selected: Bool
    var toggle: () -> Void
    @Binding var pendingDelete: DeleteRequest?

    private var cpu: Double { group.containers.compactMap { store.stats[$0.id]?.cpuPercent }.reduce(0, +) }
    private var memory: Int64 {
        group.containers.compactMap { store.stats[$0.id]?.memoryUsage }.compactMap(Parsing.parseSize).reduce(0, +)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 20)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 6) {
                StatusDot(color: group.allRunning ? .green : (group.runningCount == 0 ? .secondary.opacity(0.6) : .orange))
                Text(group.title).fontWeight(.medium).lineLimit(1)
                if group.isStack || group.kind == .image {
                    Text(group.summary).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: (compact ? 0 : 150 + 8) + 130 + 8)
            Text(group.runningCount > 0 ? String(format: "%.1f%%", cpu) : "–")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            Text(group.runningCount > 0 && memory > 0 ? Format.bytes(memory) : "–")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            HStack(spacing: 2) {
                if group.runningCount > 0 {
                    IconButton(systemName: "stop.fill", help: "Stop all") { Task { await store.perform(.stop, on: group) } }
                }
                if group.runningCount < group.containers.count {
                    IconButton(systemName: "play.fill", help: "Start all") { Task { await store.perform(.start, on: group) } }
                }
                IconButton(systemName: "arrow.clockwise", help: "Restart all") { Task { await store.perform(.restart, on: group) } }
                IconButton(systemName: "trash", help: "Delete all", role: .destructive) {
                    pendingDelete = DeleteRequest(
                        title: "Delete \(group.containers.count) containers?",
                        message: "This removes every container in \(group.title). Volumes are kept.") {
                        await store.remove(group.containers.map(\.id))
                    }
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        .contentShape(Rectangle())
    }
}

private struct ContainerRow: View {
    @Environment(ColimaStore.self) private var store
    var container: Container
    var indent: Bool
    var compact: Bool
    var selected: Bool
    @Binding var pendingDelete: DeleteRequest?

    private var busy: Bool { store.busyContainerIDs.contains(container.id) }
    private var stats: ContainerStats? { store.stats[container.id] }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: indent ? 28 : 8)
            HStack(spacing: 6) {
                StatusDot(color: container.state.color)
                Text(indent ? container.displayName : container.name).lineLimit(1).truncationMode(.middle)
                if busy { ProgressView().controlSize(.mini) }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(container.image).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
            }
            PortLinks(ports: container.ports).frame(width: 130, alignment: .leading)
            Text(container.isRunning ? String(format: "%.1f%%", stats?.cpuPercent ?? 0) : "–")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            Text(container.isRunning ? (stats?.memoryUsage.replacingOccurrences(of: "iB", with: "") ?? "…") : "–")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            HStack(spacing: 2) {
                if container.isRunning {
                    IconButton(systemName: "stop.fill", help: "Stop", disabled: busy) { Task { await store.perform(.stop, on: [container.id]) } }
                } else {
                    IconButton(systemName: "play.fill", help: "Start", disabled: busy) { Task { await store.perform(.start, on: [container.id]) } }
                }
                IconButton(systemName: "arrow.clockwise", help: "Restart", disabled: busy) { Task { await store.perform(.restart, on: [container.id]) } }
                IconButton(systemName: "trash", help: "Delete", role: .destructive, disabled: busy) {
                    pendingDelete = DeleteRequest(title: "Delete \(container.name)?",
                                                  message: "The container is removed. Volumes are kept.") {
                        await store.remove([container.id])
                    }
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle())
        .contextMenu {
            if let url = container.ports.compactMap(\.browserURL).first {
                Button("Open in browser") { NSWorkspace.shared.open(url) }
            }
            if container.isRunning, let docker = store.docker {
                Button("Open shell in Terminal") { Terminal.run(docker.shellCommand(containerID: container.id)) }
            }
            Button("Copy ID") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(container.id, forType: .string)
            }
        }
    }
}

// MARK: - Detail panes

private struct DetailHeader<Actions: View>: View {
    var title: String
    var subtitle: String
    var color: Color
    var onClose: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Label("Containers", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to containers (Esc)")
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            actions
        }
        .padding(12)
    }
}

struct ContainerDetail: View {
    @Environment(ColimaStore.self) private var store
    var container: Container
    var onClose: () -> Void
    @Binding var pendingDelete: DeleteRequest?
    @State private var tab = Tab.logs

    enum Tab: String, CaseIterable, Identifiable { case logs = "Logs", inspect = "Inspect", info = "Info"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: container.name, subtitle: container.status, color: container.state.color, onClose: onClose) {
                if container.isRunning {
                    Button("Stop") { Task { await store.perform(.stop, on: [container.id]) } }
                    Button("Restart") { Task { await store.perform(.restart, on: [container.id]) } }
                    if let docker = store.docker {
                        Button("Shell") { Terminal.run(docker.shellCommand(containerID: container.id)) }
                            .help("Open a shell in Terminal")
                    }
                } else {
                    Button("Start") { Task { await store.perform(.start, on: [container.id]) } }
                }
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ZStack {
                switch tab {
                case .logs: LogsView(sources: [LogSource(id: container.id, label: nil)]).transition(.opacity)
                case .inspect: InspectView(id: container.id).transition(.opacity)
                case .info: info.transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: tab)
        }
    }

    private var info: some View {
        ScrollView {
            Card {
                KeyValueRow(key: "ID", value: container.id, mono: true)
                KeyValueRow(key: "Image", value: container.image, mono: true)
                KeyValueRow(key: "State", value: container.state.label)
                KeyValueRow(key: "Created", value: container.createdAt)
                if let project = container.composeProject { KeyValueRow(key: "Stack", value: project) }
                if let service = container.composeService { KeyValueRow(key: "Service", value: service) }
                if let dir = container.composeWorkingDir { KeyValueRow(key: "Directory", value: dir, mono: true) }
                if !container.ports.isEmpty { KeyValueRow(key: "Ports", value: container.ports.map(\.label).joined(separator: ", ")) }
                if let s = store.stats[container.id] {
                    KeyValueRow(key: "CPU", value: String(format: "%.2f%%", s.cpuPercent))
                    KeyValueRow(key: "Memory", value: "\(s.memoryUsage) (\(String(format: "%.1f", s.memoryPercent))%)")
                }
            }
            .padding(12)
        }
    }
}

struct GroupDetail: View {
    @Environment(ColimaStore.self) private var store
    var group: ContainerGroup
    var onClose: () -> Void
    @Binding var pendingDelete: DeleteRequest?
    @State private var tab = Tab.logs

    enum Tab: String, CaseIterable, Identifiable { case logs = "Stack logs", services = "Services"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: group.title, subtitle: "\(group.summary) running", color: group.allRunning ? .green : .orange, onClose: onClose) {
                if group.runningCount > 0 { Button("Stop") { Task { await store.perform(.stop, on: group) } } }
                if group.runningCount < group.containers.count {
                    Button("Start") {
                        Task { group.canComposeUp ? await store.composeUp(group) : await store.perform(.start, on: group) }
                    }
                }
                Button("Restart") { Task { await store.perform(.restart, on: group) } }
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            switch tab {
            case .logs:
                LogsView(sources: group.containers.filter(\.isRunning).map { LogSource(id: $0.id, label: $0.displayName) })
            case .services:
                ScrollView {
                    VStack(spacing: 8) {
                        if case .stack(_, let dir, _) = group.kind, let dir {
                            Card {
                                KeyValueRow(key: "Directory", value: dir, mono: true)
                                if !group.canComposeUp {
                                    Label("Compose files are missing, so the stack can be stopped or removed but not recreated.",
                                          systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        ForEach(group.containers) { c in
                            Card {
                                HStack {
                                    StatusDot(color: c.state.color)
                                    Text(c.displayName).fontWeight(.medium)
                                    Spacer()
                                    PortLinks(ports: c.ports)
                                }
                                Text(c.image).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                Text(c.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}
