import SwiftUI
import ReclaimKit

@main
struct ReclaimApp: App {
    @State private var model = AppModel()
    @State private var notchHUD = NotchHUDController()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .task { DockIcon.install() }
                .onChange(of: model.lastScanDate) {
                    notchHUD.update(model: model)
                    Task { await NotificationManager.checkAfterScan(model: model) }
                }
                .onChange(of: model.isScanning) { wasScanning, isScanning in
                    notchHUD.update(model: model)
                    if wasScanning && !isScanning && model.lastScanDate != nil {
                        ChipTune.playScanComplete()
                    }
                }
                .onChange(of: model.isCleaning) { wasCleaning, isCleaning in
                    notchHUD.update(model: model)
                    if wasCleaning && !isCleaning {
                        ChipTune.playScanComplete()
                    }
                }
        }
        .defaultSize(width: 1000, height: 720)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra("Reclaim", systemImage: menuBarSymbol, isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(model)
        }
    }

    private var menuBarSymbol: String {
        model.isScanning ? "internaldrive.badge.timemachine" : "internaldrive"
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isBusy {
            Text(model.statusLine)
        } else if let date = model.lastScanDate {
            Text("Last scan \(date.formatted(.relative(presentation: .named)))")
            Text("\(model.totalBytes.formattedBytes) found · \(model.safeBytes.formattedBytes) safe to clean")
        } else {
            Text("No scan yet")
        }
        Divider()
        Button(model.isScanning ? "Stop Scan" : "Scan Now") {
            model.isScanning ? model.cancelScan() : model.scan()
        }
        Button("Open Reclaim") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
