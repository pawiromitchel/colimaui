import Foundation

/// How the app picks light or dark. `system` follows macOS, including its automatic switching at sunset.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// SF Symbol for the switcher button.
    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Anything unrecognised, such as a value from a future version, falls back to following the system.
    public init(stored: String?) {
        self = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}
