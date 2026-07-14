import SwiftUI
import ReclaimKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Locations", systemImage: "folder") { LocationSettings() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettings() }
        }
        .frame(width: 520, height: 420)
    }
}

struct GeneralSettings: View {
    @AppStorage("scanOnLaunch") private var scanOnLaunch = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false
    @AppStorage("showNotchHUD") private var showNotchHUD = true

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Scan automatically at launch", isOn: $scanOnLaunch)
            }
            Section("Status") {
                Toggle("Show status in menu bar", isOn: $showMenuBarExtra)
                Toggle("Show notch panel while scanning", isOn: $showNotchHUD)
                Text("The notch panel only appears while a scan is running and disappears a few seconds after it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LocationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Project folders") {
                ForEach(model.projectRoots, id: \.self) { root in
                    HStack {
                        Text(root).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            model.projectRoots.removeAll { $0 == root }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Folder…") { addFolder() }
                Text("Searched for git repositories and node_modules. Tool locations (~/.codex, ~/conductor, Xcode data, caches) are always scanned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.projectRoots.contains(url.path) {
                model.projectRoots.append(url.path)
            }
        }
    }
}

struct NotificationSettings: View {
    @AppStorage("notifyEnabled") private var notifyEnabled = false
    @AppStorage("notifyFreeSpaceGB") private var notifyFreeSpaceGB = 50
    @AppStorage("notifyDevStorageGB") private var notifyDevStorageGB = 100

    var body: some View {
        Form {
            Section {
                Toggle("Notify about storage conditions", isOn: $notifyEnabled)
                Stepper("Free space below \(notifyFreeSpaceGB) GB", value: $notifyFreeSpaceGB, in: 5...500, step: 5)
                    .disabled(!notifyEnabled)
                Stepper("Reclaimable dev storage above \(notifyDevStorageGB) GB", value: $notifyDevStorageGB, in: 10...1000, step: 10)
                    .disabled(!notifyEnabled)
                Text("Checked after each scan; each condition notifies at most once per day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
