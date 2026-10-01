import SwiftUI
import ColimaKit

enum NavSection: String, CaseIterable, Identifiable {
    case containers = "Containers", images = "Images", volumes = "Volumes", networks = "Networks"
    case profiles = "Profiles"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .profiles: "server.rack"
        }
    }
}

struct MainView: View {
    @Environment(ColimaStore.self) private var store
    @AppStorage("selectedSection") private var sectionName = NavSection.containers.rawValue

    private var section: NavSection { NavSection(rawValue: sectionName) ?? .containers }

    var body: some View {
        NavigationSplitView {
            SidebarView(sectionName: $sectionName)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner(goToProfiles: { sectionName = NavSection.profiles.rawValue })
                ZStack {
                    switch section {
                    case .containers: ContainersView().transition(.opacity)
                    case .images: ImagesView().transition(.opacity)
                    case .volumes: VolumesView().transition(.opacity)
                    case .networks: NetworksView().transition(.opacity)
                    case .profiles: ProfilesView().transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: sectionName)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }
}

struct SidebarView: View {
    @Environment(ColimaStore.self) private var store
    @Binding var sectionName: String

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            profilePicker
            List(selection: Binding(get: { sectionName }, set: { if let s = $0 { sectionName = s } })) {
                ForEach(NavSection.allCases.filter { $0 != .profiles }) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section.rawValue)
                }
                Divider()
                Label(NavSection.profiles.rawValue, systemImage: NavSection.profiles.icon).tag(NavSection.profiles.rawValue)
            }
            .listStyle(.sidebar)
            if let p = store.selectedProfile { resources(p) }
        }
    }

    private var profilePicker: some View {
        HStack(spacing: 8) {
            StatusDot(color: store.selectedProfile?.status.color ?? .secondary)
            if store.profiles.count > 1 {
                Menu(store.selectedProfile?.name ?? "No profile") {
                    ForEach(store.profiles) { p in
                        Button(p.name + (p.isRunning ? "" : " (stopped)")) { store.selectedProfileName = p.name; Task { await store.refresh() } }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Text(store.selectedProfile?.name ?? "No profile").fontWeight(.medium)
            }
            Spacer()
            if let p = store.selectedProfile {
                Text("\(p.runtime) · \(p.arch)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func resources(_ p: ColimaProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            Text("\(p.cpus) CPU · \(Format.bytes(p.memoryBytes)) RAM").font(.caption).foregroundStyle(.secondary)
            Text("\(Format.bytes(p.diskBytes)) disk · \(store.runningContainerCount) running").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusBanner: View {
    @Environment(ColimaStore.self) private var store
    var goToProfiles: () -> Void

    var body: some View {
        if let missing = store.toolMissing {
            banner(icon: "exclamationmark.triangle.fill", text: missing, tint: .orange) { EmptyView() }
        } else if store.profiles.isEmpty && store.lastRefresh != nil {
            banner(icon: "info.circle.fill", text: "No Colima profiles yet. Create one to get started.", tint: .blue) {
                Button("Create profile", action: goToProfiles)
            }
        } else if let p = store.selectedProfile, !p.isRunning {
            banner(icon: "pause.circle.fill", text: "Profile \(p.name) is stopped.", tint: .secondary) {
                Button(store.busyProfiles.contains(p.name) ? "Starting…" : "Start") { Task { await store.startProfile(p.name) } }
                    .disabled(store.busyProfiles.contains(p.name))
            }
        }
    }

    private func banner<Trailing: View>(icon: String, text: String, tint: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }
}
