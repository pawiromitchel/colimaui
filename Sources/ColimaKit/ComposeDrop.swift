import Foundation
import Observation

/// Drives "drop a compose file to start a stack": read it, show a plan, run `up`, report the outcome.
@MainActor
@Observable
public final class ComposeDropModel {
    public enum Failure: Equatable, Sendable {
        case notComposeFile
        case noVM
        case composeMissing
        /// Compose rejected the file; the message is compose's own.
        case invalid(String)
        /// `up` started but failed.
        case failed(String)
    }

    public enum Phase {
        case idle
        case reading
        case review(ComposePlan)
        case running(ComposeProgress, project: String, openLogs: Bool)
        case done(project: String, openLogs: Bool, isUpdate: Bool)
        case failure(Failure, files: [String])
    }

    public struct Completion: Equatable, Sendable {
        public let id = UUID()
        public var project: String
        public var openLogs: Bool
        public var isUpdate: Bool
    }

    public private(set) var phase: Phase = .idle
    /// Set once when a stack finishes starting, so the window can react (open the stack, hide the sheet).
    public private(set) var completion: Completion?
    /// Whether the sheet is showing. "Run in background" hides it while the work continues.
    public var isPresented = false
    /// The stack name being edited on the review sheet.
    public var projectName = ""

    private let store: ColimaStore
    @ObservationIgnored private var composeTool = DockerClient.ComposeTool.plugin
    @ObservationIgnored private var task: Task<Void, Never>?

    @ObservationIgnored private let findTool: @Sendable (String) -> String?

    public init(store: ColimaStore, findTool: @escaping @Sendable (String) -> String? = { ToolLocator.find($0) }) {
        self.store = store
        self.findTool = findTool
    }

    /// For previews and screenshots: a model that is already in `phase`.
    public init(store: ColimaStore, previewPhase: Phase, projectName: String = "") {
        self.store = store
        self.findTool = { ToolLocator.find($0) }
        self.phase = previewPhase
        self.projectName = projectName
        self.isPresented = true
    }

    // MARK: Reading

    public func begin(urls: [URL]) {
        if case .running = phase { return } // one stack at a time
        task?.cancel()
        isPresented = true
        phase = .reading
        task = Task { await read(urls) }
    }

    private func read(_ urls: [URL]) async {
        guard let input = ComposeLocator.resolve(urls) else { phase = .failure(.notComposeFile, files: []); return }
        guard let docker = store.docker else { phase = .failure(.noVM, files: input.files); return }
        guard let tool = await docker.composeTool(find: findTool) else { phase = .failure(.composeMissing, files: input.files); return }

        projectName = input.suggestedName
        composeTool = tool
        do {
            let config = try await docker.composeConfig(tool: tool, project: input.suggestedName, workingDir: input.workingDir, files: input.files)
            let plan = try ComposePlan.parse(configJSON: config.json, stderr: config.stderr, input: input, localImages: store.images)
            phase = .review(plan)
        } catch {
            phase = .failure(.invalid(error.localizedDescription), files: input.files)
        }
    }

    // MARK: Running

    /// True when a stack with this name already exists, so starting it updates it in place.
    public func isUpdate(_ name: String) -> Bool {
        store.containers.contains { $0.composeProject == name }
    }

    public var nameIsValid: Bool { ComposeLocator.isValidName(projectName) }

    public func start(openLogs: Bool) {
        guard case .review(let plan) = phase, nameIsValid, let docker = store.docker else { return }
        let tool = composeTool
        let name = projectName
        let update = isUpdate(name)
        phase = .running(ComposeProgress(plan: plan, project: name), project: name, openLogs: openLogs)
        task = Task {
            var progress = ComposeProgress(plan: plan, project: name)
            do {
                for try await line in docker.composeUpStream(tool: tool, project: name, workingDir: plan.input.workingDir, files: plan.input.files) {
                    progress.apply(line: line)
                    phase = .running(progress, project: name, openLogs: openLogs)
                }
                try Task.checkCancellation() // a stopped process ends the stream quietly; don't report that as success
                progress.finish(success: true)
                await store.refresh()
                store.post(update ? "Updated \(name)" : "Started \(name)")
                phase = .done(project: name, openLogs: openLogs, isUpdate: update)
                completion = Completion(project: name, openLogs: openLogs, isUpdate: update)
            } catch is CancellationError {
                return
            } catch {
                progress.finish(success: false)
                store.post("Couldn't start \(name)", isError: true)
                await store.refresh()
                phase = .failure(.failed(error.localizedDescription), files: plan.input.files)
                isPresented = true // a failure in the background should be seen
            }
        }
    }

    /// Stops watching `up`. Anything compose already created is left as it is; remove it from the Containers page.
    public func cancel() {
        task?.cancel()
        task = nil
        if case .running(_, let project, _) = phase {
            store.post("Stopped starting \(project). Anything already created is still there.")
        }
        phase = .idle
        close()
    }

    public func runInBackground() { isPresented = false }

    /// Hides the sheet and resets, unless a stack is still starting.
    public func close() {
        isPresented = false
        if case .running = phase { return }
        phase = .idle
    }
}
