import SwiftUI
import ColimaKit

/// Shown instead of the app when colima or docker isn't installed. The store keeps checking,
/// so the window switches to the dashboard on its own once the install finishes.
struct SetupView: View {
    @Environment(ColimaStore.self) private var store
    @State private var copied = false

    var body: some View {
        let p = store.prerequisites
        VStack(spacing: 18) {
            Image(nsImage: appIcon)
                .resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text(p.title).font(.title2.weight(.medium))
                Text(p.explanation).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }

            if p.brewAvailable {
                commandBox(p.installCommand)
                HStack {
                    Button("Install in Terminal") { Terminal.run(p.installCommand) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button(copied ? "Copied" : "Copy command") { copy(p.installCommand) }.controlSize(.large)
                }
                Text("This window updates by itself when the install finishes.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Homebrew, the package manager these tools come from, isn't installed either.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                HStack {
                    Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button(copied ? "Copied" : "Copy command") { copy(p.installCommand) }.controlSize(.large)
                }
                commandBox(p.installCommand)
                Text("Install Homebrew first, then run the command above.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appIcon: NSImage {
        let rep = LlamaArt.appIcon(pixels: 192)
        let image = NSImage(size: NSSize(width: 96, height: 96))
        image.addRepresentation(rep)
        return image
    }

    private func commandBox(_ command: String) -> some View {
        Text(command)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
