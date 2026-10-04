import SwiftUI
import ColimaKit

private struct PageHeader<Actions: View>: View {
    var title: String
    var count: Int
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.medium)).displayTracking()
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
            actions
        }
        .padding(12)
    }
}

struct ImagesView: View {
    @Environment(ColimaStore.self) private var store
    @State private var pullReference = ""
    @State private var pulling = false
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Images", count: store.images.count) {
                TextField("Pull image, e.g. redis:7", text: $pullReference)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit(pull)
                Button("Pull", action: pull).disabled(pulling)
                Button("Prune unused") {
                    pendingDelete = DeleteRequest(title: "Prune unused images?",
                                                  message: "Dangling images are removed.", confirmLabel: "Prune") {
                        await store.prune(.images)
                    }
                }
            }
            Divider()
            if !store.hasLoaded || (store.selectedProfileIsBusy && store.images.isEmpty) {
                LoadingState(message: "Loading images…")
            } else if store.images.isEmpty {
                EmptyState(systemImage: "square.stack.3d.up", title: "No images", message: "Pull an image to get started.")
            } else {
                List(store.images) { image in
                    let users = store.containers(using: image)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.reference).font(.system(.body, design: .monospaced))
                            Text("\(image.id) · \(image.createdSince)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if users.isEmpty {
                            Text("Unused").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("In use by \(users.map(\.displayName).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(image.size).font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                        IconButton(systemName: "trash", help: users.isEmpty ? "Delete image" : "In use by a container",
                                   role: .destructive, disabled: !users.isEmpty) {
                            pendingDelete = DeleteRequest(title: "Delete \(image.reference)?", message: "The image is removed from Colima.") {
                                await store.removeImage(image)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Images")
        .confirm($pendingDelete)
    }

    private func pull() {
        let ref = pullReference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !pulling else { return }
        pulling = true
        Task {
            await store.pullImage(ref)
            pullReference = ""
            pulling = false
        }
    }
}

struct VolumesView: View {
    @Environment(ColimaStore.self) private var store
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Volumes", count: store.volumes.count) {
                Button("Prune unused") {
                    pendingDelete = DeleteRequest(title: "Prune unused volumes?",
                                                  message: "Volumes not used by any container are deleted. This can't be undone.",
                                                  confirmLabel: "Prune") { await store.prune(.volumes) }
                }
            }
            Divider()
            if !store.hasLoaded || (store.selectedProfileIsBusy && store.volumes.isEmpty) {
                LoadingState(message: "Loading volumes…")
            } else if store.volumes.isEmpty {
                EmptyState(systemImage: "externaldrive", title: "No volumes", message: "Volumes created by your containers appear here.")
            } else {
                List(store.volumes) { volume in
                    let owners = Grouping.volumeOwner(volume, in: store.containers)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(volume.composeProject.map { "Stack \($0)" } ?? (volume.isAnonymous ? "Anonymous" : volume.driver))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !owners.isEmpty {
                            Text("\(owners.count) container\(owners.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        IconButton(systemName: "trash", help: "Delete volume", role: .destructive) {
                            pendingDelete = DeleteRequest(title: "Delete \(volume.name)?",
                                                          message: "The data in this volume is lost.") { await store.removeVolume(volume) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Volumes")
        .confirm($pendingDelete)
    }
}

struct NetworksView: View {
    @Environment(ColimaStore.self) private var store
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Networks", count: store.networks.count) { EmptyView() }
            Divider()
            if !store.hasLoaded || (store.selectedProfileIsBusy && store.networks.isEmpty) {
                LoadingState(message: "Loading networks…")
            } else if store.networks.isEmpty {
                EmptyState(systemImage: "network", title: "No networks", message: "Docker creates networks for your stacks.")
            } else {
                List(store.networks) { network in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.name).font(.system(.body, design: .monospaced))
                            Text("\(network.driver) · \(network.scope)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if network.isBuiltIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
                        IconButton(systemName: "trash", help: network.isBuiltIn ? "Built-in networks can't be deleted" : "Delete network",
                                   role: .destructive, disabled: network.isBuiltIn) {
                            pendingDelete = DeleteRequest(title: "Delete \(network.name)?",
                                                          message: "Containers attached to it are disconnected.") { await store.removeNetwork(network) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Networks")
        .confirm($pendingDelete)
    }
}
