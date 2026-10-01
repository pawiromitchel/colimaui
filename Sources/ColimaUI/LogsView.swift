import SwiftUI
import ColimaKit

struct LogSource: Hashable {
    var id: String
    var label: String?
}

struct LogLine: Identifiable, Equatable {
    let id: Int
    var label: String?
    var text: String
}

@MainActor
@Observable
final class LogModel {
    private(set) var lines: [LogLine] = []
    private(set) var error: String?
    private var counter = 0
    private let cap = 3000

    func append(label: String?, text: String) {
        counter += 1
        lines.append(LogLine(id: counter, label: label, text: ANSI.strip(text)))
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }

    func clear() { lines = []; error = nil }

    func run(client: DockerClient, sources: [LogSource], timestamps: Bool) async {
        clear()
        await withTaskGroup(of: String?.self) { group in
            for source in sources {
                group.addTask { [weak self] in
                    do {
                        for try await line in client.logs(id: source.id, tail: 200, follow: true, timestamps: timestamps) {
                            await self?.append(label: source.label, text: line)
                        }
                        return nil
                    } catch { return error.localizedDescription }
                }
            }
            for await failure in group { if let failure { error = failure } }
        }
    }
}

/// Lets the README screenshot renderer show log lines without a live stream, which doesn't start offscreen.
enum ScreenshotSeed {
    @MainActor static var logLines: [String]?
}

struct LogsView: View {
    @Environment(ColimaStore.self) private var store
    var sources: [LogSource]

    @State private var model = LogModel()
    @State private var filter = ""
    @State private var follow = true
    @State private var timestamps = false

    private var visible: [LogLine] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.lines : model.lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if let label = line.label {
                                    Text(label).foregroundStyle(color(for: label)).frame(width: 80, alignment: .leading).lineLimit(1)
                                }
                                Text(line.text).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .id(line.id)
                        }
                        if visible.isEmpty {
                            Text(model.error ?? "No log output yet.").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.06))
                .onChange(of: model.lines.count) {
                    if follow, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                TextField("Filter logs", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Toggle("Follow", isOn: $follow)
                Toggle("Timestamps", isOn: $timestamps)
                Spacer()
                Button("Clear") { model.clear() }
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .padding(8)
        }
        .task(id: TaskKey(sources: sources, timestamps: timestamps, profile: store.selectedProfile?.name)) {
            if let seed = ScreenshotSeed.logLines {
                model.clear()
                seed.forEach { model.append(label: nil, text: $0) }
                return
            }
            guard let client = store.docker else { return }
            await model.run(client: client, sources: sources, timestamps: timestamps)
        }
    }

    private struct TaskKey: Hashable { var sources: [LogSource]; var timestamps: Bool; var profile: String? }

    private func color(for label: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]
        return palette[abs(label.hashValue) % palette.count]
    }
}

struct InspectView: View {
    @Environment(ColimaStore.self) private var store
    var id: String
    @State private var text = "Loading…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.secondary.opacity(0.06))
        .task(id: id) {
            guard let client = store.docker else { return }
            do {
                let raw = try await client.inspect(id)
                if let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                    text = String(decoding: pretty, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
                } else { text = raw }
            } catch { text = error.localizedDescription }
        }
    }
}
