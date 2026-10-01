import Foundation

/// Editable settings for creating or changing a Colima profile.
public struct ProfileDraft: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var isNew: Bool
    public var name: String
    public var cpus: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var runtime: String
    public var vmType: String
    public var rosetta: Bool
    public var kubernetes: Bool
    public private(set) var original: ColimaProfile?

    private static let gib: Int64 = 1_073_741_824

    public static func new() -> ProfileDraft {
        ProfileDraft(isNew: true, name: "", cpus: 2, memoryGiB: 4, diskGiB: 60, runtime: "docker",
                     vmType: "vz", rosetta: false, kubernetes: false)
    }

    public init(isNew: Bool, name: String, cpus: Int, memoryGiB: Int, diskGiB: Int, runtime: String,
                vmType: String, rosetta: Bool, kubernetes: Bool) {
        self.isNew = isNew; self.name = name; self.cpus = cpus; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB
        self.runtime = runtime; self.vmType = vmType; self.rosetta = rosetta; self.kubernetes = kubernetes
    }

    public init(profile: ColimaProfile) {
        self.init(isNew: false, name: profile.name, cpus: max(1, profile.cpus),
                  memoryGiB: max(1, Int(profile.memoryBytes / Self.gib)),
                  diskGiB: max(1, Int(profile.diskBytes / Self.gib)),
                  runtime: profile.runtime, vmType: "vz", rosetta: false, kubernetes: profile.kubernetes)
        original = profile
    }

    public var minimumDiskGiB: Int { original.map { Int($0.diskBytes / Self.gib) } ?? 10 }

    /// Colima profile names become directory and VM names, so keep them simple.
    public var nameIsValid: Bool {
        !name.isEmpty && name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }

    /// Options for `colima start`. Editing sends only what changed so the VM keeps its other settings.
    public var options: StartOptions {
        guard let original else {
            return StartOptions(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB, runtime: runtime,
                                vmType: vmType, rosetta: vmType == "vz" ? rosetta : nil, kubernetes: kubernetes)
        }
        return StartOptions(
            cpus: cpus != original.cpus ? cpus : nil,
            memoryGiB: Int64(memoryGiB) * Self.gib != original.memoryBytes ? memoryGiB : nil,
            diskGiB: Int64(diskGiB) * Self.gib != original.diskBytes ? max(diskGiB, minimumDiskGiB) : nil,
            kubernetes: kubernetes != original.kubernetes ? kubernetes : nil)
    }
}
