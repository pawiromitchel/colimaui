import Testing
import Foundation
@testable import ColimaKit

@MainActor
@Suite struct StoreTests {
    func makeRunner() -> FakeRunner {
        let r = FakeRunner()
        r.on("list", output: Sample.colimaList)
        r.on("context", "show", output: "colima\n")
        r.on("ps", output: Sample.ps)
        r.on("image", output: #"{"ID":"i1","Repository":"redis","Tag":"7","Size":"100MB","CreatedSince":"1 day ago"}"#)
        r.on("volume", output: #"{"Name":"shop_data","Driver":"local","Labels":"com.docker.compose.project=shop"}"#)
        r.on("network", output: #"{"ID":"n1","Name":"shop_default","Driver":"bridge","Scope":"local","Labels":""}"#)
        r.on("stats", output: #"{"ID":"aaa111","Name":"shop-web-1","CPUPerc":"2.00%","MemUsage":"10MiB / 1GiB","MemPerc":"1.00%"}"#)
        return r
    }

    @Test func refreshLoadsEverything() async {
        let store = ColimaStore(runner: makeRunner())
        await store.refresh()
        #expect(store.profiles.count == 2)
        #expect(store.selectedProfile?.name == "default")
        #expect(store.activeContext == "colima")
        #expect(store.containers.count == 4)
        #expect(store.runningContainerCount == 3)
        #expect(store.images.count == 1)
        #expect(store.volumes.count == 1)
        #expect(store.networks.count == 1)
        #expect(store.stats["aaa111"]?.cpuPercent == 2.0)
        #expect(store.lastRefresh != nil)
        #expect(store.groups.map(\.title) == ["shop", "Standalone"])
    }

    @Test func searchFiltersGroups() async {
        let store = ColimaStore(runner: makeRunner())
        await store.refresh()
        store.searchText = "redis"
        #expect(store.groups.map(\.title) == ["Standalone"])
        store.groupMode = .none
        store.searchText = ""
        #expect(store.groups.first?.containers.count == 4)
    }

    @Test func stoppedProfileClearsDockerData() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner)
        await store.refresh()
        store.selectedProfileName = "k8s"
        await store.refresh()
        #expect(store.docker == nil)
        #expect(store.containers.isEmpty)
        #expect(store.images.isEmpty)
    }

    @Test func missingColimaIsReported() async {
        let runner = FakeRunner()
        runner.on("list", output: "", exit: 127, stderr: "x")
        struct Missing: CommandRunning {
            func run(_ e: String, arguments: [String], environment: [String: String]) async throws -> CommandResult {
                throw CommandError(command: e, exitCode: 127, message: "\(e) not found. Install it with Homebrew.")
            }
            func stream(_ e: String, arguments: [String], environment: [String: String]) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let store = ColimaStore(runner: Missing())
        await store.refresh()
        #expect(store.toolMissing?.contains("colima not found") == true)
    }

    @Test func stackActionsOnlyTouchRelevantContainers() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner)
        await store.refresh()
        let shop = store.groups[0]

        await store.perform(.stop, on: shop)
        #expect(runner.commandLines.contains("docker stop bbb222 aaa111"))

        await store.perform(.start, on: shop)
        #expect(runner.commandLines.contains("docker start ccc333"))

        await store.perform(.restart, on: shop)
        #expect(runner.commandLines.contains("docker restart bbb222 aaa111 ccc333"))
    }

    @Test func removeAndBusyStateClears() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner)
        await store.refresh()
        await store.remove(["ccc333"])
        #expect(runner.commandLines.contains("docker rm -f ccc333"))
        #expect(store.busyContainerIDs.isEmpty)
    }

    @Test func errorsAreLoggedNotThrown() async {
        let runner = makeRunner()
        runner.responses.insert(({ $0.first == "stop" }, CommandResult(exitCode: 1, stdout: "", stderr: "boom")), at: 0)
        let store = ColimaStore(runner: runner)
        await store.refresh()
        await store.perform(.stop, on: ["aaa111"])
        #expect(store.activity.contains { $0.level == .error && $0.message == "boom" })
    }

    @Test func startProfileStreamsProgressIntoActivity() async {
        let runner = makeRunner()
        runner.streams = [#"time="t" level=info msg="starting colima""#, #"time="t" level=info msg="done""#]
        let store = ColimaStore(runner: runner)
        await store.refresh()
        await store.startProfile("k8s", options: StartOptions(cpus: 2))
        let messages = store.activity.map(\.message)
        #expect(messages.contains("starting colima"))
        #expect(messages.contains("Started k8s"))
        #expect(runner.commandLines.contains("colima start --profile k8s --cpu 2"))
        #expect(store.busyProfiles.isEmpty)
    }

    @Test func stopAndDeleteProfile() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner)
        await store.stopProfile("default")
        await store.deleteProfile("k8s")
        #expect(runner.commandLines.contains("colima stop --profile default"))
        #expect(runner.commandLines.contains("colima delete --profile k8s --force"))
    }

    @Test func useContextSwitchesDockerContext() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner)
        await store.refresh()
        await store.useContext(store.profiles[1])
        #expect(runner.commandLines.contains("docker context use colima-k8s"))
    }

    @Test func pruneLogsLastLine() async {
        let runner = makeRunner()
        runner.on("image", "prune", output: "Deleted Images:\nTotal reclaimed space: 1.2GB\n")
        runner.responses.insert(runner.responses.removeLast(), at: 0)
        let store = ColimaStore(runner: runner)
        await store.refresh()
        await store.prune(.images)
        #expect(store.activity.last?.message == "Total reclaimed space: 1.2GB")
    }

    @Test func activityIsCapped() {
        let store = ColimaStore(runner: FakeRunner())
        for i in 0..<400 { store.log(.info, "m\(i)") }
        #expect(store.activity.count == 300)
        #expect(store.activity.last?.message == "m399")
        store.log(.info, "   ")
        #expect(store.activity.count == 300)
        store.clearActivity()
        #expect(store.activity.isEmpty)
    }
}
