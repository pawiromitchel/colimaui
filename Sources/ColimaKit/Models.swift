import Foundation

// MARK: - Colima profiles

public enum ProfileStatus: String, Sendable, Equatable, Codable {
    case running, stopped, unknown

    init(raw: String) {
        switch raw.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
}

public struct ColimaProfile: Identifiable, Sendable, Equatable, Hashable, Codable {
    public var name: String
    public var status: ProfileStatus
    public var arch: String
    public var cpus: Int
    public var memoryBytes: Int64
    public var diskBytes: Int64
    public var runtime: String
    public var address: String
    public var kubernetes: Bool

    public var id: String { name }
    public var isRunning: Bool { status == .running }

    /// Colima names the Docker context `colima` for the default profile and `colima-<name>` otherwise.
    public var dockerContext: String { name == "default" ? "colima" : "colima-\(name)" }

    public var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".colima/\(name)/docker.sock")
    }

    public init(name: String, status: ProfileStatus, arch: String = "", cpus: Int = 0,
                memoryBytes: Int64 = 0, diskBytes: Int64 = 0, runtime: String = "docker",
                address: String = "", kubernetes: Bool = false) {
        self.name = name; self.status = status; self.arch = arch; self.cpus = cpus
        self.memoryBytes = memoryBytes; self.diskBytes = diskBytes; self.runtime = runtime
        self.address = address; self.kubernetes = kubernetes
    }
}

// MARK: - Docker objects

public enum ContainerState: String, Sendable, Equatable, Codable {
    case running, exited, paused, restarting, created, dead, removing, other

    init(raw: String) { self = ContainerState(rawValue: raw.lowercased()) ?? .other }
    public var isRunning: Bool { self == .running || self == .restarting }
}

public struct PortMapping: Sendable, Equatable, Hashable, Codable {
    public var hostIP: String?
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: String

    public var isPublished: Bool { hostPort != nil }

    /// A URL to open in the browser, when the port is published over TCP on a reachable address.
    public var browserURL: URL? {
        guard let hostPort, proto == "tcp" else { return nil }
        return URL(string: "http://localhost:\(hostPort)")
    }

    public var label: String {
        if let hostPort { return "\(hostPort):\(containerPort)" }
        return "\(containerPort)"
    }
}

public struct Container: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    public var state: ContainerState
    public var status: String
    public var ports: [PortMapping]
    public var labels: [String: String]
    public var createdAt: String

    public init(id: String, name: String, image: String, state: ContainerState, status: String = "",
                ports: [PortMapping] = [], labels: [String: String] = [:], createdAt: String = "") {
        self.id = id; self.name = name; self.image = image; self.state = state; self.status = status
        self.ports = ports; self.labels = labels; self.createdAt = createdAt
    }

    public var isRunning: Bool { state.isRunning }
    public var composeProject: String? { labels["com.docker.compose.project"].flatMap { $0.isEmpty ? nil : $0 } }
    public var composeService: String? { labels["com.docker.compose.service"] }
    public var composeWorkingDir: String? { labels["com.docker.compose.project.working_dir"] }
    public var composeConfigFiles: [String] {
        (labels["com.docker.compose.project.config_files"] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    /// Short name shown inside a stack: the compose service when there is one.
    public var displayName: String { composeService ?? name }
}

public struct DockerImage: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var repository: String
    public var tag: String
    public var size: String
    public var createdSince: String

    public init(id: String, repository: String, tag: String, size: String = "", createdSince: String = "") {
        self.id = id; self.repository = repository; self.tag = tag; self.size = size; self.createdSince = createdSince
    }

    public var reference: String {
        if repository == "<none>" { return String(id.prefix(12)) }
        return tag == "<none>" ? repository : "\(repository):\(tag)"
    }
    public var isDangling: Bool { repository == "<none>" }

    /// True when a container's `Image` column refers to this image.
    public func matches(containerImage: String) -> Bool {
        if containerImage == reference || containerImage == repository && tag == "latest" { return true }
        let ref = containerImage.replacingOccurrences(of: "sha256:", with: "")
        return ref.count >= 6 && (id.hasPrefix(ref) || ref.hasPrefix(id))
    }
}

public struct DockerVolume: Identifiable, Sendable, Equatable, Hashable {
    public var name: String
    public var driver: String
    public var labels: [String: String]
    public var id: String { name }
    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var isAnonymous: Bool { labels["com.docker.volume.anonymous"] != nil }
    public init(name: String, driver: String = "local", labels: [String: String] = [:]) {
        self.name = name; self.driver = driver; self.labels = labels
    }
}

public struct DockerNetwork: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var driver: String
    public var scope: String
    public var labels: [String: String]
    public var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
    public init(id: String, name: String, driver: String, scope: String = "local", labels: [String: String] = [:]) {
        self.id = id; self.name = name; self.driver = driver; self.scope = scope; self.labels = labels
    }
}

public struct ContainerStats: Sendable, Equatable {
    public var id: String
    public var name: String
    public var cpuPercent: Double
    public var memoryUsage: String
    public var memoryPercent: Double
    public init(id: String, name: String, cpuPercent: Double, memoryUsage: String, memoryPercent: Double) {
        self.id = id; self.name = name; self.cpuPercent = cpuPercent
        self.memoryUsage = memoryUsage; self.memoryPercent = memoryPercent
    }
}
