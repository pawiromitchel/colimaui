import Foundation

// MARK: - Colima

public struct StartOptions: Sendable, Equatable {
    public var cpus: Int?
    public var memoryGiB: Int?
    public var diskGiB: Int?
    public var runtime: String?
    public var vmType: String?
    public var rosetta: Bool?
    public var kubernetes: Bool?

    public init(cpus: Int? = nil, memoryGiB: Int? = nil, diskGiB: Int? = nil, runtime: String? = nil,
                vmType: String? = nil, rosetta: Bool? = nil, kubernetes: Bool? = nil) {
        self.cpus = cpus; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB; self.runtime = runtime
        self.vmType = vmType; self.rosetta = rosetta; self.kubernetes = kubernetes
    }

    var arguments: [String] {
        var args: [String] = []
        if let cpus { args += ["--cpu", "\(cpus)"] }
        if let memoryGiB { args += ["--memory", "\(memoryGiB)"] }
        if let diskGiB { args += ["--disk", "\(diskGiB)"] }
        if let runtime { args += ["--runtime", runtime] }
        if let vmType { args += ["--vm-type", vmType] }
        if let rosetta { args += rosetta ? ["--vz-rosetta"] : ["--vz-rosetta=false"] }
        if let kubernetes { args += kubernetes ? ["--kubernetes"] : ["--kubernetes=false"] }
        return args
    }
}

public struct ColimaClient: Sendable {
    public let runner: CommandRunning
    public init(runner: CommandRunning = ProcessRunner()) { self.runner = runner }

    public func profiles() async throws -> [ColimaProfile] {
        let out = try await runner.runChecked("colima", arguments: ["list", "--json"])
        return Parsing.profiles(from: out)
    }

    public static func startArguments(profile: String, options: StartOptions = .init()) -> [String] {
        ["start", "--profile", profile] + options.arguments
    }

    /// Streams the progress output of `colima start`, which can run for minutes.
    public func start(profile: String, options: StartOptions = .init()) -> AsyncThrowingStream<String, Error> {
        runner.stream("colima", arguments: Self.startArguments(profile: profile, options: options), environment: [:])
    }

    public func stop(profile: String) async throws {
        _ = try await runner.runChecked("colima", arguments: ["stop", "--profile", profile])
    }

    public func delete(profile: String) async throws {
        _ = try await runner.runChecked("colima", arguments: ["delete", "--profile", profile, "--force"])
    }

    public func useContext(profile: ColimaProfile) async throws {
        _ = try await runner.runChecked("docker", arguments: ["context", "use", profile.dockerContext])
    }

    /// Disk usage inside the VM, or nil when the VM can't be reached.
    public func vmDisk(profile: String) async -> VMDisk? {
        guard let out = try? await runner.runChecked("colima", arguments: ["ssh", "--profile", profile, "--", "df", "-k"]) else { return nil }
        return Parsing.vmDisk(from: out)
    }

    public func currentContext() async -> String? {
        guard let out = try? await runner.runChecked("docker", arguments: ["context", "show"]) else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Docker

public enum ContainerAction: String, Sendable {
    case start, stop, restart, kill, pause, unpause
}

public struct DockerClient: Sendable {
    public let runner: CommandRunning
    public let profile: ColimaProfile

    public init(profile: ColimaProfile, runner: CommandRunning = ProcessRunner()) {
        self.profile = profile
        self.runner = runner
    }

    var environment: [String: String] { ["DOCKER_HOST": "unix://\(profile.socketPath)"] }

    private func docker(_ args: [String]) async throws -> String {
        try await runner.runChecked("docker", arguments: args, environment: environment)
    }

    public func containers() async throws -> [Container] {
        Parsing.containers(from: try await docker(["ps", "-a", "--format", "{{json .}}"]))
    }

    public func images() async throws -> [DockerImage] {
        Parsing.images(from: try await docker(["image", "ls", "--format", "{{json .}}"]))
    }

    public func volumes() async throws -> [DockerVolume] {
        Parsing.volumes(from: try await docker(["volume", "ls", "--format", "{{json .}}"]))
    }

    public func networks() async throws -> [DockerNetwork] {
        Parsing.networks(from: try await docker(["network", "ls", "--format", "{{json .}}"]))
    }

    public func stats() async throws -> [ContainerStats] {
        Parsing.stats(from: try await docker(["stats", "--no-stream", "--format", "{{json .}}"]))
    }

    public func perform(_ action: ContainerAction, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await docker([action.rawValue] + ids)
    }

    public func remove(ids: [String], force: Bool = true) async throws {
        guard !ids.isEmpty else { return }
        _ = try await docker(["rm"] + (force ? ["-f"] : []) + ids)
    }

    public func removeImage(_ id: String, force: Bool = false) async throws {
        _ = try await docker(["image", "rm"] + (force ? ["-f"] : []) + [id])
    }

    public func removeVolume(_ name: String) async throws { _ = try await docker(["volume", "rm", name]) }
    public func removeNetwork(_ id: String) async throws { _ = try await docker(["network", "rm", id]) }
    public func pruneImages() async throws -> String { try await docker(["image", "prune", "-f"]) }
    public func pruneVolumes() async throws -> String { try await docker(["volume", "prune", "-f"]) }
    public func pruneBuildCache() async throws -> String { try await docker(["builder", "prune", "-f"]) }
    public func diskUsage() async throws -> DockerDiskUsage? {
        Parsing.diskUsage(from: try await docker(["system", "df", "--format", "{{json .}}"]))
    }
    public func pruneSystem() async throws -> String { try await docker(["system", "prune", "-f"]) }

    public func inspect(_ id: String) async throws -> String {
        try await docker(["inspect", id])
    }

    public func pull(_ reference: String) -> AsyncThrowingStream<String, Error> {
        runner.stream("docker", arguments: ["pull", reference], environment: environment)
    }

    /// Recent log lines, then follows when `follow` is true.
    public func logs(id: String, tail: Int = 200, follow: Bool = true, timestamps: Bool = false) -> AsyncThrowingStream<String, Error> {
        var args = ["logs", "--tail", "\(tail)"]
        if follow { args.append("--follow") }
        if timestamps { args.append("--timestamps") }
        args.append(id)
        return runner.stream("docker", arguments: args, environment: environment)
    }

    // MARK: Compose

    /// How to run compose: the `docker compose` plugin, or the standalone `docker-compose` that
    /// `brew install docker-compose` provides. Homebrew's `docker` formula ships neither.
    public struct ComposeTool: Equatable, Sendable {
        public var executable: String
        public var prefix: [String]
        public static let plugin = ComposeTool(executable: "docker", prefix: ["compose"])
        public static let standalone = ComposeTool(executable: "docker-compose", prefix: [])
    }

    public func composeTool(find: (String) -> String? = { ToolLocator.find($0) }) async -> ComposeTool? {
        if let v = try? await docker(["compose", "version", "--short"]), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plugin
        }
        guard find("docker-compose") != nil,
              let v = try? await runner.runChecked("docker-compose", arguments: ["version", "--short"], environment: environment),
              !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .standalone
    }

    private func composeArgs(_ tool: ComposeTool, project: String, workingDir: String?, files: [String], command: [String]) -> [String] {
        var args = tool.prefix + ["--project-name", project]
        if let workingDir { args += ["--project-directory", workingDir] }
        for f in files { args += ["--file", f] }
        return args + command
    }

    /// Resolves and validates the files. Returns compose's JSON plus its stderr, which carries warnings.
    public func composeConfig(tool: ComposeTool, project: String, workingDir: String, files: [String]) async throws -> (json: String, stderr: String) {
        let args = composeArgs(tool, project: project, workingDir: workingDir, files: files, command: ["config", "--format", "json"])
        let result = try await runner.run(tool.executable, arguments: args, environment: environment)
        guard result.succeeded else {
            let message = ComposePlan.composeError(from: result.stderr)
            throw CommandError(command: "docker compose config", exitCode: result.exitCode, message: message.isEmpty ? result.stdout : message)
        }
        return (result.stdout, result.stderr)
    }

    /// `up -d` with plain, line-per-event progress. Throws if compose exits with an error.
    public func composeUpStream(tool: ComposeTool, project: String, workingDir: String, files: [String]) -> AsyncThrowingStream<String, Error> {
        let args = composeArgs(tool, project: project, workingDir: workingDir, files: files, command: ["--progress", "plain", "up", "-d"])
        return runner.stream(tool.executable, arguments: args, environment: environment)
    }

    public func composeDown(tool: ComposeTool = .plugin, project: String, workingDir: String, files: [String]) async throws {
        let args = composeArgs(tool, project: project, workingDir: workingDir, files: files,
                               command: ["down", "--volumes", "--remove-orphans", "--rmi", "local"])
        _ = try await runner.runChecked(tool.executable, arguments: args, environment: environment)
    }

    public static func composeArguments(project: String, workingDir: String?, files: [String], command: [String]) -> [String] {
        var args = ["compose", "--project-name", project]
        if let workingDir { args += ["--project-directory", workingDir] }
        for f in files { args += ["--file", f] }
        return args + command
    }

    /// Recreates a stack from its files, using whichever compose is installed.
    public func composeUp(project: String, workingDir: String?, files: [String]) async throws {
        let tool = await composeTool() ?? .plugin
        let args = composeArgs(tool, project: project, workingDir: workingDir, files: files, command: ["up", "-d"])
        _ = try await runner.runChecked(tool.executable, arguments: args, environment: environment)
    }

    /// Shell command to open an interactive session in a container, for Terminal.app.
    public func shellCommand(containerID: String) -> String {
        "DOCKER_HOST=unix://\(profile.socketPath) docker exec -it \(containerID) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }
}
