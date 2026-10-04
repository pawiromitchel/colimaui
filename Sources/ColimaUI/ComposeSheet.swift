import SwiftUI
import UniformTypeIdentifiers
import ColimaKit

/// The sheet behind "drop a compose file": review, progress, and the ways it can go wrong.
struct ComposeSheet: View {
    @Environment(ComposeDropModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .reading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the compose file…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .review(let plan):
                ReviewView(plan: plan)
            case .running(let progress, let project, _):
                RunningView(progress: progress, project: project)
            case .done(let project, _, let isUpdate):
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                    Text("\(isUpdate ? "Updated" : "Started") \(project)").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .failure(let failure, let files):
                FailureView(failure: failure, files: files)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

private struct ReviewView: View {
    @Environment(ComposeDropModel.self) private var model
    var plan: ComposePlan

    var body: some View {
        @Bindable var model = model
        let update = model.isUpdate(model.projectName)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(update ? "Update a stack" : "Start a stack").font(.title3.weight(.medium)).displayTracking()
                Text(plan.input.files.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " + "))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Text("Stack name").foregroundStyle(.secondary)
                TextField("name", text: $model.projectName).textFieldStyle(.roundedBorder)
                Badge(text: update ? "Exists" : "New", color: update ? .orange : .green)
            }
            if !model.nameIsValid && !model.projectName.isEmpty {
                Text("Use lowercase letters, digits, dashes and underscores, starting with a letter or digit.")
                    .font(.caption).foregroundStyle(.red)
            }

            section("Services (\(plan.services.count))") {
                ForEach(plan.services) { service in
                    HStack(spacing: 8) {
                        Text(service.name).frame(width: 100, alignment: .leading)
                        Text(detail(service)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        switch service.action {
                        case .build: Badge(text: "Build", color: .orange)
                        case .pull: Badge(text: "Pull", color: .blue)
                        case .local: Badge(text: "Ready", color: .green)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }

            if !plan.browserPorts.isEmpty || !plan.binds.isEmpty {
                section("Ports and folders") {
                    if !plan.browserPorts.isEmpty {
                        factRow("Opens in your browser") {
                            HStack(spacing: 8) {
                                ForEach(plan.browserPorts, id: \.self) { Text(verbatim: "\($0.published ?? $0.target) ↗").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                    if !plan.binds.isEmpty {
                        factRow("Mounts from your Mac") {
                            Text(plan.binds.map { ($0.source as NSString).abbreviatingWithTildeInPath }.prefix(3).joined(separator: ", ")
                                 + (plan.binds.count > 3 ? " +\(plan.binds.count - 3)" : ""))
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }

            VStack(spacing: 6) {
                ForEach(plan.warnings, id: \.self) { Note(text: $0, systemImage: "exclamationmark.triangle.fill", color: .orange) }
                if let count = plan.envVariableCount {
                    Note(text: ".env found next to the file: \(count) variable\(count == 1 ? "" : "s") will be used.",
                         systemImage: "doc.text", color: .secondary)
                }
            }

            HStack {
                if update {
                    Text("Services that changed are recreated; the rest keep running.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button(update ? "Update" : "Start") { model.start(openLogs: false) }.disabled(!model.nameIsValid)
                Button(update ? "Update and open logs" : "Start and open logs") { model.start(openLogs: true) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.nameIsValid)
            }
        }
    }

    private func detail(_ s: ComposeService) -> String {
        switch s.action {
        case .build: "builds from \(s.buildContext.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "source")"
        default: s.image ?? ""
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private func factRow<C: View>(_ label: String, @ViewBuilder _ value: () -> C) -> some View {
        HStack {
            Text(label)
            Spacer()
            value()
        }
        .font(.callout).padding(.vertical, 3)
    }
}

private struct RunningView: View {
    @Environment(ComposeDropModel.self) private var model
    var progress: ComposeProgress
    var project: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Starting \(project)…").font(.title3.weight(.medium)).displayTracking()
            VStack(alignment: .leading, spacing: 0) {
                row(icon: "checkmark.circle.fill", color: .green, title: "Checked the compose file", state: .done)
                ForEach(progress.stages) { stage in
                    HStack(spacing: 10) {
                        icon(stage.state).frame(width: 18)
                        Text(stage.title).foregroundStyle(stage.state == .pending ? .secondary : .primary)
                        Spacer()
                        if let fraction = stage.fraction, stage.state == .running {
                            ProgressView(value: fraction).frame(width: 90)
                        }
                        if let detail = stage.detail, stage.state == .running {
                            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            ScrollView {
                Text(progress.log.suffix(8).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 110)
            .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("You can close this; ColimaUI tells you when it's done.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
                Button("Run in background") { model.runInBackground() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row(icon: String, color: Color, title: String, state: ComposeProgress.State) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(title)
            Spacer()
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func icon(_ state: ComposeProgress.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct FailureView: View {
    @Environment(ComposeDropModel.self) private var model
    var failure: ComposeDropModel.Failure
    var files: [String]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch failure {
            case .notComposeFile:
                header("That doesn't look like a compose file", "Drop a compose.yml, docker-compose.yml, or a folder that has one.")
            case .noVM:
                header("Colima isn't running", "Start it from the dashboard, then drop the file again.")
            case .composeMissing:
                header("Docker Compose isn't installed", "Compose is a separate tool from Docker's command line. Install it with Homebrew, then drop the file again.")
                Text("brew install docker-compose").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            case .invalid(let message):
                header("That file has a problem", "This is Docker's own message. Fix the file and drop it again.")
                errorBox(message)
            case .failed(let message):
                header("Couldn't start the stack", "Compose stopped with an error. Anything it already created is still there.")
                errorBox(message)
            }
            HStack {
                Spacer()
                if !files.isEmpty, failure != .composeMissing, failure != .noVM {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: $0) }) }
                }
                if case .composeMissing = failure {
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install docker-compose", forType: .string)
                        copied = true
                    }
                    Button("Install in Terminal") { Terminal.run("brew install docker-compose") }.buttonStyle(.borderedProminent)
                } else {
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func header(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.medium)).displayTracking()
            Text(message).foregroundStyle(.secondary)
        }
    }

    private func errorBox(_ message: String) -> some View {
        ScrollView {
            Text(message).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(maxHeight: 130)
        .background(Color.red.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 0.5))
    }
}

private struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16)).foregroundStyle(color).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct Note: View {
    var text: String
    var systemImage: String
    var color: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout).foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Shown over the window while a file is dragged across it.
struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.1)))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                    Text("Drop to start a stack").font(.title3.weight(.medium)).displayTracking().foregroundStyle(Color.accentColor)
                    Text("compose.yml, docker-compose.yml, or a folder that has one").foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

/// A short message at the bottom of the window, like "Started shop".
struct Toast: View {
    var notice: ColimaStore.Notice
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
            Text(notice.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .floatingSurface(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

enum ComposePicker {
    /// "Start Stack from Compose File…" in the File menu and the Containers toolbar.
    @MainActor
    static func choose(then handle: ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a compose file"
        panel.message = "Choose a compose.yml or docker-compose.yml, or a folder that contains one."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { handle(panel.urls) }
    }
}
