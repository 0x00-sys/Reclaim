import Foundation
import Testing
@testable import ReclaimKit

@Suite struct InstallerScannerTests {
    private func apps(_ names: [String]) -> [(name: String, modified: Date?)] {
        names.map { ($0, nil) }
    }

    @Test func matchesVersionedInstallerToInstalledApp() {
        let installed = apps(["Proxyman", "Xcode", "LM Studio"])
        #expect(InstallerScanner.matchingApp(installerName: "Proxyman_6.11.0", installedApps: installed)?.name == "Proxyman")
        #expect(InstallerScanner.matchingApp(installerName: "proxyman latest", installedApps: installed)?.name == "Proxyman")
        #expect(InstallerScanner.matchingApp(installerName: "SomeOtherTool-2.0", installedApps: installed) == nil)
    }

    @Test func qualifiedNamesDoNotOverMatch() {
        // Xcode_27_beta_3 -> "xcode" matches Xcode; "XcodeBeta" app would not.
        #expect(InstallerScanner.matchingApp(installerName: "Xcode_27_beta_3", installedApps: apps(["Xcode"]))?.name == "Xcode")
        #expect(InstallerScanner.matchingApp(installerName: "Go2Shell", installedApps: apps(["Go"])) == nil)
    }

    @Test func installerNewerThanAppIsNotConsumed() {
        let appInstalled = Date(timeIntervalSince1970: 1_000_000)
        let downloadedBefore = Date(timeIntervalSince1970: 900_000)
        let downloadedAfter = Date(timeIntervalSince1970: 1_100_000)
        #expect(InstallerScanner.installerConsumed(appModified: appInstalled, downloaded: downloadedBefore))
        #expect(!InstallerScanner.installerConsumed(appModified: appInstalled, downloaded: downloadedAfter))
        // Unknown dates never promote to Safe.
        #expect(!InstallerScanner.installerConsumed(appModified: nil, downloaded: downloadedBefore))
        #expect(!InstallerScanner.installerConsumed(appModified: appInstalled, downloaded: nil))
    }

    @Test func scanFindsInstallersAndClassifies() async throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("installer-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("dmg".utf8).write(to: downloads.appendingPathComponent("Mystery_1.0.dmg"))
        try Data("txt".utf8).write(to: downloads.appendingPathComponent("notes.txt"))

        let items = try await InstallerScanner().scan(context: ScanContext(home: home))
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.category == .installers)
        #expect(item.sizeBytes == 3)
        // No matching app installed: stays Review, never silently Safe.
        #expect(item.safety == .review)
    }
}
