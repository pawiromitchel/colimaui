import SwiftUI
import ColimaKit

struct ProfilesView: View {
    @Environment(ColimaStore.self) private var store
    @State private var editing: ProfileDraft?
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(store.profiles) { profile in card(profile) }
                    Button { editing = ProfileDraft.new() } label: {
                        VStack(spacing: 6) { Image(systemName: "plus"); Text("New profile") }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.secondary.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }
                if !store.activity.isEmpty { activityLog }
            }
            .padding(16)
        }
        .navigationTitle("Profiles")
        .sheet(item: $editing) { draft in ProfileEditor(draft: draft) }
        .confirm($pendingDelete)
    }

    private func card(_ profile: ColimaProfile) -> some View {
        let busy = store.busyProfiles.contains(profile.name)
        let isActiveContext = store.activeContext == profile.dockerContext
        return Card(dimmed: !profile.isRunning) {
            HStack(spacing: 8) {
                StatusDot(color: profile.status.color)
                Text(profile.name).font(.headline)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if isActiveContext {
                    Text("Docker context").font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15)).foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(profile.status == .running ? "Running" : "Stopped").font(.caption).foregroundStyle(.secondary)
                }
            }
            KeyValueRow(key: "Runtime", value: profile.runtime)
            KeyValueRow(key: "Architecture", value: profile.arch)
            KeyValueRow(key: "Resources", value: "\(profile.cpus) CPU · \(Format.bytes(profile.memoryBytes)) · \(Format.bytes(profile.diskBytes))")
            KeyValueRow(key: "Kubernetes", value: profile.kubernetes ? "on" : "off")
            if !profile.address.isEmpty { KeyValueRow(key: "Address", value: profile.address, mono: true) }
            HStack {
                if profile.isRunning {
                    Button("Stop") { Task { await store.stopProfile(profile.name) } }.disabled(busy)
                } else {
                    Button("Start") { Task { await store.startProfile(profile.name) } }.disabled(busy)
                }
                Button("Edit") { editing = ProfileDraft(profile: profile) }.disabled(busy)
                if profile.isRunning {
                    Button("SSH") { Terminal.run("colima ssh --profile \(profile.name)") }
                }
                if !isActiveContext {
                    Button("Use context") { Task { await store.useContext(profile) } }
                }
                Spacer()
                IconButton(systemName: "trash", help: "Delete profile", role: .destructive, disabled: busy) {
                    pendingDelete = DeleteRequest(title: "Delete \(profile.name)?",
                                                  message: "The VM and everything in it, including images and volumes, is removed.") {
                        await store.deleteProfile(profile.name)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Clear") { store.clearActivity() }.buttonStyle(.borderless)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.activity.suffix(40)) { entry in
                        Text(entry.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(entry.level == .error ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 180)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ProfileEditor: View {
    @Environment(ColimaStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProfileDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isNew ? "New profile" : "Edit \(draft.name)").font(.title3.weight(.medium)).displayTracking()
            Form {
                if draft.isNew { TextField("Name", text: $draft.name, prompt: Text("dev")) }
                Stepper("CPU: \(draft.cpus)", value: $draft.cpus, in: 1...32)
                Stepper("Memory: \(draft.memoryGiB) GiB", value: $draft.memoryGiB, in: 1...128)
                Stepper("Disk: \(draft.diskGiB) GiB", value: $draft.diskGiB, in: draft.minimumDiskGiB...2000, step: 10)
                if draft.isNew {
                    Picker("Runtime", selection: $draft.runtime) { Text("docker").tag("docker"); Text("containerd").tag("containerd") }
                    Picker("VM type", selection: $draft.vmType) { Text("vz").tag("vz"); Text("qemu").tag("qemu") }
                    Toggle("Rosetta (run amd64 images)", isOn: $draft.rosetta).disabled(draft.vmType != "vz")
                }
                Toggle("Kubernetes", isOn: $draft.kubernetes)
            }
            if !draft.isNew {
                Label(draft.original?.isRunning == true
                      ? "Applying changes restarts the VM and stops its containers for a moment."
                      : "Changes apply the next time the profile starts.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Disk can only grow.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create and start" : (draft.original?.isRunning == true ? "Apply and restart" : "Apply and start")) {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.isNew && !draft.nameIsValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func apply() {
        let d = draft
        dismiss()
        Task {
            if d.isNew {
                await store.startProfile(d.name, options: d.options)
            } else if d.original?.isRunning == true {
                await store.restartProfile(d.name, options: d.options)
            } else {
                await store.startProfile(d.name, options: d.options)
            }
        }
    }
}
