import Testing
import Foundation
@testable import ColimaKit

@MainActor
@Suite struct DemoTests {
    func makeStore() -> ColimaStore { ColimaStore(runner: DemoRunner(), prerequisites: { .ready }) }

    @Test func demoLooksLikeARealSetup() async {
        let store = makeStore()
        await store.refresh()
        #expect(store.selectedProfile?.isRunning == true)
        #expect(store.groups.map(\.title) == ["monitoring", "shop", "Standalone"])
        #expect(store.containers.count == 8)
        #expect(store.runningContainerCount == 7)
        #expect(store.images.count == 9)
        #expect(store.volumes.count == 3)
        #expect(store.networks.contains { $0.name == "shop_default" })
        #expect(store.diskUsage?.entry(.buildCache)?.reclaimableBytes ?? 0 > 6_000_000_000)
        #expect(store.vmDisk?.mount == "/mnt/lima-colima")
        #expect(store.activity.filter { $0.level == .error }.isEmpty)
    }

    @Test func demoShowsOneCrashedContainer() async {
        let store = makeStore()
        await store.refresh()
        #expect(store.attention.map(\.message) == ["shop-worker-1 exited with code 1"])
    }

    @Test func demoActionsChangeState() async throws {
        let store = makeStore()
        await store.refresh()
        let redis = try #require(store.containers.first { $0.name == "redis-dev" })
        await store.perform(.stop, on: [redis.id])
        #expect(store.container(id: redis.id)?.isRunning == false)
        await store.perform(.start, on: [redis.id])
        #expect(store.container(id: redis.id)?.isRunning == true)
        await store.remove([redis.id])
        #expect(store.container(id: redis.id) == nil)
    }

    @Test func demoStatsMoveSoSparklinesHaveShape() async {
        let store = makeStore()
        await store.refresh()
        await store.refresh()
        await store.refresh()
        let cpu = store.history.samples.map(\.cpuPercent)
        #expect(cpu.count == 3)
        #expect(Set(cpu).count > 1)
    }

    @Test func pruningBuildCacheFreesSpace() async {
        let store = makeStore()
        await store.refresh()
        await store.prune(.buildCache)
        #expect(store.diskUsage?.entry(.buildCache)?.sizeBytes == 0)
    }

    @Test func demoLogsStream() async throws {
        let runner = DemoRunner()
        var lines: [String] = []
        for try await line in runner.stream("docker", arguments: ["logs", "--tail", "10", "shop-web-1"], environment: [:]) { lines.append(line) }
        #expect(lines.count >= 5)
        #expect(lines.contains { $0.contains("GET /api/items") })
    }

    @Test func demoStopsAndStartsTheVM() async {
        let store = makeStore()
        await store.refresh()
        await store.stopProfile("default")
        #expect(store.selectedProfile?.isRunning == false)
        #expect(store.docker == nil)
        await store.startProfile("default")
        #expect(store.selectedProfile?.isRunning == true)
        #expect(store.containers.count == 8)
    }
}
