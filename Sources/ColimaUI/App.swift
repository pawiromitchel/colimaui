import SwiftUI
import ServiceManagement
import ColimaKit

@main
struct ColimaUIApp: App {
    @State private var store = ColimaStore()
    @State private var composeModel: ComposeDropModel
    @AppStorage("refreshSeconds") private var refreshSeconds = 5

    init() {
        let store = ColimaStore()
        _store = State(initialValue: store)
        _composeModel = State(initialValue: ComposeDropModel(store: store))
        if let path = Launch.argument("--dump-state") {
            Task { @MainActor in
                await Launch.dumpState(of: store, to: path)
                exit(0)
            }
        } else if let dir = Launch.argument("--screenshots") {
            Task { @MainActor in
                await Launch.screenshots(to: dir)
                exit(0)
            }
        } else if let path = Launch.argument("--snapshot") {
            Task { @MainActor in
                await store.refresh()
                await store.refresh() // a second sample so the sparklines have a line to draw
                Launch.snapshot(of: store, to: path)
                exit(0)
            }
        } else {
            store.startAutoRefresh(interval: .seconds(UserDefaults.standard.object(forKey: "refreshSeconds") as? Int ?? 5))
        }
    }

    var body: some Scene {
        Window("ColimaUI", id: "main") {
            MainView().environment(store).environment(composeModel)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { ComposeCommands(model: composeModel) }

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            MenuBarLabel().environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }
    }
}

struct ComposeCommands: Commands {
    var model: ComposeDropModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Start Stack from Compose File…") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
                ComposePicker.choose { model.begin(urls: $0) }
            }
            .keyboardShortcut("o")
        }
    }
}

struct SettingsView: View {
    @Environment(ColimaStore.self) private var store
    @AppStorage("refreshSeconds") private var refreshSeconds = 5
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        Form {
            Picker("Refresh every", selection: $refreshSeconds) {
                ForEach([2, 5, 10, 30], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            .onChange(of: refreshSeconds) { store.startAutoRefresh(interval: .seconds(refreshSeconds)) }

            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    do {
                        if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = "Open at login only works from the packaged app."
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                Link("ColimaUI on GitHub", destination: URL(string: "https://github.com/pawiromitchel/colimaui")!)
            }

            Section("Prune") {
                HStack {
                    Button("Prune unused images") { Task { await store.prune(.images) } }
                    Button("Prune everything unused") { Task { await store.prune(.system) } }
                }
                .disabled(store.docker == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
