import Testing
import Foundation
@testable import ColimaKit

/// End-to-end checks against a real, running Colima. Opt in with `COLIMABAR_E2E=1 ./scripts/test.sh`.
/// The tests only create and remove containers named `colimabar-e2e-*`; they never touch the VM or your containers.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COLIMABAR_E2E"] == "1"))
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
        let name = "colimabar-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        let project = "colimabar-e2e"

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
}
