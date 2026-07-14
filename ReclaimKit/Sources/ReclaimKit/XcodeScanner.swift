import Foundation

/// DerivedData, archives, device support, and simulator caches.
public struct XcodeScanner: StorageScanner {
    public let name = "Xcode"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let developer = context.home.appendingPathComponent("Library/Developer")
        let fm = FileManager.default
        let xcodeRunning = context.processes.hasProcess(named: "Xcode")
        var items: [ScanItem] = []

        let derivedData = developer.appendingPathComponent("Xcode/DerivedData")
        for entry in fm.contentsOfDirectoryIfPresent(derivedData) where fm.directoryExists(entry) {
            try Task.checkCancellation()
            if entry.lastPathComponent.hasSuffix(".noindex") || entry.lastPathComponent == "SDKExplicitPrecompiledModules" {
                var item = ScanItem(
                    path: entry.path,
                    displayName: "Shared build cache (\(entry.lastPathComponent))",
                    tool: .xcode,
                    category: .toolCache,
                    lastActivity: latestModification(in: entry, maxDepth: 0),
                    hasActiveProcess: xcodeRunning
                )
                (item.safety, item.reasons) = Classifier.classify(item)
                items.append(item)
                continue
            }
            let meta = derivedDataInfo(entry)
            var item = ScanItem(
                path: entry.path,
                displayName: meta.name,
                tool: .xcode,
                category: .derivedData,
                lastActivity: latestModification(in: entry, maxDepth: 0),
                hasActiveProcess: xcodeRunning
                    && meta.workspacePath.map { context.processes.referencesPath($0) } ?? false
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            items.append(item)
        }

        let simpleLocations: [(String, StorageCategory, String)] = [
            ("Xcode/Archives", .archives, "Xcode archives"),
            ("Xcode/iOS DeviceSupport", .deviceSupport, "iOS device support"),
            ("Xcode/watchOS DeviceSupport", .deviceSupport, "watchOS device support"),
            ("CoreSimulator/Caches", .toolCache, "Simulator caches"),
            ("CoreSimulator/Devices", .simulators, "Simulator devices"),
        ]
        for (relative, category, title) in simpleLocations {
            let url = developer.appendingPathComponent(relative)
            guard fm.directoryExists(url), !fm.contentsOfDirectoryIfPresent(url).isEmpty else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: title,
                tool: .xcode,
                category: category,
                lastActivity: latestModification(in: url, maxDepth: 1),
                hasActiveProcess: category == .simulators && context.processes.hasProcess(named: "Simulator")
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            items.append(item)
        }
        return items
    }

    /// DerivedData folders are "<Name>-<hash>"; the info.plist inside names the workspace.
    private func derivedDataInfo(_ url: URL) -> (name: String, workspacePath: String?) {
        let plist = url.appendingPathComponent("info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let workspacePath = dict["WorkspacePath"] as? String {
            return (URL(filePath: workspacePath).deletingPathExtension().lastPathComponent, workspacePath)
        }
        let name = url.lastPathComponent
        if let dash = name.lastIndex(of: "-") {
            return (String(name[..<dash]), nil)
        }
        return (name, nil)
    }
}
