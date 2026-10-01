import Foundation

/// Which of the command-line tools ColimaUI needs are installed, and how to get the missing ones.
public struct Prerequisites: Sendable, Equatable {
    /// Homebrew formula names of the tools that weren't found, in install order.
    public var missing: [String]
    public var brewAvailable: Bool

    public static let required = ["colima", "docker"]
    public static let ready = Prerequisites(missing: [], brewAvailable: true)

    public init(missing: [String], brewAvailable: Bool) {
        self.missing = missing
        self.brewAvailable = brewAvailable
    }

    public var isReady: Bool { missing.isEmpty }
    public var needsColima: Bool { missing.contains("colima") }
    public var needsDocker: Bool { missing.contains("docker") }

    /// The one-liner that fixes it.
    public var installCommand: String { "brew install " + missing.joined(separator: " ") }

    public var title: String {
        switch (needsColima, needsDocker) {
        case (true, true): "Colima and Docker aren't installed"
        case (true, false): "Colima isn't installed"
        case (false, true): "The Docker command-line tool isn't installed"
        default: "Everything is installed"
        }
    }

    public var explanation: String {
        switch (needsColima, needsDocker) {
        case (true, true):
            "ColimaUI is the window onto Colima, which runs your containers, and Docker's command-line tool, which talks to it. Install both with Homebrew."
        case (true, false):
            "Colima runs the VM your containers live in. Install it with Homebrew."
        case (false, true):
            "Colima is installed, but ColimaUI also needs Docker's command-line tool to list and control containers."
        default: ""
        }
    }

    public static func check(find: (String) -> String? = { ToolLocator.find($0) }) -> Prerequisites {
        Prerequisites(missing: required.filter { find($0) == nil }, brewAvailable: find("brew") != nil)
    }
}
