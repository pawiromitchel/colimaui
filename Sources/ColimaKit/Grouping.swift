import Foundation

public enum GroupMode: String, CaseIterable, Sendable, Identifiable {
    case stack = "Stack", image = "Image", none = "None"
    public var id: String { rawValue }
}

public struct ContainerGroup: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case stack(project: String, workingDir: String?, configFiles: [String])
        case image
        case standalone
        case flat
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var containers: [Container]

    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var summary: String { "\(runningCount)/\(containers.count)" }
    public var allRunning: Bool { !containers.isEmpty && runningCount == containers.count }
    public var isStack: Bool { if case .stack = kind { return true } else { return false } }
    public var projectName: String? { if case .stack(let p, _, _) = kind { return p } else { return nil } }

    /// Whether `docker compose up` can be run: the working directory and every config file still exist.
    public var canComposeUp: Bool {
        guard case .stack(_, let dir, let files) = kind, let dir, !files.isEmpty else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir) && files.allSatisfy { fm.fileExists(atPath: $0) }
    }
}

public enum Grouping {
    public static func group(_ containers: [Container], by mode: GroupMode) -> [ContainerGroup] {
        let sorted = containers.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        switch mode {
        case .none:
            return [ContainerGroup(id: "all", title: "All containers", kind: .flat, containers: sorted)]
        case .image:
            return Dictionary(grouping: sorted, by: \.image)
                .map { ContainerGroup(id: "image:\($0.key)", title: $0.key, kind: .image, containers: $0.value) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .stack:
            var stacks: [String: [Container]] = [:]
            var standalone: [Container] = []
            for c in sorted {
                if let project = c.composeProject { stacks[project, default: []].append(c) } else { standalone.append(c) }
            }
            var groups = stacks.map { project, members -> ContainerGroup in
                let first = members.first
                return ContainerGroup(
                    id: "stack:\(project)", title: project,
                    kind: .stack(project: project, workingDir: first?.composeWorkingDir,
                                 configFiles: first?.composeConfigFiles ?? []),
                    containers: members)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !standalone.isEmpty {
                groups.append(ContainerGroup(id: "standalone", title: "Standalone", kind: .standalone, containers: standalone))
            }
            return groups
        }
    }

    public static func filter(_ containers: [Container], query: String) -> [Container] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return containers }
        return containers.filter {
            $0.name.lowercased().contains(q) || $0.image.lowercased().contains(q)
                || ($0.composeProject?.lowercased().contains(q) ?? false)
                || $0.ports.contains { $0.label.contains(q) }
        }
    }

    /// Containers that use `image`.
    public static func containers(using image: DockerImage, in containers: [Container]) -> [Container] {
        containers.filter { image.matches(containerImage: $0.image) }
    }

    /// Containers that mount `volume`, by compose project label as the best cheap signal.
    public static func volumeOwner(_ volume: DockerVolume, in containers: [Container]) -> [Container] {
        guard let project = volume.composeProject else { return [] }
        return containers.filter { $0.composeProject == project }
    }
}
