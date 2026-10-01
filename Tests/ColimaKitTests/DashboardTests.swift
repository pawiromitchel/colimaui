import Testing
import Foundation
@testable import ColimaKit

@Suite struct DashboardParsingTests {
    static let df = """
    {"Active":"5","Reclaimable":"738.3MB (1%)","Size":"38.06GB","TotalCount":"8","Type":"Images"}
    {"Active":"5","Reclaimable":"16.38kB (1%)","Size":"1.573MB","TotalCount":"6","Type":"Containers"}
    {"Active":"2","Reclaimable":"0B (0%)","Size":"1.623MB","TotalCount":"2","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"37.76GB","Size":"38.33GB","TotalCount":"965","Type":"Build Cache"}
    """

    @Test func parsesDockerSystemDf() throws {
        let usage = try #require(Parsing.diskUsage(from: Self.df))
        #expect(usage.entries.count == 4)
        let images = try #require(usage.entry(.images))
        #expect(images.totalCount == 8)
        #expect(images.activeCount == 5)
        #expect(images.sizeBytes == 38_060_000_000)
        #expect(images.reclaimableBytes == 738_300_000)
        #expect(usage.entry(.buildCache)?.reclaimableBytes == 37_760_000_000)
        #expect(usage.entry(.volumes)?.reclaimableBytes == 0)
        #expect(usage.reclaimableBytes > 38_000_000_000)
        #expect(usage.totalBytes > usage.entry(.images)!.sizeBytes)
    }

    @Test func diskUsageIgnoresUnknownRowsAndEmptyOutput() {
        #expect(Parsing.diskUsage(from: "") == nil)
        #expect(Parsing.diskUsage(from: #"{"Type":"Mystery","Size":"1GB"}"#) == nil)
    }

    static let vmDf = """
    Filesystem            1K-blocks      Used Available Use% Mounted on
    /dev/root              19221248    975256  18229608   6% /
    tmpfs                   4056200         0   4056200   0% /dev/shm
    lima-2125057151a5421b 482797652 215566092 267231560  45% /Users/toasty
    /dev/vdc                  19476     19476         0 100% /mnt/lima-cidata
    /dev/vdb1             102624184  39043784  58321240  41% /mnt/lima-colima
    """

    @Test func vmDiskPrefersTheDockerDataMount() throws {
        let disk = try #require(Parsing.vmDisk(from: Self.vmDf))
        #expect(disk.mount == "/mnt/lima-colima")
        #expect(disk.totalBytes == 102_624_184 * 1024)
        #expect(disk.usedBytes == 39_043_784 * 1024)
        #expect(abs(disk.usedFraction - 0.38) < 0.01)
        #expect(disk.freeBytes == disk.totalBytes - disk.usedBytes)
    }

    @Test func vmDiskFallsBackToRoot() throws {
        let text = """
        Filesystem     1K-blocks   Used Available Use% Mounted on
        /dev/root       19221248 975256  18229608   6% /
        /dev/vdc           19476  19476         0 100% /mnt/lima-cidata
        """
        #expect(try #require(Parsing.vmDisk(from: text)).mount == "/")
        #expect(Parsing.vmDisk(from: "") == nil)
        #expect(Parsing.vmDisk(from: "Filesystem 1K-blocks\ngarbage") == nil)
    }

    @Test func parsesExitCodes() {
        #expect(Parsing.exitCode(fromStatus: "Exited (1) 2 hours ago") == 1)
        #expect(Parsing.exitCode(fromStatus: "Exited (137) 3 days ago") == 137)
        #expect(Parsing.exitCode(fromStatus: "Up 5 minutes") == nil)
        #expect(Parsing.exitCode(fromStatus: "Exited (x) now") == nil)
    }
}

@Suite struct HistoryAndAttentionTests {
    @Test func historyKeepsOnlyTheNewestSamples() {
        var h = MetricsHistory(capacity: 3)
        for i in 0..<5 { h.append(MetricSample(cpuPercent: Double(i), memoryBytes: Int64(i))) }
        #expect(h.samples.map(\.cpuPercent) == [2, 3, 4])
        #expect(h.latest?.cpuPercent == 4)
        h.reset()
        #expect(h.samples.isEmpty)
        #expect(h.latest == nil)
    }

    private func container(_ name: String, _ state: ContainerState, status: String) -> Container {
        Container(id: name, name: name, image: "img", state: state, status: status)
    }

    @Test func flagsCrashesButNotNormalStops() {
        let items = Attention.items(containers: [
            container("crashed", .exited, status: "Exited (1) 2 hours ago"),
            container("clean", .exited, status: "Exited (0) 2 hours ago"),
            container("stopped", .exited, status: "Exited (137) 1 minute ago"),
            container("termed", .exited, status: "Exited (143) 1 minute ago"),
            container("loop", .restarting, status: "Restarting (1) 5 seconds ago"),
            container("gone", .dead, status: "Dead"),
            container("fine", .running, status: "Up 3 hours"),
        ], vmDisk: nil)
        #expect(items.map(\.message) == ["gone is dead", "loop keeps restarting", "crashed exited with code 1"])
        #expect(items[0].severity == .error)
        #expect(items[2].severity == .warning)
        #expect(items[2].action == .logs(containerID: "crashed"))
    }

    @Test func warnsWhenTheVMDiskIsAlmostFull() {
        let gib: Int64 = 1_073_741_824
        #expect(Attention.items(containers: [], vmDisk: VMDisk(mount: "/", totalBytes: 100 * gib, usedBytes: 79 * gib)).isEmpty)
        let items = Attention.items(containers: [], vmDisk: VMDisk(mount: "/", totalBytes: 100 * gib, usedBytes: 85 * gib))
        #expect(items.map(\.message) == ["VM disk is 85% full"])
        #expect(items[0].action == .prune)
    }
}

@MainActor
@Suite struct DashboardStoreTests {
    func makeRunner() -> FakeRunner {
        let r = FakeRunner()
        r.on("list", output: Sample.colimaList)
        r.on("context", "show", output: "colima\n")
        r.on("ps", output: Sample.ps)
        r.on("stats", output: [
            #"{"ID":"aaa111","Name":"shop-web-1","CPUPerc":"40.00%","MemUsage":"100MiB / 8GiB","MemPerc":"1.2%"}"#,
            #"{"ID":"bbb222","Name":"shop-db-1","CPUPerc":"20.00%","MemUsage":"200MiB / 8GiB","MemPerc":"2.4%"}"#,
        ].joined(separator: "\n"))
        r.on("system", "df", output: DashboardParsingTests.df)
        r.on("ssh", output: DashboardParsingTests.vmDf)
        return r
    }

    @Test func refreshCollectsDiskAndHistory() async {
        let store = ColimaStore(runner: makeRunner(), prerequisites: { .ready })
        await store.refresh()
        #expect(store.diskUsage?.entry(.buildCache) != nil)
        #expect(store.vmDisk?.mount == "/mnt/lima-colima")
        #expect(store.history.samples.count == 1)
        // 60% of one core across a 4-core VM is 15% of the VM.
        #expect(store.history.latest?.cpuPercent == 15)
        #expect(store.history.latest?.memoryBytes == Int64(300 * 1_048_576))
        #expect(store.stackCount == 1)
        #expect(store.runningStats.count == 2)
    }

    @Test func diskIsRefreshedOnItsOwnSchedule() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner, prerequisites: { .ready })
        await store.refresh()
        await store.refresh()
        #expect(runner.commandLines.filter { $0.hasPrefix("docker system df") }.count == 1)
        #expect(store.history.samples.count == 2)
        await store.refreshDisk(force: true)
        #expect(runner.commandLines.filter { $0.hasPrefix("docker system df") }.count == 2)
    }

    @Test func attentionComesFromTheStore() async {
        let runner = makeRunner()
        let store = ColimaStore(runner: runner, prerequisites: { .ready })
        await store.refresh()
        // shop-worker exited with code 0 in the sample data, which is not a problem.
        #expect(store.attention.isEmpty)
    }

    @Test func stoppedProfileClearsDashboardData() async {
        let store = ColimaStore(runner: makeRunner(), prerequisites: { .ready })
        await store.refresh()
        store.selectedProfileName = "k8s"
        await store.refresh()
        #expect(store.diskUsage == nil)
        #expect(store.vmDisk == nil)
        #expect(store.history.samples.isEmpty)
    }

    @Test func pruneBuildCacheRunsTheBuilderCommandAndRefreshesDisk() async {
        let runner = makeRunner()
        runner.on("builder", "prune", output: "Total:\t37.76GB\n")
        let store = ColimaStore(runner: runner, prerequisites: { .ready })
        await store.refresh()
        await store.prune(.buildCache)
        #expect(runner.commandLines.contains("docker builder prune -f"))
        #expect(runner.commandLines.filter { $0.hasPrefix("docker system df") }.count == 2)
        #expect(store.activity.last?.message == "Total:\t37.76GB")
    }
}
