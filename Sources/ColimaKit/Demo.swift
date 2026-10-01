import Foundation

/// A pretend Colima and Docker with a small, believable set of stacks. It's what the README screenshots
/// are rendered from without exposing anyone's real containers, and it lets the
/// whole UI be driven in tests: starting, stopping and deleting actually change what it reports.
public final class DemoRunner: CommandRunning, @unchecked Sendable {
    struct DemoContainer {
        var id: String
        var name: String
        var image: String
        var project: String?
        var service: String?
        var ports: String
        var running: Bool
        var exitCode: Int
        var cpu: Double
        var memMiB: Double
    }

    private let lock = NSLock()
    private var containers: [DemoContainer]
    private var images: [(id: String, repo: String, tag: String, size: String, age: String)]
    private var volumes: [(name: String, project: String?)]
    private var networks: [(id: String, name: String)]
    private var buildCacheBytes: Double = 6.8e9
    private var tick = 0
    private var profileRunning = true

    public init() {
        func c(_ id: String, _ name: String, _ image: String, _ project: String?, _ service: String?, _ ports: String,
               running: Bool = true, exit: Int = 0, cpu: Double, mem: Double) -> DemoContainer {
            DemoContainer(id: id, name: name, image: image, project: project, service: service, ports: ports,
                          running: running, exitCode: exit, cpu: cpu, memMiB: mem)
        }
        containers = [
            c("a1b2c3d4e5f1", "shop-web-1", "shop-web:latest", "shop", "web", "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp", cpu: 1.8, mem: 148),
            c("a1b2c3d4e5f2", "shop-api-1", "shop-api:latest", "shop", "api", "0.0.0.0:8080->8080/tcp", cpu: 3.4, mem: 212),
            c("a1b2c3d4e5f3", "shop-db-1", "postgres:16", "shop", "db", "5432/tcp", cpu: 1.1, mem: 264),
            c("a1b2c3d4e5f4", "shop-worker-1", "shop-worker:latest", "shop", "worker", "", running: false, exit: 1, cpu: 0, mem: 0),
            c("b1b2c3d4e5f1", "monitoring-prometheus-1", "prom/prometheus:latest", "monitoring", "prometheus", "0.0.0.0:9090->9090/tcp", cpu: 0.9, mem: 186),
            c("b1b2c3d4e5f2", "monitoring-grafana-1", "grafana/grafana:latest", "monitoring", "grafana", "0.0.0.0:3001->3000/tcp", cpu: 0.6, mem: 132),
            c("c1b2c3d4e5f1", "redis-dev", "redis:7", nil, nil, "0.0.0.0:6379->6379/tcp", cpu: 0.2, mem: 14),
            c("c1b2c3d4e5f2", "portainer", "portainer/portainer-ce:latest", nil, nil, "0.0.0.0:9000->9000/tcp, 8000/tcp", cpu: 0.1, mem: 38),
        ]
        images = [
            ("img000000001", "shop-web", "latest", "412MB", "2 days ago"),
            ("img000000002", "shop-api", "latest", "388MB", "2 days ago"),
            ("img000000003", "shop-worker", "latest", "301MB", "2 days ago"),
            ("img000000004", "postgres", "16", "438MB", "3 weeks ago"),
            ("img000000005", "prom/prometheus", "latest", "280MB", "5 days ago"),
            ("img000000006", "grafana/grafana", "latest", "520MB", "5 days ago"),
            ("img000000007", "redis", "7", "117MB", "3 weeks ago"),
            ("img000000008", "portainer/portainer-ce", "latest", "290MB", "2 weeks ago"),
            ("img000000009", "<none>", "<none>", "301MB", "3 days ago"),
        ]
        volumes = [("shop_pgdata", "shop"), ("monitoring_grafana_data", "monitoring"), ("monitoring_prometheus_data", "monitoring")]
        networks = [("n00000000001", "bridge"), ("n00000000002", "host"), ("n00000000003", "none"),
                    ("n00000000004", "shop_default"), ("n00000000005", "monitoring_default")]
    }

    // MARK: CommandRunning

    public func run(_ executable: String, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        lock.withLock { handle(executable, arguments) }
    }

    private func handle(_ executable: String, _ a: [String]) -> CommandResult {
        switch (executable, a.first ?? "") {
        case ("colima", "list"): return ok(Self.lines([profile()]))
        case ("colima", "ssh"): return ok(vmDf())
        case ("colima", "stop"): profileRunning = false; return ok("")
        case ("docker", "context") where a.dropFirst().first == "show": return ok("colima\n")
        case ("docker", "ps"): return ok(Self.lines(containers.map(psRow)))
        case ("docker", "stats"): tick += 1; return ok(Self.lines(containers.filter(\.running).enumerated().map { statsRow($0.element, $0.offset) }))
        case ("docker", "image") where a.dropFirst().first == "ls": return ok(Self.lines(images.map(imageRow)))
        case ("docker", "image") where a.dropFirst().first == "rm": images.removeAll { $0.id == a.last }; return ok("")
        case ("docker", "image") where a.dropFirst().first == "prune": images.removeAll { $0.repo == "<none>" }; return ok("Total reclaimed space: 301MB\n")
        case ("docker", "volume") where a.dropFirst().first == "ls": return ok(Self.lines(volumes.map(volumeRow)))
        case ("docker", "volume") where a.dropFirst().first == "rm": volumes.removeAll { $0.name == a.last }; return ok("")
        case ("docker", "network") where a.dropFirst().first == "ls": return ok(Self.lines(networks.map(networkRow)))
        case ("docker", "network") where a.dropFirst().first == "rm": networks.removeAll { $0.id == a.last }; return ok("")
        case ("docker", "system") where a.dropFirst().first == "df": return ok(Self.lines(diskRows()))
        case ("docker", "system") where a.dropFirst().first == "prune": buildCacheBytes = 0; return ok("Total reclaimed space: 6.1GB\n")
        case ("docker", "builder"): let freed = buildCacheBytes; buildCacheBytes = 0; return ok("Total:\t\(Self.size(freed))\n")
        case ("docker", "inspect"): return ok(inspect(a.last ?? ""))
        case ("docker", "start"), ("docker", "stop"), ("docker", "restart"), ("docker", "kill"):
            let ids = Array(a.dropFirst())
            for i in containers.indices where ids.contains(containers[i].id) {
                containers[i].running = a[0] != "stop" && a[0] != "kill"
                if containers[i].running { containers[i].exitCode = 0 }
            }
            return ok(ids.joined(separator: "\n"))
        case ("docker", "rm"):
            let ids = Set(a.dropFirst().filter { !$0.hasPrefix("-") })
            containers.removeAll { ids.contains($0.id) }
            return ok("")
        default: return ok("")
        }
    }

    public func stream(_ executable: String, arguments: [String], environment: [String: String]) -> AsyncThrowingStream<String, Error> {
        let (lines, keepOpen) = lock.withLock { streamContent(executable, arguments) }
        return AsyncThrowingStream { continuation in
            for l in lines { continuation.yield(l) }
            if keepOpen {
                let task = Task {
                    var n = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        n += 1
                        continuation.yield(Self.logTime(offset: n) + " GET /health 200 1ms")
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.finish()
            }
        }
    }

    private func streamContent(_ executable: String, _ arguments: [String]) -> ([String], Bool) {
        let lines: [String]
        var keepOpen = false
        if executable == "colima", arguments.first == "start" {
            profileRunning = true
            lines = ["starting colima", "creating and starting VM", "provisioning docker runtime", "done"]
        } else if executable == "docker", arguments.first == "logs" {
            lines = logLines(for: arguments.last ?? "")
            keepOpen = arguments.contains("--follow")
        } else if executable == "docker", arguments.first == "pull" {
            lines = ["Pulling from library/\(arguments.last ?? "image")", "Status: Downloaded newer image"]
        } else { lines = [] }
        return (lines, keepOpen)
    }

    // MARK: Output builders

    private func ok(_ s: String) -> CommandResult { CommandResult(exitCode: 0, stdout: s) }

    private static func lines(_ rows: [[String: Any]]) -> String {
        rows.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    private func profile() -> [String: Any] {
        ["name": "default", "status": profileRunning ? "Running" : "Stopped", "arch": "aarch64", "cpus": 4,
         "memory": 8_589_934_592, "disk": 107_374_182_400, "runtime": "docker"]
    }

    private func vmDf() -> String {
        """
        Filesystem            1K-blocks      Used Available Use% Mounted on
        /dev/root              19221248    975256  18229608   6% /
        /dev/vdb1             102624184  41523540  55839484  43% /mnt/lima-colima
        """
    }

    private func psRow(_ c: DemoContainer) -> [String: Any] {
        var labels: [String] = []
        if let p = c.project {
            labels = ["com.docker.compose.project=\(p)", "com.docker.compose.service=\(c.service ?? "")",
                      "com.docker.compose.project.working_dir=/Users/demo/\(p)",
                      "com.docker.compose.project.config_files=/Users/demo/\(p)/compose.yml"]
        }
        return ["ID": c.id, "Names": c.name, "Image": c.image, "State": c.running ? "running" : "exited",
                "Status": c.running ? "Up 3 hours" : "Exited (\(c.exitCode)) 2 hours ago",
                "Ports": c.running ? c.ports : "", "Labels": labels.joined(separator: ","),
                "CreatedAt": "2026-09-30 15:27:44 -0300 -03"]
    }

    private func statsRow(_ c: DemoContainer, _ index: Int) -> [String: Any] {
        let wave = 1 + 0.35 * sin(Double(tick) * 0.8 + Double(index))
        return ["ID": c.id, "Name": c.name, "CPUPerc": String(format: "%.2f%%", c.cpu * wave),
                "MemUsage": String(format: "%.1fMiB / 7.737GiB", c.memMiB * (1 + 0.07 * sin(Double(tick) * 0.5 + Double(index) * 1.7))),
                "MemPerc": String(format: "%.2f%%", c.memMiB / 7922 * 100)]
    }

    private func imageRow(_ i: (id: String, repo: String, tag: String, size: String, age: String)) -> [String: Any] {
        ["ID": i.id, "Repository": i.repo, "Tag": i.tag, "Size": i.size, "CreatedSince": i.age]
    }

    private func volumeRow(_ v: (name: String, project: String?)) -> [String: Any] {
        ["Name": v.name, "Driver": "local",
         "Labels": v.project.map { "com.docker.compose.project=\($0)" } ?? ""]
    }

    private func networkRow(_ n: (id: String, name: String)) -> [String: Any] {
        ["ID": n.id, "Name": n.name, "Driver": n.name == "host" ? "host" : (n.name == "none" ? "null" : "bridge"),
         "Scope": "local", "Labels": ""]
    }

    private func diskRows() -> [[String: Any]] {
        let reclaimable = max(0, buildCacheBytes * 0.9)
        return [
            ["Type": "Images", "TotalCount": "\(images.count)", "Active": "8", "Size": "2.74GB", "Reclaimable": "301MB (10%)"],
            ["Type": "Containers", "TotalCount": "\(containers.count)", "Active": "\(containers.filter(\.running).count)", "Size": "4.2MB", "Reclaimable": "120kB (2%)"],
            ["Type": "Local Volumes", "TotalCount": "\(volumes.count)", "Active": "\(volumes.count)", "Size": "612MB", "Reclaimable": "0B (0%)"],
            ["Type": "Build Cache", "TotalCount": buildCacheBytes > 0 ? "123" : "0", "Active": "0",
             "Size": Self.size(buildCacheBytes), "Reclaimable": Self.size(reclaimable)],
        ]
    }

    private static func size(_ bytes: Double) -> String {
        bytes >= 1e9 ? String(format: "%.2fGB", bytes / 1e9) : String(format: "%.0fMB", bytes / 1e6)
    }

    private func inspect(_ id: String) -> String {
        guard let c = containers.first(where: { $0.id == id || $0.name == id }) else { return "[]" }
        let obj: [[String: Any]] = [[
            "Id": c.id + String(repeating: "0", count: 52), "Name": "/\(c.name)",
            "Config": ["Image": c.image, "Env": ["NODE_ENV=production", "PORT=3000"]],
            "State": ["Status": c.running ? "running" : "exited", "ExitCode": c.exitCode, "Running": c.running],
            "NetworkSettings": ["IPAddress": "172.17.0.\(Int(c.id.suffix(1), radix: 16) ?? 2)"],
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func logTime(offset: Int = 0) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date().addingTimeInterval(Double(offset)))
    }

    private func logLines(for id: String) -> [String] {
        let name = containers.first { $0.id == id || $0.name == id }?.name ?? id
        let t = { (s: Int) in Self.logTime(offset: -s) }
        if name.contains("db") {
            return ["\(t(40)) LOG:  database system is ready to accept connections",
                    "\(t(31)) LOG:  checkpoint starting: time", "\(t(30)) LOG:  checkpoint complete: wrote 12 buffers (0.1%)"]
        }
        if name.contains("worker") {
            return ["\(t(7200)) job 4821 started", "\(t(7199)) error: connection refused (queue:6379)", "\(t(7199)) fatal: giving up after 3 retries"]
        }
        return ["\(t(60)) ▲ Ready in 312ms", "\(t(42)) GET /api/items 200 12ms", "\(t(40)) GET /api/cart 200 8ms",
                "\(t(37)) POST /api/checkout 201 54ms", "\(t(33)) slow query: orders (310ms)", "\(t(20)) GET /health 200 1ms"]
    }
}
