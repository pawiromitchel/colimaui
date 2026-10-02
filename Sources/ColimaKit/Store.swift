import Foundation
import Observation

public struct ActivityEntry: Identifiable, Sendable, Equatable {
    public enum Level: Sendable { case info, error }
    public let id = UUID()
    public var date = Date()
    public var level: Level
    public var message: String
}

/// Central app state. Everything the UI shows is refreshed from Colima/Docker through here.
@MainActor
@Observable
public final class ColimaStore {
    public private(set) var profiles: [ColimaProfile] = []
    public private(set) var containers: [Container] = []
    public private(set) var images: [DockerImage] = []
    public private(set) var volumes: [DockerVolume] = []
    public private(set) var networks: [DockerNetwork] = []
    public private(set) var stats: [String: ContainerStats] = [:]
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var busyProfiles: Set<String> = []
    public private(set) var busyContainerIDs: Set<String> = []
    public private(set) var activeContext: String?
    public private(set) var lastRefresh: Date?
    public private(set) var toolMissing: String?
    public private(set) var prerequisites = Prerequisites.ready
    public private(set) var diskUsage: DockerDiskUsage?
    public private(set) var vmDisk: VMDisk?
    public private(set) var history = MetricsHistory()

    /// Set by the dashboard to open a container (`container:<id>`) or stack (`group:<id>`) on the Containers page.
    public var requestedSelection: String?

    /// A short message the window shows briefly, like "Started shop".
    public struct Notice: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public var text: String
        public var isError = false
    }
    public private(set) var notice: Notice?

    public var selectedProfileName: String = "default"
    public var groupMode: GroupMode = .stack
    public var searchText: String = ""

    @ObservationIgnored public let colima: ColimaClient
    @ObservationIgnored private let runner: CommandRunning
    @ObservationIgnored private let checkPrerequisites: @Sendable () -> Prerequisites
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastDiskRefresh: Date?
    @ObservationIgnored private var historyProfile: String?
    public static let diskRefreshInterval: TimeInterval = 30

    public init(runner: CommandRunning = ProcessRunner(),
                prerequisites: @escaping @Sendable () -> Prerequisites = { Prerequisites.check() }) {
        self.runner = runner
        self.checkPrerequisites = prerequisites
        self.colima = ColimaClient(runner: runner)
    }

    // MARK: Derived

    public var selectedProfile: ColimaProfile? {
        profiles.first { $0.name == selectedProfileName } ?? profiles.first
    }

    public var docker: DockerClient? {
        guard let p = selectedProfile, p.isRunning else { return nil }
        return DockerClient(profile: p, runner: runner)
    }

    public var groups: [ContainerGroup] {
        Grouping.group(Grouping.filter(containers, query: searchText), by: groupMode)
    }

    /// False until the first refresh finishes, so the UI can show a spinner instead of empty lists.
    public var hasLoaded: Bool { lastRefresh != nil }

    /// What the selected profile is busy with, if anything (start, stop or delete in progress).
    public var selectedProfileIsBusy: Bool {
        selectedProfile.map { busyProfiles.contains($0.name) } ?? false
    }

    public var attention: [AttentionItem] { Attention.items(containers: containers, vmDisk: vmDisk) }

    public var stackCount: Int { Set(containers.compactMap(\.composeProject)).count }

    public var runningStats: [(container: Container, stats: ContainerStats)] {
        containers.filter(\.isRunning).compactMap { c in stats[c.id].map { (c, $0) } }
    }

    public var runningContainerCount: Int { containers.filter(\.isRunning).count }

    public func container(id: String) -> Container? { containers.first { $0.id == id } }

    public func containers(using image: DockerImage) -> [Container] {
        Grouping.containers(using: image, in: containers)
    }

    // MARK: Refresh

    public func startAutoRefresh(interval: Duration = .seconds(4)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopAutoRefresh() { refreshTask?.cancel(); refreshTask = nil }

    public func refresh() async {
        // Without colima and docker there's nothing to ask, so skip the commands and let the UI explain.
        prerequisites = checkPrerequisites()
        guard prerequisites.isReady else {
            profiles = []; containers = []; images = []; volumes = []; networks = []; stats = [:]
            diskUsage = nil; vmDisk = nil; history.reset()
            lastRefresh = Date()
            return
        }
        await refreshProfiles()
        activeContext = await colima.currentContext()
        guard let client = docker else {
            containers = []; images = []; volumes = []; networks = []; stats = [:]
            diskUsage = nil; vmDisk = nil; lastDiskRefresh = nil; history.reset()
            lastRefresh = Date()
            return
        }
        async let c = capture { try await client.containers() }
        async let i = capture { try await client.images() }
        async let v = capture { try await client.volumes() }
        async let n = capture { try await client.networks() }
        async let s = capture { try await client.stats() }
        let (cs, im, vo, ne) = await (c, i, v, n)
        if let cs { containers = cs }
        if let im { images = im }
        if let vo { volumes = vo }
        if let ne { networks = ne }
        // Lists are ready: show them now. `docker stats` is slow, so its numbers fill in afterwards.
        lastRefresh = Date()
        if let st = await s { stats = Dictionary(st.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        recordSample()
        await refreshDisk()
    }

    /// Adds a CPU/memory point for the sparklines. CPU is shown as a share of the whole VM.
    func recordSample() {
        guard let profile = selectedProfile else { return }
        if historyProfile != profile.name { history.reset(); historyProfile = profile.name }
        let values = stats.values
        let cpu = values.reduce(0) { $0 + $1.cpuPercent } / Double(max(profile.cpus, 1))
        let memory = values.compactMap { Parsing.parseSize($0.memoryUsage) }.reduce(0, +)
        history.append(MetricSample(cpuPercent: min(cpu, 100), memoryBytes: memory))
    }

    /// Disk numbers are slower to gather than stats, so they refresh on their own, slower, schedule.
    public func refreshDisk(force: Bool = false) async {
        guard let client = docker, let profile = selectedProfile else { return }
        if !force, let last = lastDiskRefresh, Date().timeIntervalSince(last) < Self.diskRefreshInterval { return }
        lastDiskRefresh = Date()
        async let usage = try? await client.diskUsage()
        async let disk = colima.vmDisk(profile: profile.name)
        let (u, d) = await (usage, disk)
        if let u { diskUsage = u }
        vmDisk = d
    }

    public func refreshProfiles() async {
        do {
            profiles = try await colima.profiles()
            toolMissing = nil
            if !profiles.contains(where: { $0.name == selectedProfileName }),
               let first = profiles.first(where: \.isRunning) ?? profiles.first {
                selectedProfileName = first.name
            }
        } catch let error as CommandError where error.exitCode == 127 {
            toolMissing = error.localizedDescription
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> T? {
        do { return try await body() } catch {
            log(.error, error.localizedDescription)
            return nil
        }
    }

    // MARK: Profile actions

    public func startProfile(_ name: String, options: StartOptions = .init()) async {
        guard busyProfiles.insert(name).inserted else { return }
        log(.info, "Starting \(name)…")
        defer { busyProfiles.remove(name) }
        do {
            for try await line in colima.start(profile: name, options: options) { log(.info, Self.stripLogPrefix(line)) }
            log(.info, "Started \(name)")
        } catch { log(.error, "Couldn't start \(name): \(error.localizedDescription)") }
        await refresh()
    }

    public func stopProfile(_ name: String) async {
        guard busyProfiles.insert(name).inserted else { return }
        log(.info, "Stopping \(name)…")
        defer { busyProfiles.remove(name) }
        do { try await colima.stop(profile: name); log(.info, "Stopped \(name)") }
        catch { log(.error, "Couldn't stop \(name): \(error.localizedDescription)") }
        await refresh()
    }

    public func restartProfile(_ name: String, options: StartOptions = .init()) async {
        await stopProfile(name)
        await startProfile(name, options: options)
    }

    public func deleteProfile(_ name: String) async {
        guard busyProfiles.insert(name).inserted else { return }
        defer { busyProfiles.remove(name) }
        do { try await colima.delete(profile: name); log(.info, "Deleted \(name)") }
        catch { log(.error, "Couldn't delete \(name): \(error.localizedDescription)") }
        await refresh()
    }

    public func useContext(_ profile: ColimaProfile) async {
        do { try await colima.useContext(profile: profile); log(.info, "Docker context is now \(profile.dockerContext)") }
        catch { log(.error, error.localizedDescription) }
        activeContext = await colima.currentContext()
    }

    // MARK: Container actions

    public func perform(_ action: ContainerAction, on ids: [String]) async {
        guard let client = docker, !ids.isEmpty else { return }
        busyContainerIDs.formUnion(ids)
        defer { busyContainerIDs.subtract(ids) }
        do { try await client.perform(action, ids: ids) }
        catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    /// Applies `action` to the members of a stack or image group that it makes sense for.
    public func perform(_ action: ContainerAction, on group: ContainerGroup) async {
        let ids: [String]
        switch action {
        case .start: ids = group.containers.filter { !$0.isRunning }.map(\.id)
        case .stop, .kill, .pause: ids = group.containers.filter(\.isRunning).map(\.id)
        case .restart, .unpause: ids = group.containers.map(\.id)
        }
        await perform(action, on: ids)
    }

    public func remove(_ ids: [String]) async {
        guard let client = docker, !ids.isEmpty else { return }
        busyContainerIDs.formUnion(ids)
        defer { busyContainerIDs.subtract(ids) }
        do { try await client.remove(ids: ids) } catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    public func composeUp(_ group: ContainerGroup) async {
        guard let client = docker, case .stack(let project, let dir, let files) = group.kind else { return }
        let ids = group.containers.map(\.id)
        busyContainerIDs.formUnion(ids)
        defer { busyContainerIDs.subtract(ids) }
        do { try await client.composeUp(project: project, workingDir: dir, files: files) }
        catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    // MARK: Images, volumes, networks

    public func removeImage(_ image: DockerImage) async {
        guard let client = docker else { return }
        do { try await client.removeImage(image.id) } catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    public func removeVolume(_ volume: DockerVolume) async {
        guard let client = docker else { return }
        do { try await client.removeVolume(volume.name) } catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    public func removeNetwork(_ network: DockerNetwork) async {
        guard let client = docker else { return }
        do { try await client.removeNetwork(network.id) } catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    public enum PruneTarget: Sendable { case images, volumes, buildCache, system }

    public func prune(_ target: PruneTarget) async {
        guard let client = docker else { return }
        do {
            let out: String
            switch target {
            case .images: out = try await client.pruneImages()
            case .volumes: out = try await client.pruneVolumes()
            case .buildCache: out = try await client.pruneBuildCache()
            case .system: out = try await client.pruneSystem()
            }
            log(.info, out.split(separator: "\n").last.map(String.init) ?? "Pruned")
        } catch { log(.error, error.localizedDescription) }
        await refresh()
        await refreshDisk(force: true)
    }

    public func pullImage(_ reference: String) async {
        guard let client = docker else { return }
        log(.info, "Pulling \(reference)…")
        do {
            for try await line in client.pull(reference) { log(.info, line) }
        } catch { log(.error, error.localizedDescription) }
        await refresh()
    }

    // MARK: Logging

    public func log(_ level: ActivityEntry.Level, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activity.append(ActivityEntry(level: level, message: trimmed))
        if activity.count > 300 { activity.removeFirst(activity.count - 300) }
    }

    public func post(_ text: String, isError: Bool = false) {
        notice = Notice(text: text, isError: isError)
        log(isError ? .error : .info, text)
    }

    public func dismissNotice(_ id: UUID) { if notice?.id == id { notice = nil } }

    public func clearActivity() { activity.removeAll() }

    /// Colima prints `time="..." level=info msg="..."`; show only the message.
    nonisolated static func stripLogPrefix(_ line: String) -> String {
        guard let range = line.range(of: "msg=\"") else { return line }
        let rest = line[range.upperBound...]
        return String(rest.dropLast(rest.hasSuffix("\"") ? 1 : 0))
    }
}
