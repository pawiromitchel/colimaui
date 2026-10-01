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
        default:
            size = NSSize(width: 1100, height: 700)
            root = AnyView(MainView().environment(store))
        }
        if let png = render(root, size: size, settle: 2.5) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: README screenshots

    /// `--screenshots <dir>`: writes the README images from a built-in sample setup, never from real containers.
    @MainActor
    static func screenshots(to dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ColimaStore(runner: DemoRunner(), prerequisites: { .ready })
        for _ in 0..<8 { await store.refresh() } // a few samples so the sparklines have a shape

        func write(_ name: String, _ root: AnyView, size: NSSize, dark: Bool = false, settle: TimeInterval = 1.0) {
            guard let png = render(root, size: size, dark: dark, settle: settle) else { return }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        let window = NSSize(width: 1200, height: 760)

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            write("dashboard\(suffix)", AnyView(ScreenshotWindow(section: .dashboard).environment(store)), size: window, dark: dark)
        }
        write("containers", AnyView(ScreenshotWindow(section: .containers).environment(store)), size: window)

        if let web = store.containers.first(where: { $0.name == "shop-api-1" }) {
            var seed: [String] = []
            if let client = store.docker {
                do { for try await line in client.logs(id: web.id, tail: 50, follow: false) { seed.append(line) } } catch {}
            }
            ScreenshotSeed.logLines = seed
            store.requestedSelection = "container:\(web.id)"
            write("container-logs", AnyView(ScreenshotWindow(section: .containers).environment(store)), size: window, settle: 1.5)
            store.requestedSelection = nil
            ScreenshotSeed.logLines = nil
        }
        write("images", AnyView(ScreenshotWindow(section: .images).environment(store)), size: window)
        write("profiles", AnyView(ScreenshotWindow(section: .profiles).environment(store)), size: window)
        write("menu-bar", AnyView(ScreenshotPopover().environment(store)), size: NSSize(width: 372, height: 470))

        let empty = ColimaStore(runner: DemoRunner(), prerequisites: { Prerequisites(missing: ["colima", "docker"], brewAvailable: true) })
        await empty.refresh()
        write("setup", AnyView(ScreenshotWindow(section: .dashboard, showsSetup: true).environment(empty)), size: window)
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
