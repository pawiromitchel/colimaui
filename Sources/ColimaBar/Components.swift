import SwiftUI
import AppKit
import ColimaKit

extension ContainerState {
    var color: Color {
        switch self {
        case .running: .green
        case .restarting, .paused, .removing: .orange
        case .dead: .red
        default: .secondary.opacity(0.6)
        }
    }

    var label: String { rawValue.capitalized }
}

extension ProfileStatus {
    var color: Color {
        switch self {
        case .running: .green
        case .stopped: .secondary.opacity(0.6)
        case .unknown: .orange
        }
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct IconButton: View {
    var systemName: String
    var help: String
    var role: ButtonRole?
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(disabled)
        .accessibilityLabel(help)
    }
}

struct PortLinks: View {
    var ports: [PortMapping]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(ports.prefix(2), id: \.self) { port in
                if let url = port.browserURL {
                    Link(destination: url) {
                        Text("\(port.label) ↗").font(.caption).foregroundStyle(Color.accentColor).lineLimit(1).fixedSize()
                    }
                    .help("Open \(url.absoluteString)")
                } else {
                    Text(port.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            if ports.count > 2 {
                Text("+\(ports.count - 2)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

struct LoadingState: View {
    var message: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct Card<Content: View>: View {
    var dimmed = false
    var minHeight: CGFloat?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(dimmed ? Color.secondary.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(mono ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// A pending destructive action awaiting confirmation.
struct DeleteRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel = "Delete"
    var action: () async -> Void
}

extension View {
    func confirm(_ request: Binding<DeleteRequest?>) -> some View {
        confirmationDialog(request.wrappedValue?.title ?? "", isPresented: Binding(
            get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            titleVisibility: .visible, presenting: request.wrappedValue) { req in
            Button(req.confirmLabel, role: .destructive) { Task { await req.action() } }
            Button("Cancel", role: .cancel) {}
        } message: { req in Text(req.message) }
    }
}

enum Terminal {
    /// Opens Terminal.app running `command`.
    static func run(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

enum ANSI {
    private static let pattern = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}"), let pattern else { return s }
        return pattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}
