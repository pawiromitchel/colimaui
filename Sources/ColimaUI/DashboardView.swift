import SwiftUI
import ColimaKit

struct Sparkline: View {
    var values: [Double]
    /// Top of the scale. When nil the chart scales to its own peak.
    var maxValue: Double?
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1) * 1.2, 0.0001)
            if values.count < 2 {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                }
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
            } else {
                let step = geo.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step, y: geo.size.height - CGFloat(min(v / top, 1)) * (geo.size.height - 2) - 1)
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

struct UsageBar: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

private struct Tile<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        Card(minHeight: 112) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            content
        }
    }
}

struct DashboardView: View {
    @Environment(ColimaStore.self) private var store
    var navigate: (NavSection) -> Void

    @State private var topSort = TopSort.memory
    @State private var pendingAction: DeleteRequest?

    enum TopSort: String, CaseIterable, Identifiable { case memory = "Memory", cpu = "CPU"; var id: String { rawValue } }

    var body: some View {
        Group {
            if !store.hasLoaded {
                LoadingState(message: "Loading dashboard…")
            } else if let profile = store.selectedProfile, profile.isRunning {
                content(profile)
            } else if store.selectedProfileIsBusy {
                LoadingState(message: "Waiting for Colima…")
            } else if store.profiles.isEmpty {
                EmptyState(systemImage: "gauge.with.dots.needle.0percent", title: "Let's start Colima",
                           message: "There's no Colima VM yet. Starting one downloads a small Linux image the first time, which takes a minute or two.") {
                    Button("Start Colima") { Task { await store.startProfile("default") } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Choose settings…") { navigate(.profiles) }
                }
            } else if let profile = store.selectedProfile {
                EmptyState(systemImage: "gauge.with.dots.needle.0percent", title: "\(profile.name) isn't running",
                           message: "Start it to see its containers and resources.") {
                    Button("Start \(profile.name)") { Task { await store.startProfile(profile.name) } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                LoadingState(message: "Loading…")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.hasLoaded)
        .navigationTitle("Dashboard")
        .confirm($pendingAction)
    }

    private func content(_ profile: ColimaProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(profile)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], spacing: 12) {
                    cpuTile(profile)
                    memoryTile(profile)
                    diskTile
                    containersTile
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], spacing: 12) {
                    topContainers
                    diskUsage
                }
                stacks
                attention
            }
            .padding(16)
        }
    }

    // MARK: Header

    private func header(_ profile: ColimaProfile) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: profile.status.color)
            Text(profile.name).font(.title3.weight(.medium))
            Text("\(profile.runtime) · \(profile.arch) · \(profile.cpus) CPU · \(Format.bytes(profile.memoryBytes)) RAM")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Restart VM") {
                pendingAction = DeleteRequest(title: "Restart \(profile.name)?",
                                              message: "The VM restarts and its containers stop for a moment.",
                                              confirmLabel: "Restart") { await store.restartProfile(profile.name) }
            }
            pruneMenu
        }
    }

    private var pruneMenu: some View {
        Menu("Prune") {
            if let cache = store.diskUsage?.entry(.buildCache), cache.reclaimableBytes > 0 {
                Button("Build cache · \(Format.bytes(cache.reclaimableBytes)) reclaimable") {
                    confirmPrune(.buildCache, "Prune build cache?", "Cached build layers are deleted. The next build may be slower.")
                }
            } else {
                Button("Build cache") { confirmPrune(.buildCache, "Prune build cache?", "Cached build layers are deleted. The next build may be slower.") }
            }
            Button("Unused images") { confirmPrune(.images, "Prune unused images?", "Dangling images are removed.") }
            Button("Everything unused") {
                confirmPrune(.system, "Prune everything unused?", "Stopped containers, unused networks, dangling images and build cache are removed. Volumes are kept.")
            }
        }
        .fixedSize()
    }

    private func confirmPrune(_ target: ColimaStore.PruneTarget, _ title: String, _ message: String) {
        pendingAction = DeleteRequest(title: title, message: message, confirmLabel: "Prune") { await store.prune(target) }
    }

    // MARK: Tiles

    private func cpuTile(_ profile: ColimaProfile) -> some View {
        let latest = store.history.latest?.cpuPercent
        return Tile(title: "CPU") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(latest.map { String(format: "%.1f%%", $0) } ?? "–").font(.title2.weight(.medium)).monospacedDigit()
                Text("of \(profile.cpus) cores").font(.caption).foregroundStyle(.secondary)
            }
            Sparkline(values: store.history.samples.map(\.cpuPercent), maxValue: nil, color: .blue)
        }
    }

    private func memoryTile(_ profile: ColimaProfile) -> some View {
        let latest = store.history.latest?.memoryBytes
        return Tile(title: "Memory") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(latest.map { Format.bytes($0) } ?? "–").font(.title2.weight(.medium)).monospacedDigit()
                Text("of \(Format.bytes(profile.memoryBytes))").font(.caption).foregroundStyle(.secondary)
            }
            Sparkline(values: store.history.samples.map { Double($0.memoryBytes) }, maxValue: nil, color: .purple)
        }
    }

    private var diskTile: some View {
        Tile(title: "VM disk") {
            if let disk = store.vmDisk {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.bytes(disk.usedBytes)).font(.title2.weight(.medium)).monospacedDigit()
                    Text("of \(Format.bytes(disk.totalBytes))").font(.caption).foregroundStyle(.secondary)
                }
                UsageBar(fraction: disk.usedFraction, color: disk.usedFraction >= Attention.diskWarningFraction ? .orange : .blue)
                    .padding(.top, 6)
                Text("\(Format.bytes(disk.freeBytes)) free").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("–").font(.title2.weight(.medium))
                Text("Couldn't read the VM disk.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var containersTile: some View {
        Tile(title: "Containers") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(store.runningContainerCount)").font(.title2.weight(.medium)).monospacedDigit()
                Text("of \(store.containers.count) running").font(.caption).foregroundStyle(.secondary)
            }
            let standalone = store.containers.filter { $0.composeProject == nil }.count
            Text("\(store.stackCount) stack\(store.stackCount == 1 ? "" : "s") · \(standalone) standalone")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
    }

    // MARK: Top containers

    private var topContainers: some View {
        let entries = store.runningStats.map { (c: $0.container, mem: Double(Parsing.parseSize($0.stats.memoryUsage) ?? 0), cpu: $0.stats.cpuPercent) }
        let sorted = entries.sorted { topSort == .memory ? $0.mem > $1.mem : $0.cpu > $1.cpu }.prefix(6)
        let peak = max(sorted.map { topSort == .memory ? $0.mem : $0.cpu }.max() ?? 1, 0.0001)
        return Card {
            HStack {
                Text("Top containers").font(.headline)
                Spacer()
                Picker("Sort by", selection: $topSort) { ForEach(TopSort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }
            if sorted.isEmpty {
                Text("No running containers.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(sorted), id: \.c.id) { entry in
                let value = topSort == .memory ? entry.mem : entry.cpu
                Button { open(container: entry.c) } label: {
                    HStack(spacing: 10) {
                        Text(entry.c.name).lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading)
                        UsageBar(fraction: value / peak, color: topSort == .memory ? .purple : .blue)
                        Text(topSort == .memory ? Format.bytes(Int64(entry.mem)) : String(format: "%.1f%%", entry.cpu))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(entry.c.name)")
            }
        }
        .animation(.smooth(duration: 0.25), value: topSort)
    }

    // MARK: Disk usage

    private var diskUsage: some View {
        Card {
            Text("Disk usage").font(.headline)
            if let usage = store.diskUsage {
                let palette: [DiskUsageEntry.Kind: Color] = [.images: .blue, .volumes: .purple, .buildCache: .teal, .containers: .orange]
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(usage.entries.filter { $0.sizeBytes > 0 }) { entry in
                            Rectangle().fill(palette[entry.kind] ?? .gray)
                                .frame(width: max(3, geo.size.width * CGFloat(entry.sizeBytes) / CGFloat(max(usage.totalBytes, 1))))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 10)
                ForEach(usage.entries) { entry in
                    HStack(spacing: 8) {
                        Circle().fill(palette[entry.kind] ?? .gray).frame(width: 8, height: 8)
                        Text(entry.title)
                        Spacer()
                        Text("\(entry.totalCount) · \(Format.bytes(entry.sizeBytes))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                HStack {
                    Text("\(Format.bytes(usage.reclaimableBytes)) reclaimable").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Text("Disk usage isn't available yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Stacks

    private var stacks: some View {
        let groups = Grouping.group(store.containers, by: .stack).filter(\.isStack)
        let problemIDs = Set(store.attention.compactMap { item -> String? in
            if case .logs(let id) = item.action { return id } else { return nil }
        })
        return Card {
            Text("Stacks").font(.headline)
            if groups.isEmpty {
                Text("No Compose stacks running.").font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(groups) { group in
                    let hasProblem = group.containers.contains { problemIDs.contains($0.id) }
                    Button { open(group: group) } label: { stackCard(group, hasProblem: hasProblem) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func stackCard(_ group: ContainerGroup, hasProblem: Bool) -> some View {
        let ports = group.containers.flatMap(\.ports).filter { $0.browserURL != nil }
        let memory = group.containers.compactMap { store.stats[$0.id]?.memoryUsage }.compactMap(Parsing.parseSize).reduce(0, +)
        let color: Color = hasProblem ? .orange : (group.runningCount == 0 ? .secondary.opacity(0.6) : .green)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(color: color)
                Text(group.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(group.summary).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(ports.prefix(2).enumerated()), id: \.offset) { _, port in
                    Text("\(port.hostPort ?? port.containerPort) ↗").font(.caption).foregroundStyle(Color.accentColor)
                }
                if memory > 0 { Text(Format.bytes(memory)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(hasProblem ? Color.orange : Color.secondary.opacity(0.25), lineWidth: hasProblem ? 1 : 0.5))
        .contentShape(Rectangle())
    }

    // MARK: Needs attention

    private var attention: some View {
        let items = store.attention
        return Card {
            Text("Needs attention").font(.headline)
            if items.isEmpty {
                Label("Everything looks healthy.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(item.severity == .error ? Color.red : Color.orange)
                    Text(item.message)
                    Spacer()
                    switch item.action {
                    case .logs(let id):
                        Button("Logs") {
                            if let c = store.container(id: id) { open(container: c) }
                        }
                        .buttonStyle(.borderless)
                    case .prune:
                        Button("Prune") { confirmPrune(.system, "Prune everything unused?", "Stopped containers, unused networks, dangling images and build cache are removed. Volumes are kept.") }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: Navigation

    private func open(container: Container) {
        store.requestedSelection = "container:\(container.id)"
        navigate(.containers)
    }

    private func open(group: ContainerGroup) {
        store.groupMode = .stack
        store.requestedSelection = "group:\(group.id)"
        navigate(.containers)
    }
}
