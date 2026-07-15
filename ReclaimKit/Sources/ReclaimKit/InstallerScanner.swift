import Foundation

/// Leftover installer files in Downloads and on the Desktop: .dmg, .pkg, .xip,
/// .iso. Once the app is installed the file is dead weight, and most are
/// re-downloadable anyway. An installer whose app already sits in /Applications
/// classifies Safe; everything else stays Review.
public struct InstallerScanner: StorageScanner {
    public let name = "Installer files"

    static let extensions: Set<String> = ["dmg", "pkg", "xip", "iso"]

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let installed = Self.installedApplications()
        var items: [ScanItem] = []
        for folder in ["Downloads", "Desktop"] {
            let root = context.home.appendingPathComponent(folder)
            for file in FileManager.default.contentsOfDirectoryIfPresent(root)
            where Self.extensions.contains(file.pathExtension.lowercased()) {
                try Task.checkCancellation()
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let downloaded = values?.contentModificationDate
                var item = ScanItem(
                    path: file.path,
                    displayName: file.lastPathComponent,
                    tool: .installer,
                    category: .installers,
                    sizeBytes: (values?.fileSize).map(Int64.init),
                    lastActivity: downloaded
                )
                (item.safety, item.reasons) = Classifier.classify(item)
                if let app = Self.matchingApp(installerName: file.deletingPathExtension().lastPathComponent,
                                              installedApps: installed),
                   item.safety == .review {
                    if Self.installerConsumed(appModified: app.modified, downloaded: downloaded) {
                        item.safety = .safe
                        item.reasons = ["\(app.name).app is already installed in /Applications; the installer has done its job."]
                    } else {
                        item.reasons.append("\(app.name).app is installed, but it predates this download, so this may be a newer version you haven't installed yet.")
                    }
                }
                items.append(item)
            }
        }
        return items
    }

    /// App bundles (name without .app, last-modified date) in the standard
    /// applications folders. The date approximates install/update time.
    static func installedApplications(
        directories: [URL] = [URL(filePath: "/Applications"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    ) -> [(name: String, modified: Date?)] {
        directories.flatMap { directory in
            FileManager.default.contentsOfDirectoryIfPresent(directory)
                .filter { $0.pathExtension == "app" }
                .map { ($0.deletingPathExtension().lastPathComponent,
                        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        }
    }

    /// Words that may trail an app name in an installer filename without
    /// meaning a different product.
    private static let qualifierWords = [
        "beta", "alpha", "rc", "arm", "aarch", "intel", "universal", "apple",
        "silicon", "mac", "macos", "osx", "latest", "installer", "setup",
        "release", "final",
    ]

    /// Match "Proxyman_6.11.0" or "Xcode_27_beta_3" to an installed app.
    /// Digits and separators are noise; whatever letters remain after the app
    /// name must all be known qualifier words ("beta", "arm"), so "Go2Shell"
    /// never matches an installed "Go".
    static func matchingApp(
        installerName: String,
        installedApps: [(name: String, modified: Date?)]
    ) -> (name: String, modified: Date?)? {
        let installerLetters = letters(of: installerName)
        return installedApps.first { app in
            let appLetters = letters(of: app.name)
            guard appLetters.count >= 2, installerLetters.hasPrefix(appLetters) else { return false }
            var rest = installerLetters.dropFirst(appLetters.count)
            while let qualifier = qualifierWords.first(where: { rest.hasPrefix($0) }) {
                rest = rest.dropFirst(qualifier.count)
            }
            return rest.isEmpty
        }
    }

    /// The name match is version-blind, so only trust it when the app bundle
    /// changed after the download: an installer newer than the installed app
    /// is probably a not-yet-installed update.
    static func installerConsumed(appModified: Date?, downloaded: Date?) -> Bool {
        guard let appModified, let downloaded else { return false }
        return appModified >= downloaded
    }

    private static func letters(of name: String) -> String {
        String(name.lowercased().filter(\.isLetter))
    }
}
