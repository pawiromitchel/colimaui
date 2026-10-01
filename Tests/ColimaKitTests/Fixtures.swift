import Foundation
@testable import ColimaKit

/// Records invocations and returns canned output, so clients and the store run without Colima.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String]; var environment: [String: String] }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var responses: [(match: ([String]) -> Bool, result: CommandResult)] = []
    var streams: [String] = []

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var commandLines: [String] { calls.map { ([$0.executable] + $0.arguments).joined(separator: " ") } }

    func on(_ prefix: String..., output: String, exit: Int32 = 0, stderr: String = "") {
        responses.append(({ args in Array(args.prefix(prefix.count)) == prefix },
                          CommandResult(exitCode: exit, stdout: output, stderr: stderr)))
    }

    private func record(_ call: Call) { lock.lock(); _calls.append(call); lock.unlock() }

    func run(_ executable: String, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        record(Call(executable: executable, arguments: arguments, environment: environment))
        for r in responses where r.match(arguments) { return r.result }
        return CommandResult(exitCode: 0)
    }

    func stream(_ executable: String, arguments: [String], environment: [String: String]) -> AsyncThrowingStream<String, Error> {
        record(Call(executable: executable, arguments: arguments, environment: environment))
        let lines = streams
        return AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() }
    }
}

enum Sample {
    static let colimaList = """
    {"name":"default","status":"Running","arch":"aarch64","cpus":4,"memory":8589934592,"disk":64424509440,"runtime":"docker"}
    {"name":"k8s","status":"Stopped","arch":"aarch64","cpus":2,"memory":4294967296,"disk":32212254720,"runtime":"containerd","kubernetes":true}
    """

    static func psLine(id: String, name: String, image: String, state: String, ports: String = "",
                       status: String = "Up 1 hour", labels: String = "") -> String {
        let obj: [String: String] = ["ID": id, "Names": name, "Image": image, "State": state,
                                     "Status": status, "Ports": ports, "Labels": labels,
                                     "CreatedAt": "2026-09-30 15:27:44 -0300 -03"]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static let composeLabels = "com.docker.compose.project=shop,com.docker.compose.service=web,com.docker.compose.project.working_dir=/tmp/shop,com.docker.compose.project.config_files=/tmp/shop/compose.yml"

    static var ps: String {
        [
            psLine(id: "aaa111", name: "shop-web-1", image: "shop-web", state: "running",
                   ports: "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp", labels: composeLabels),
            psLine(id: "bbb222", name: "shop-db-1", image: "postgres:16", state: "running", ports: "5432/tcp",
                   labels: composeLabels.replacingOccurrences(of: "service=web", with: "service=db")),
            psLine(id: "ccc333", name: "shop-worker-1", image: "shop-worker", state: "exited", status: "Exited (0) 2 hours ago",
                   labels: composeLabels.replacingOccurrences(of: "service=web", with: "service=worker")),
            psLine(id: "ddd444", name: "redis-dev", image: "redis:7", state: "running", ports: "0.0.0.0:6379->6379/tcp"),
        ].joined(separator: "\n")
    }
}
