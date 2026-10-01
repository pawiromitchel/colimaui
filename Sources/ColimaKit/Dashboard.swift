import Foundation

// MARK: - Disk

public struct DiskUsageEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case images, containers, volumes, buildCache }
    public var kind: Kind
    public var totalCount: Int
    public var activeCount: Int
    public var sizeBytes: Int64
    public var reclaimableBytes: Int64
    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .images: "Images"
        case .containers: "Containers"
        case .volumes: "Volumes"
        case .buildCache: "Build cache"
        }
    }
}

/// What `docker system df` reports.
public struct DockerDiskUsage: Sendable, Equatable {
    public var entries: [DiskUsageEntry]
    public init(entries: [DiskUsageEntry]) { self.entries = entries }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }
    public var reclaimableBytes: Int64 { entries.reduce(0) { $0 + $1.reclaimableBytes } }
    public func entry(_ kind: DiskUsageEntry.Kind) -> DiskUsageEntry? { entries.first { $0.kind == kind } }
}

/// Usage of the VM disk that holds Docker's data.
public struct VMDisk: Sendable, Equatable {
    public var mount: String
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    public var freeBytes: Int64 { max(0, totalBytes - usedBytes) }
    public init(mount: String, totalBytes: Int64, usedBytes: Int64) {
        self.mount = mount; self.totalBytes = totalBytes; self.usedBytes = usedBytes
    }
}

// MARK: - History

public struct MetricSample: Sendable, Equatable {
    public var date: Date
    /// Share of the VM's total CPU, 0...100.
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public init(date: Date = Date(), cpuPercent: Double, memoryBytes: Int64) {
        self.date = date; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

/// A fixed-size window of recent samples for the dashboard sparklines.
public struct MetricsHistory: Sendable, Equatable {
    public private(set) var samples: [MetricSample] = []
    public let capacity: Int
    public init(capacity: Int = 60) { self.capacity = max(2, capacity) }

    public mutating func append(_ sample: MetricSample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func reset() { samples.removeAll() }
    public var latest: MetricSample? { samples.last }
}

// MARK: - Attention

public struct AttentionItem: Identifiable, Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case warning = 1, error = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Action: Sendable, Equatable { case logs(containerID: String), prune }

    public var id: String
    public var severity: Severity
    public var message: String
    public var action: Action
}

public enum Attention {
    public static let diskWarningFraction = 0.8
    /// Exit codes produced by a normal `docker stop` (SIGTERM, then SIGKILL), which aren't crashes.
    static let expectedExitCodes: Set<Int> = [0, 137, 143]

    public static func items(containers: [Container], vmDisk: VMDisk?) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for c in containers {
            switch c.state {
            case .dead:
                items.append(.init(id: "dead:\(c.id)", severity: .error, message: "\(c.name) is dead", action: .logs(containerID: c.id)))
            case .restarting:
                items.append(.init(id: "restart:\(c.id)", severity: .error, message: "\(c.name) keeps restarting", action: .logs(containerID: c.id)))
            case .exited:
                if let code = Parsing.exitCode(fromStatus: c.status), !expectedExitCodes.contains(code) {
                    items.append(.init(id: "exit:\(c.id)", severity: .warning, message: "\(c.name) exited with code \(code)", action: .logs(containerID: c.id)))
                }
            default: break
            }
        }
        if let disk = vmDisk, disk.usedFraction >= diskWarningFraction {
            items.append(.init(id: "disk", severity: .warning,
                               message: "VM disk is \(Int((disk.usedFraction * 100).rounded()))% full", action: .prune))
        }
        return items.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.message < $1.message }
    }
}

// MARK: - Parsing

extension Parsing {
    /// `docker system df --format '{{json .}}'`
    public static func diskUsage(from text: String) -> DockerDiskUsage? {
        let entries: [DiskUsageEntry] = jsonLines(text).compactMap { obj in
            let kind: DiskUsageEntry.Kind
            switch obj["Type"] as? String {
            case "Images": kind = .images
            case "Containers": kind = .containers
            case "Local Volumes": kind = .volumes
            case "Build Cache": kind = .buildCache
            default: return nil
            }
            let reclaimable = (obj["Reclaimable"] as? String ?? "").split(separator: "(").first.map(String.init) ?? ""
            return DiskUsageEntry(
                kind: kind,
                totalCount: Int(obj["TotalCount"] as? String ?? "") ?? 0,
                activeCount: Int(obj["Active"] as? String ?? "") ?? 0,
                sizeBytes: parseSize(obj["Size"] as? String ?? "") ?? 0,
                reclaimableBytes: parseSize(reclaimable) ?? 0)
        }
        return entries.isEmpty ? nil : DockerDiskUsage(entries: entries)
    }

    /// `df -k` run inside the VM. Docker's data sits on the extra disk mounted at `/mnt/lima-<profile>`;
    /// the root filesystem is only the small boot image, so prefer that mount.
    public static func vmDisk(from text: String) -> VMDisk? {
        var rows: [(mount: String, total: Int64, used: Int64)] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 6, let total = Int64(cols[1]), let used = Int64(cols[2]) else { continue }
            rows.append((cols[5...].joined(separator: " "), total * 1024, used * 1024))
        }
        let row = rows.first { $0.mount.hasPrefix("/mnt/lima-") && $0.mount != "/mnt/lima-cidata" }
            ?? rows.first { $0.mount == "/" }
        return row.map { VMDisk(mount: $0.mount, totalBytes: $0.total, usedBytes: $0.used) }
    }

    /// "Exited (1) 2 hours ago" -> 1
    public static func exitCode(fromStatus status: String) -> Int? {
        guard status.hasPrefix("Exited"), let open = status.firstIndex(of: "("),
              let close = status.firstIndex(of: ")"), open < close else { return nil }
        return Int(status[status.index(after: open)..<close])
    }
}
