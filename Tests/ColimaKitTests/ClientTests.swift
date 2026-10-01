import Testing
import Foundation
@testable import ColimaKit

@Suite struct ClientTests {
    let profile = ColimaProfile(name: "default", status: .running)

    @Test func colimaListUsesJSON() async throws {
        let runner = FakeRunner()
        runner.on("list", output: Sample.colimaList)
        let profiles = try await ColimaClient(runner: runner).profiles()
        #expect(profiles.count == 2)
        #expect(runner.commandLines == ["colima list --json"])
    }

    @Test func startArgumentsIncludeOnlyProvidedOptions() {
        #expect(ColimaClient.startArguments(profile: "default") == ["start", "--profile", "default"])
        let args = ColimaClient.startArguments(profile: "dev", options: StartOptions(cpus: 4, memoryGiB: 8, diskGiB: 100, runtime: "docker", vmType: "vz", rosetta: true, kubernetes: false))
        #expect(args == ["start", "--profile", "dev", "--cpu", "4", "--memory", "8", "--disk", "100",
                         "--runtime", "docker", "--vm-type", "vz", "--vz-rosetta", "--kubernetes=false"])
    }

    @Test func stopAndDeleteTargetTheProfile() async throws {
        let runner = FakeRunner()
        let client = ColimaClient(runner: runner)
        try await client.stop(profile: "dev")
        try await client.delete(profile: "dev")
        #expect(runner.commandLines == ["colima stop --profile dev", "colima delete --profile dev --force"])
    }

    @Test func failuresSurfaceStderr() async {
        let runner = FakeRunner()
        runner.on("stop", output: "", exit: 1, stderr: "profile not running\n")
        await #expect(throws: CommandError.self) { try await ColimaClient(runner: runner).stop(profile: "x") }
        do { try await ColimaClient(runner: runner).stop(profile: "x") } catch {
            #expect(error.localizedDescription == "profile not running")
        }
    }

    @Test func dockerCommandsTargetTheProfileSocket() async throws {
        let runner = FakeRunner()
        runner.on("ps", output: Sample.ps)
        let containers = try await DockerClient(profile: profile, runner: runner).containers()
        #expect(containers.count == 4)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "docker")
        #expect(call.arguments.prefix(2) == ["ps", "-a"])
        #expect(call.environment["DOCKER_HOST"] == "unix://\(profile.socketPath)")
        #expect(profile.socketPath.hasSuffix("/.colima/default/docker.sock"))
    }

    @Test func containerActionsBatchIDs() async throws {
        let runner = FakeRunner()
        let client = DockerClient(profile: profile, runner: runner)
        try await client.perform(.stop, ids: ["a", "b"])
        try await client.perform(.restart, ids: [])
        try await client.remove(ids: ["a"])
        #expect(runner.commandLines == ["docker stop a b", "docker rm -f a"])
    }

    @Test func logsArguments() {
        let runner = FakeRunner()
        let client = DockerClient(profile: profile, runner: runner)
        _ = client.logs(id: "abc", tail: 50, follow: true, timestamps: true)
        _ = client.logs(id: "abc", tail: 10, follow: false)
        #expect(runner.commandLines == ["docker logs --tail 50 --follow --timestamps abc", "docker logs --tail 10 abc"])
    }

    @Test func composeArguments() {
        let args = DockerClient.composeArguments(project: "shop", workingDir: "/tmp/shop", files: ["/tmp/shop/a.yml", "/tmp/shop/b.yml"], command: ["up", "-d"])
        #expect(args == ["compose", "--project-name", "shop", "--project-directory", "/tmp/shop",
                         "--file", "/tmp/shop/a.yml", "--file", "/tmp/shop/b.yml", "up", "-d"])
    }

    @Test func shellCommandUsesProfileSocket() {
        let cmd = DockerClient(profile: profile, runner: FakeRunner()).shellCommand(containerID: "abc")
        #expect(cmd.contains("DOCKER_HOST=unix://"))
        #expect(cmd.contains("docker exec -it abc"))
    }

    @Test func toolLocatorFindsAbsolutePathsOnly() {
        #expect(ToolLocator.find("/bin/ls") == "/bin/ls")
        #expect(ToolLocator.find("/definitely/missing") == nil)
        #expect(ToolLocator.find("ls") != nil)
        #expect(ToolLocator.find("definitely-not-a-tool-xyz") == nil)
    }
}
