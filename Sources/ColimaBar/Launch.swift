import SwiftUI
import AppKit
import ColimaKit

/// Headless entry points used by the end-to-end checks (`scripts/e2e-app.sh`).
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

    /// Renders the main window to a PNG without needing screen-recording permission.
    @MainActor
    static func snapshot(of store: ColimaStore, to path: String) {
        _ = NSApplication.shared
        let size = NSSize(width: 1100, height: 700)
        let host = NSHostingView(rootView: MainView().environment(store).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
