import Foundation

// MARK: - Finding the compose file

/// The compose files behind something dropped on the window.
public struct ComposeInput: Equatable, Sendable {
    /// Absolute paths, base file first and overrides after it, in the order compose should read them.
    public var files: [String]
    /// The folder of the first file. Relative paths and `.env` resolve from here.
    public var workingDir: String
    public var suggestedName: String

    public init(files: [String], workingDir: String, suggestedName: String) {
        self.files = files; self.workingDir = workingDir; self.suggestedName = suggestedName
    }
}

public enum ComposeLocator {
    /// Compose's own lookup order.
    static let baseNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let overrideNames = ["compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml"]

    /// Accepts compose files, or folders that contain one. Returns nil when nothing dropped looks like a compose file.
    public static func resolve(_ urls: [URL]) -> ComposeInput? {
        let fm = FileManager.default
        var files: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                guard let base = baseNames.first(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) else { return nil }
                files.append(url.appendingPathComponent(base).path)
                // Only the override that goes with the base file's naming family is picked up by compose.
                let family = base.hasPrefix("docker-compose") ? "docker-compose" : "compose"
                if let over = overrideNames.first(where: { $0.hasPrefix(family) && fm.fileExists(atPath: url.appendingPathComponent($0).path) }) {
                    files.append(url.appendingPathComponent(over).path)
                }
            } else {
                files.append(url.path)
            }
        }
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }
        guard !files.isEmpty, files.allSatisfy(looksLikeCompose) else { return nil }
        // Overrides go last, whatever order they were dropped in.
        files = files.filter { !isOverride($0) } + files.filter(isOverride)
        let dir = (files[0] as NSString).deletingLastPathComponent
        return ComposeInput(files: files, workingDir: dir, suggestedName: sanitizedName((dir as NSString).lastPathComponent))
    }

    static func isOverride(_ path: String) -> Bool { (path as NSString).lastPathComponent.contains(".override.") }

    /// A YAML file with a top-level `services:` key. Compose itself does the real validation later.
    static func looksLikeCompose(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "yml" || ext == "yaml",
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 65_536), as: UTF8.self)
        return head.range(of: #"(?m)^services\s*:"#, options: .regularExpression) != nil
    }

    /// Compose project names are lowercase letters, digits, dashes and underscores, and start with a letter or digit.
    public static func sanitizedName(_ raw: String) -> String {
        var name = raw.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? String($0) : "-" }.joined()
        while let first = name.first, !(first.isLetter || first.isNumber) { name.removeFirst() }
        return name.isEmpty ? "stack" : name
    }

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }
}

// MARK: - The plan shown before anything runs

public struct ComposePort: Equatable, Sendable, Hashable {
    public var published: Int?
    public var target: Int
    public var proto: String
    public var browserURL: URL? { published.flatMap { proto == "tcp" ? URL(string: "http://localhost:\($0)") : nil } }
}

public struct ComposeBind: Equatable, Sendable, Hashable {
    public var source: String
    public var target: String
}

public struct ComposeService: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable { case build, pull, local }
    public var name: String
    public var image: String?
    public var buildContext: String?
    public var ports: [ComposePort]
    public var binds: [ComposeBind]
    public var privileged: Bool
    public var action: Action
    public var id: String { name }
}

public struct ComposePlan: Equatable, Sendable {
    public var input: ComposeInput
    public var services: [ComposeService]
    public var warnings: [String]
    /// How many variables the `.env` file next to the compose file defines, if there is one.
    public var envVariableCount: Int?

    public var buildCount: Int { services.filter { $0.action == .build }.count }
    public var browserPorts: [ComposePort] { services.flatMap(\.ports).filter { $0.browserURL != nil } }
    public var binds: [ComposeBind] { services.flatMap(\.binds) }

    /// Parses `docker compose config --format json`. `stderr` carries compose's warnings, such as unset variables.
    public static func parse(configJSON: String, stderr: String, input: ComposeInput, localImages: [DockerImage]) throws -> ComposePlan {
        guard let data = configJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["services"] as? [String: [String: Any]] else {
            throw CommandError(command: "docker compose config", exitCode: 1, message: "Compose returned something ColimaUI couldn't read.")
        }
        let services: [ComposeService] = raw.keys.sorted().map { name in
            let s = raw[name] ?? [:]
            let image = s["image"] as? String
            let build = s["build"] as? [String: Any]
            let ports = (s["ports"] as? [[String: Any]] ?? []).compactMap(port)
            let binds = (s["volumes"] as? [[String: Any]] ?? []).compactMap { v -> ComposeBind? in
                guard v["type"] as? String == "bind", let source = v["source"] as? String, let target = v["target"] as? String else { return nil }
                return ComposeBind(source: source, target: target)
            }
            let action: ComposeService.Action = build != nil ? .build
                : (image.map { ref in localImages.contains { $0.matches(containerImage: ref) } } == true ? .local : .pull)
            return ComposeService(name: name, image: image, buildContext: build?["context"] as? String, ports: ports, binds: binds,
                                  privileged: s["privileged"] as? Bool ?? false, action: action)
        }

        var warnings = composeWarnings(from: stderr)
        for s in services where s.privileged { warnings.append("\(s.name) runs privileged, which gives it broad access to the VM.") }
        let builds = services.filter { $0.action == .build }.count
        if builds > 0 {
            warnings.append("\(builds) service\(builds == 1 ? " builds" : "s build") from source, which can take a few minutes the first time.")
        }
        return ComposePlan(input: input, services: services, warnings: warnings, envVariableCount: envVariableCount(in: input.workingDir))
    }

    private static func port(_ p: [String: Any]) -> ComposePort? {
        guard let target = (p["target"] as? NSNumber)?.intValue ?? Int("\(p["target"] ?? "")") else { return nil }
        // `published` is a string in compose's JSON, and may be a range like "8000-8010".
        let published: Int? = (p["published"] as? NSNumber)?.intValue
            ?? (p["published"] as? String).flatMap { Int($0.split(separator: "-").first ?? "") }
        return ComposePort(published: published, target: target, proto: p["protocol"] as? String ?? "tcp")
    }

    /// Pulls the message out of compose's `time=… level=warning msg="…"` lines.
    static func composeWarnings(from stderr: String) -> [String] {
        stderr.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.contains("level=warning"), let r = line.range(of: #"msg=""#) else { return nil }
            var msg = String(line[r.upperBound...])
            if msg.hasSuffix("\"") { msg.removeLast() }
            return msg.replacingOccurrences(of: "\\\"", with: "\"")
        }
    }

    static func envVariableCount(in dir: String) -> Int? {
        guard let text = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).filter {
            $0.range(of: #"^\s*[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) != nil
        }.count
    }

    /// Compose's error output without its warning lines.
    static func composeError(from stderr: String) -> String {
        stderr.split(whereSeparator: \.isNewline)
            .filter { !$0.contains("level=warning") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Progress while `up` runs

/// Turns compose's plain progress output into a short checklist, and keeps the raw lines for the log.
public struct ComposeProgress: Equatable, Sendable {
    public enum State: Sendable { case pending, running, done, failed }
    public struct Stage: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var state: State = .pending
        public var detail: String?
        public var fraction: Double?
    }

    public private(set) var stages: [Stage]
    public private(set) var log: [String] = []
    private let project: String
    private let services: [ComposeService]

    public init(plan: ComposePlan, project: String) {
        self.project = project
        services = plan.services
        var stages: [Stage] = []
        for s in plan.services where s.action == .pull { stages.append(Stage(id: "pull:\(s.name)", title: "Pull \(s.image ?? s.name)")) }
        for s in plan.services where s.action == .build { stages.append(Stage(id: "build:\(s.name)", title: "Build \(s.name)")) }
        stages.append(Stage(id: "start", title: "Create the network and start services"))
        self.stages = stages
    }

    public var failedMessage: String? { log.last { $0.contains("Error") } }

    public mutating func apply(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }

        let words = line.split(separator: " ").map(String.init)
        if words.count >= 3, words[0] == "Image" {
            let ref = words[1]
            let verb = words[2]
            if let id = stageID(forImage: ref) {
                switch verb {
                case "Pulling", "Building": set(id, .running)
                case "Pulled", "Built": set(id, .done)
                case "Error": set(id, .failed)
                default: break
                }
            }
        } else if words.count >= 3, words[0] == "Network" || words[0] == "Container" {
            if ["Creating", "Created", "Starting", "Started", "Running"].contains(words[2]) { set("start", .running) }
            if words[0] == "Container", words[2] == "Error" { set("start", .failed) }
        } else if let step = buildStep(line) {
            let id = stages.first { $0.id.hasPrefix("build:") && $0.state == .running }?.id
                ?? stages.first { $0.id.hasPrefix("build:") && $0.state == .pending }?.id
            if let id, let i = stages.firstIndex(where: { $0.id == id }) {
                stages[i].state = .running
                stages[i].detail = "step \(step.current)/\(step.total)"
                stages[i].fraction = Double(step.current) / Double(max(step.total, 1))
            }
        }
    }

    /// Marks everything finished, or whatever was still going as failed.
    public mutating func finish(success: Bool) {
        for i in stages.indices {
            if success { stages[i].state = .done; stages[i].fraction = nil }
            else if stages[i].state == .running { stages[i].state = .failed }
        }
    }

    private mutating func set(_ id: String, _ state: State) {
        guard let i = stages.firstIndex(where: { $0.id == id }) else { return }
        stages[i].state = state
        if state == .done { stages[i].fraction = nil; stages[i].detail = nil }
    }

    /// Compose names a built image `<project>-<service>` unless the service sets `image:`.
    private func stageID(forImage ref: String) -> String? {
        for s in services {
            let names = ["\(project)-\(s.name)", s.image].compactMap { $0 }
            let normalised = ref.replacingOccurrences(of: "docker.io/library/", with: "").replacingOccurrences(of: "docker.io/", with: "")
            if names.contains(where: { $0 == ref || $0 == normalised || $0 + ":latest" == ref || $0 + ":latest" == normalised }) {
                return s.action == .build ? "build:\(s.name)" : "pull:\(s.name)"
            }
        }
        return nil
    }

    private func buildStep(_ line: String) -> (current: Int, total: Int)? {
        guard let r = line.range(of: #"\[(?:[A-Za-z0-9_.-]+ )?(\d+)/(\d+)\]"#, options: .regularExpression) else { return nil }
        let nums = line[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        return nums.count >= 2 ? (nums[nums.count - 2], nums[nums.count - 1]) : nil
    }
}
