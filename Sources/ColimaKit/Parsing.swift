import Foundation

/// Parsers for the CLI output formats ColimaUI depends on. Kept pure so they can be unit tested.
public enum Parsing {
    /// Parses newline-delimited JSON objects, skipping blank or malformed lines.
    public static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
    }

    // MARK: Colima

    public static func profiles(from text: String) -> [ColimaProfile] {
        jsonLines(text).compactMap { obj in
            guard let name = obj["name"] as? String else { return nil }
            func int64(_ key: String) -> Int64 {
                if let n = obj[key] as? NSNumber { return n.int64Value }
                if let s = obj[key] as? String { return parseSize(s) ?? 0 }
                return 0
            }
            return ColimaProfile(
                name: name,
                status: ProfileStatus(raw: obj["status"] as? String ?? ""),
                arch: obj["arch"] as? String ?? "",
                cpus: (obj["cpus"] as? NSNumber)?.intValue ?? 0,
                memoryBytes: int64("memory"),
                diskBytes: int64("disk"),
                runtime: obj["runtime"] as? String ?? "docker",
                address: obj["address"] as? String ?? "",
                kubernetes: (obj["kubernetes"] as? Bool) ?? false)
        }
    }

    // MARK: Docker

    /// `docker ps --format '{{.Labels}}'` renders labels as `k=v,k=v`. Values may themselves contain
    /// commas, so a fragment without `=` is treated as a continuation of the previous value.
    public static func labels(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var lastKey: String?
        for fragment in raw.split(separator: ",", omittingEmptySubsequences: true) {
            if let eq = fragment.firstIndex(of: "="), isLabelKey(fragment[fragment.startIndex..<eq]) {
                let key = String(fragment[fragment.startIndex..<eq])
                result[key] = String(fragment[fragment.index(after: eq)...])
                lastKey = key
            } else if let key = lastKey {
                result[key, default: ""] += "," + fragment
            }
        }
        return result
    }

    private static func isLabelKey(_ s: Substring) -> Bool {
        !s.isEmpty && !s.contains(" ")
    }

    /// Parses `0.0.0.0:3001->3001/tcp, [::]:3001->3001/tcp, 5432/tcp` into unique mappings.
    public static func ports(_ raw: String) -> [PortMapping] {
        var seen = Set<String>()
        var result: [PortMapping] = []
        for part in raw.split(separator: ",") {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let mapping: PortMapping?
            if let arrow = item.range(of: "->") {
                let host = String(item[item.startIndex..<arrow.lowerBound])
                let container = String(item[arrow.upperBound...])
                let (cPort, proto) = splitPortProto(container)
                let hostPort = host.split(separator: ":").last.flatMap { Int($0.split(separator: "-").first ?? "") }
                let hostIP = host.contains(":") ? String(host[host.startIndex..<host.lastIndex(of: ":")!]) : nil
                mapping = cPort.map { PortMapping(hostIP: hostIP, hostPort: hostPort, containerPort: $0, proto: proto) }
            } else {
                let (cPort, proto) = splitPortProto(item)
                mapping = cPort.map { PortMapping(hostIP: nil, hostPort: nil, containerPort: $0, proto: proto) }
            }
            if let mapping, seen.insert("\(mapping.hostPort ?? 0)-\(mapping.containerPort)-\(mapping.proto)").inserted {
                result.append(mapping)
            }
        }
        return result
    }

    private static func splitPortProto(_ s: String) -> (Int?, String) {
        let pieces = s.split(separator: "/")
        let port = pieces.first.flatMap { Int($0.split(separator: "-").first ?? "") }
        return (port, pieces.count > 1 ? String(pieces[1]) : "tcp")
    }

    public static func containers(from text: String) -> [Container] {
        jsonLines(text).compactMap { obj in
            guard let id = obj["ID"] as? String else { return nil }
            let name = (obj["Names"] as? String ?? id).split(separator: ",").first.map(String.init) ?? id
            return Container(
                id: id, name: name,
                image: obj["Image"] as? String ?? "",
                state: ContainerState(raw: obj["State"] as? String ?? ""),
                status: obj["Status"] as? String ?? "",
                ports: ports(obj["Ports"] as? String ?? ""),
                labels: labels(obj["Labels"] as? String ?? ""),
                createdAt: obj["CreatedAt"] as? String ?? "")
        }
    }

    public static func images(from text: String) -> [DockerImage] {
        jsonLines(text).compactMap { obj in
            guard let id = obj["ID"] as? String else { return nil }
            return DockerImage(id: id, repository: obj["Repository"] as? String ?? "<none>",
                               tag: obj["Tag"] as? String ?? "<none>",
                               size: obj["Size"] as? String ?? "",
                               createdSince: obj["CreatedSince"] as? String ?? "")
        }
    }

    public static func volumes(from text: String) -> [DockerVolume] {
        jsonLines(text).compactMap { obj in
            guard let name = obj["Name"] as? String else { return nil }
            return DockerVolume(name: name, driver: obj["Driver"] as? String ?? "local",
                                labels: labels(obj["Labels"] as? String ?? ""))
        }
    }

    public static func networks(from text: String) -> [DockerNetwork] {
        jsonLines(text).compactMap { obj in
            guard let id = obj["ID"] as? String, let name = obj["Name"] as? String else { return nil }
            return DockerNetwork(id: id, name: name, driver: obj["Driver"] as? String ?? "",
                                 scope: obj["Scope"] as? String ?? "local",
                                 labels: labels(obj["Labels"] as? String ?? ""))
        }
    }

    public static func stats(from text: String) -> [ContainerStats] {
        jsonLines(text).compactMap { obj in
            guard let id = obj["ID"] as? String else { return nil }
            return ContainerStats(
                id: id, name: obj["Name"] as? String ?? id,
                cpuPercent: percent(obj["CPUPerc"] as? String),
                memoryUsage: (obj["MemUsage"] as? String)?.components(separatedBy: " / ").first ?? "",
                memoryPercent: percent(obj["MemPerc"] as? String))
        }
    }

    static func percent(_ s: String?) -> Double {
        Double((s ?? "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Parses "8GiB", "512MB", "1.5GB" into bytes.
    public static func parseSize(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let table: [String: Double] = [
            "": 1, "b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
            "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776,
        ]
        return table[unit].map { Int64(value * $0) }
    }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 { return gib.rounded() == gib ? "\(Int(gib)) GiB" : String(format: "%.1f GiB", gib) }
        return "\(Int((Double(value) / 1_048_576).rounded())) MiB"
    }
}
