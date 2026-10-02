import SwiftUI
import AppKit
import ColimaKit

/// Headless entry points used by the end-to-end checks (`scripts/e2e-app.sh`) and the README screenshots.
enum Launch {
    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Refreshes once against the real Colima and writes what the app sees as JSON.
    @MainActor
    static func dumpState(of store: ColimaStore, to path: String) async {
        await store.refresh()
        let state: [String: Any] = [
            "toolMissing": store.toolMissing as Any? ?? NSNull(),
            "selectedProfile": store.selectedProfile?.name ?? NSNull(),
            "profiles": store.profiles.map { ["name": $0.name, "status": $0.status.rawValue, "cpus": $0.cpus, "runtime": $0.runtime] },
            "containers": store.containers.map {
                ["id": $0.id, "name": $0.name, "image": $0.image, "state": $0.state.rawValue,
                 "stack": $0.composeProject ?? NSNull(), "ports": $0.ports.map(\.label)] as [String: Any]
            },
            "groups": store.groups.map { ["title": $0.title, "running": $0.runningCount, "total": $0.containers.count] as [String: Any] },
            "diskUsage": store.diskUsage.map { usage in
                usage.entries.map { ["type": $0.kind.rawValue, "count": $0.totalCount, "bytes": $0.sizeBytes, "reclaimable": $0.reclaimableBytes] as [String: Any] }
            } ?? NSNull(),
            "vmDisk": store.vmDisk.map { ["mount": $0.mount, "total": $0.totalBytes, "used": $0.usedBytes] as [String: Any] } ?? NSNull(),
            "attention": store.attention.map(\.message),
            "historySamples": store.history.samples.count,
            "effectiveAppearance": NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "unknown",
            "images": store.images.count,
            "volumes": store.volumes.count,
            "networks": store.networks.count,
            "activeContext": store.activeContext ?? NSNull(),
            "errors": store.activity.filter { $0.level == .error }.map(\.message),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Rendering

    /// Renders `root` offscreen and returns it as PNG data. Needs no screen-recording permission.
    @MainActor
    static func render(_ root: AnyView, size: NSSize, dark: Bool = false, settle: TimeInterval = 1.0) -> Data? {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        // SwiftUI only starts a view's tasks (like the log stream) once its window is really on screen.
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// `--snapshot <png>`: the main window, or just one view with COLIMAUI_SNAPSHOT=menu|sidebar.
    @MainActor
    static func snapshot(of store: ColimaStore, to path: String) {
        let target = ProcessInfo.processInfo.environment["COLIMAUI_SNAPSHOT"] ?? "main"
        let size: NSSize
        let root: AnyView
        switch target {
        case "menu":
            size = NSSize(width: 340, height: 520)
            root = AnyView(MenuBarView().environment(store).frame(width: size.width, height: size.height, alignment: .top))
        case "sidebar":
            size = NSSize(width: 220, height: 420)
            root = AnyView(SidebarView(sectionName: .constant(NavSection.containers.rawValue)).environment(store))
        case let t where t.hasPrefix("compose-") || t == "drop":
            size = NSSize(width: 640, height: t == "drop" ? 360 : 640)
            root = AnyView(composeSample(t, store: store))
        default:
            size = NSSize(width: 1100, height: 700)
            root = AnyView(MainView().environment(store).environment(ComposeDropModel(store: store)))
        }
        let dark = ProcessInfo.processInfo.environment["COLIMAUI_DARK"] == "1"
        if let png = render(root, size: size, dark: dark, settle: 2.5) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: Compose screens

    private static let sampleConfig = """
    {"name":"shop","services":{
      "db":{"image":"postgres:16","volumes":[{"type":"volume","source":"pg","target":"/var/lib/postgresql/data"}]},
      "api":{"build":{"context":"/Users/demo/storefront/api"},"ports":[{"target":8080,"published":"8080","protocol":"tcp"}]},
      "web":{"build":{"context":"/Users/demo/storefront/web"},"ports":[{"target":80,"published":"3000","protocol":"tcp"}],
             "volumes":[{"type":"bind","source":"/Users/demo/storefront/data","target":"/data"},{"type":"bind","source":"/Users/demo/storefront/web","target":"/app"}]}}}
    """

    /// The compose sheet in a fixed state, for checking the layout without running anything.
    @MainActor
    static func composeSample(_ kind: String, store: ColimaStore) -> some View {
        let input = ComposeInput(files: ["/Users/demo/storefront/compose.yml"], workingDir: "/Users/demo/storefront", suggestedName: "storefront")
        let plan = try? ComposePlan.parse(configJSON: sampleConfig, stderr: "", input: input, localImages: [])
        var warned = plan
        warned?.warnings.append("The \"STRIPE_KEY\" variable is not set. Defaulting to a blank string.")
        warned?.envVariableCount = 3
        let phase: ComposeDropModel.Phase
        switch kind {
        case "compose-running":
            var progress = ComposeProgress(plan: plan!, project: "shop")
            ["Image postgres:16 Pulling", "Image postgres:16 Pulled", "Image shop-web Building", "#9 [web 3/6] RUN npm ci",
             "#9 added 412 packages in 11s", "#10 [web 4/6] COPY . ."].forEach { progress.apply(line: $0) }
            phase = .running(progress, project: "shop", openLogs: true)
        case "compose-invalid":
            phase = .failure(.invalid("services.api.ports contains an invalid port: \"80800:80\""), files: input.files)
        case "compose-missing": phase = .failure(.composeMissing, files: input.files)
        case "compose-failed":
            phase = .failure(.failed("Error response from daemon: pull access denied for shop-api, repository does not exist or may require 'docker login'"), files: input.files)
        default: phase = .review(warned!)
        }
        let model = ComposeDropModel(store: store, previewPhase: phase, projectName: "storefront")
        return ZStack {
            if kind == "drop" {
                ScreenshotWindow(section: .containers).environment(store).environment(model).overlay { DropOverlay() }
            } else {
                ComposeSheet().environment(model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    .padding(16)
            }
        }
    }

    // MARK: README screenshots

    /// `--screenshots <dir>`: writes the README images from a built-in sample setup, never from real containers.
    @MainActor
    static func screenshots(to dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ColimaStore(runner: DemoRunner(), prerequisites: { .ready })
        let compose = ComposeDropModel(store: store)
        for _ in 0..<8 { await store.refresh() } // a few samples so the sparklines have a shape

        // The README and the portfolio use dark screenshots.
        func write(_ name: String, _ root: AnyView, size: NSSize, dark: Bool = true, settle: TimeInterval = 1.0) {
            guard let png = render(root, size: size, dark: dark, settle: settle) else { return }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        let window = NSSize(width: 1200, height: 760)

        write("dashboard", AnyView(ScreenshotWindow(section: .dashboard).environment(store).environment(compose)), size: window)
        write("containers", AnyView(ScreenshotWindow(section: .containers).environment(store).environment(compose)), size: window)

        if let web = store.containers.first(where: { $0.name == "shop-api-1" }) {
            var seed: [String] = []
            if let client = store.docker {
                do { for try await line in client.logs(id: web.id, tail: 50, follow: false) { seed.append(line) } } catch {}
            }
            ScreenshotSeed.logLines = seed
            store.requestedSelection = "container:\(web.id)"
            write("container-logs", AnyView(ScreenshotWindow(section: .containers).environment(store).environment(compose)), size: window, settle: 1.5)
            store.requestedSelection = nil
            ScreenshotSeed.logLines = nil
        }
        write("images", AnyView(ScreenshotWindow(section: .images).environment(store).environment(compose)), size: window)
        write("profiles", AnyView(ScreenshotWindow(section: .profiles).environment(store).environment(compose)), size: window)
        write("compose-review", AnyView(composeSample("compose-review", store: store)), size: NSSize(width: 640, height: 640))
        write("menu-bar", AnyView(ScreenshotPopover().environment(store).environment(compose)), size: NSSize(width: 372, height: 470))

        let empty = ColimaStore(runner: DemoRunner(), prerequisites: { Prerequisites(missing: ["colima", "docker"], brewAvailable: true) })
        await empty.refresh()
        write("setup", AnyView(ScreenshotWindow(section: .dashboard, showsSetup: true).environment(empty).environment(ComposeDropModel(store: empty))), size: window)
    }
}

/// Stand-in for the app window: a real window frame can't be captured without screen-recording permission,
/// so the screenshots draw the same sidebar and pages inside a faux title bar.
struct ScreenshotWindow: View {
    @Environment(ColimaStore.self) private var store
    var section: NavSection
    var showsSetup = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                Spacer()
                Text("ColimaUI").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 60)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if showsSetup {
                SetupView()
            } else {
                HStack(spacing: 0) {
                    SidebarView(sectionName: .constant(section.rawValue))
                        .frame(width: 220)
                        .background(Color.primary.opacity(0.045))
                    Divider()
                    VStack(spacing: 0) {
                        StatusBanner(goToProfiles: {})
                        PageView(section: section, navigate: { _ in })
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
    }
}

struct ScreenshotPopover: View {
    var body: some View {
        MenuBarView()
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            .padding(16)
    }
}
