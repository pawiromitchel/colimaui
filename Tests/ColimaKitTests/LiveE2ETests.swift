import Testing
import Foundation
@testable import ColimaKit

/// End-to-end checks against a real, running Colima. Opt in with `COLIMAUI_E2E=1 ./scripts/test.sh`.
/// The tests only create and remove containers named `colimaui-e2e-*`; they never touch the VM or your containers.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COLIMAUI_E2E"] == "1"))
struct LiveE2ETests {
    let runner = ProcessRunner()

    private func runningProfile() async throws -> ColimaProfile {
        let profiles = try await ColimaClient(runner: runner).profiles()
        let running = profiles.first(where: \.isRunning)
        try #require(running != nil, "No running Colima profile")
        return running!
    }

    private func docker(_ profile: ColimaProfile, _ args: [String]) async throws -> String {
        try await runner.runChecked("docker", arguments: args, environment: ["DOCKER_HOST": "unix://\(profile.socketPath)"])
    }

    @Test func containerLifecycleThroughTheStore() async throws {
        let profile = try await runningProfile()
        let name = "colimaui-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        let project = "colimaui-e2e"

        let hasImage = (try? await docker(profile, ["image", "inspect", "alpine:latest"])) != nil
        if !hasImage { _ = try await docker(profile, ["pull", "alpine:latest"]) }

        let id = try await docker(profile, [
            "run", "-d", "--stop-timeout", "1", "--name", name,
            "--label", "com.docker.compose.project=\(project)",
            "--label", "com.docker.compose.service=probe",
            "alpine:latest", "sh", "-c", "echo hello-e2e; sleep 600",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!id.isEmpty)

        let store = ColimaStore(runner: runner)
        store.selectedProfileName = profile.name

        do {
            await store.refresh()
            let created = try #require(store.containers.first { $0.name == name }, "container not listed")
            #expect(created.isRunning)
            #expect(created.composeProject == project)
            #expect(created.displayName == "probe")

            let stack = try #require(store.groups.first { $0.title == project }, "stack group missing")
            #expect(stack.summary == "1/1")
            #expect(store.stats[created.id] != nil)

            var gotLog = false
            for try await line in DockerClient(profile: profile, runner: runner).logs(id: created.id, tail: 10, follow: false) {
                if line.contains("hello-e2e") { gotLog = true }
            }
            #expect(gotLog)

            await store.perform(.stop, on: stack)
            #expect(store.container(id: created.id)?.state == .exited)
            #expect(store.groups.first { $0.title == project }?.summary == "0/1")

            await store.perform(.start, on: [created.id])
            #expect(store.container(id: created.id)?.isRunning == true)

            await store.perform(.restart, on: [created.id])
            #expect(store.container(id: created.id)?.isRunning == true)

            let inspect = try await DockerClient(profile: profile, runner: runner).inspect(created.id)
            #expect(inspect.contains(name))

            await store.remove([created.id])
            #expect(store.container(id: created.id) == nil)
            #expect(store.busyContainerIDs.isEmpty)
        } catch {
            _ = try? await docker(profile, ["rm", "-f", name])
            throw error
        }
        _ = try? await docker(profile, ["rm", "-f", name])
    }

    @Test func refreshSeesRealProfilesImagesVolumesNetworks() async throws {
        let profile = try await runningProfile()
        let store = ColimaStore(runner: runner)
        store.selectedProfileName = profile.name
        await store.refresh()
        #expect(store.profiles.contains { $0.name == profile.name })
        #expect(store.activeContext != nil)
        #expect(store.networks.contains { $0.name == "bridge" })
        #expect(store.activity.filter { $0.level == .error }.isEmpty)
    }

    @Test func processRunnerStreamsAndReportsExitCodes() async throws {
        let result = try await runner.run("sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")

        var lines: [String] = []
        for try await l in runner.stream("sh", arguments: ["-c", "echo a; echo b"], environment: [:]) { lines.append(l) }
        #expect(lines == ["a", "b"])

        await #expect(throws: CommandError.self) {
            _ = try await runner.runChecked("definitely-not-installed-xyz", arguments: [])
        }
    }

    // MARK: Compose drop

    private func waitFor(_ seconds: Double = 120, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func droppingAComposeFileBuildsStartsAndUpdatesAStack() async throws {
        let profile = try await runningProfile()
        let project = "colimaui-e2e-cmp-\(UUID().uuidString.prefix(6).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("web"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
        let port = Int.random(in: 20_000...40_000)
        try "FROM alpine:latest\nRUN echo built\nCMD [\"sh\",\"-c\",\"echo web-up; sleep 600\"]\n"
            .write(to: dir.appendingPathComponent("web/Dockerfile"), atomically: true, encoding: .utf8)
        try """
        services:
          web:
            build: ./web
            stop_grace_period: 1s
            ports: ["\(port):80"]
            volumes: ["./data:/data"]
            environment:
              GREETING: ${GREETING}
          cache:
            image: alpine:latest
            stop_grace_period: 1s
            command: ["sh","-c","sleep 600"]
        """.write(to: dir.appendingPathComponent("compose.yml"), atomically: true, encoding: .utf8)
        try "GREETING=hello\nOTHER=1\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let hasImage = (try? await docker(profile, ["image", "inspect", "alpine:latest"])) != nil
        if !hasImage { _ = try await docker(profile, ["pull", "alpine:latest"]) }

        let store = ColimaStore(runner: runner)
        store.selectedProfileName = profile.name
        await store.refresh()
        let model = ComposeDropModel(store: store)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try #require(store.docker)
        func cleanup() async { try? await client.composeDown(project: project, workingDir: dir.path, files: [dir.appendingPathComponent("compose.yml").path]) }

        do {
            model.begin(urls: [dir])
            await waitFor(60) { if case .review = model.phase { true } else { false } }
            guard case .review(let plan) = model.phase else { Issue.record("expected review, got \(model.phase)"); await cleanup(); return }
            #expect(plan.services.map(\.name) == ["cache", "web"])
            #expect(plan.services.first { $0.name == "web" }?.action == .build)
            #expect(plan.browserPorts.map(\.published) == [port])
            #expect(plan.binds.map(\.target) == ["/data"])
            #expect(plan.envVariableCount == 2)
            #expect(plan.warnings.contains { $0.contains("builds from source") })
            #expect(!model.isUpdate(project))

            model.projectName = project
            model.start(openLogs: true)
            await waitFor { if case .done = model.phase { true } else if case .failure = model.phase { true } else { false } }
            guard case .done(_, _, let isUpdate) = model.phase else { Issue.record("expected done, got \(model.phase)"); await cleanup(); return }
            #expect(!isUpdate)
            #expect(store.notice?.text == "Started \(project)")
            let members = store.containers.filter { $0.composeProject == project }
            #expect(Set(members.compactMap(\.composeService)) == ["web", "cache"])
            #expect(members.allSatisfy { $0.isRunning })
            #expect(members.first { $0.composeService == "web" }?.ports.first?.hostPort == port)
            let group = try #require(store.groups.first { $0.title == project })
            #expect(group.summary == "2/2")

            // Dropping the same stack again updates it.
            model.close()
            model.begin(urls: [dir])
            await waitFor(60) { if case .review = model.phase { true } else { false } }
            model.projectName = project
            #expect(model.isUpdate(project))
            model.start(openLogs: false)
            await waitFor { if case .done = model.phase { true } else if case .failure = model.phase { true } else { false } }
            #expect(store.notice?.text == "Updated \(project)")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        await store.refresh()
        #expect(store.containers.filter { $0.composeProject == project }.isEmpty)
    }

    @Test func aStackThatCannotStartReportsComposesError() async throws {
        let profile = try await runningProfile()
        let project = "colimaui-e2e-bad-\(UUID().uuidString.prefix(6).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "services:\n  x:\n    image: colimaui-no-such-image-xyz:1\n".write(to: dir.appendingPathComponent("compose.yml"), atomically: true, encoding: .utf8)

        let store = ColimaStore(runner: runner)
        store.selectedProfileName = profile.name
        await store.refresh()
        let model = ComposeDropModel(store: store)
        model.begin(urls: [dir])
        await waitFor(60) { if case .review = model.phase { true } else { false } }
        model.projectName = project
        model.start(openLogs: false)
        await waitFor { if case .failure = model.phase { true } else if case .done = model.phase { true } else { false } }
        guard case .failure(.failed(let message), _) = model.phase else { Issue.record("expected a failed start, got \(model.phase)"); return }
        #expect(!message.isEmpty)
        #expect(store.notice?.isError == true)
        #expect(model.isPresented)
    }

    @Test func aBrokenComposeFileIsExplainedBeforeAnythingRuns() async throws {
        let profile = try await runningProfile()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colimaui-e2e-broken-\(UUID().uuidString.prefix(6).lowercased())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "services:\n  api:\n    image: nginx\n    ports: [\"80800:80\"]\n".write(to: dir.appendingPathComponent("compose.yml"), atomically: true, encoding: .utf8)
        let store = ColimaStore(runner: runner)
        store.selectedProfileName = profile.name
        await store.refresh()
        let model = ComposeDropModel(store: store)
        model.begin(urls: [dir])
        await waitFor(60) { if case .failure = model.phase { true } else { false } }
        guard case .failure(.invalid(let message), _) = model.phase else { Issue.record("expected invalid, got \(model.phase)"); return }
        #expect(message.contains("80800") || message.contains("port"))
    }
}
