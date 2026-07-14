import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public private(set) var items: [ScanItem] = []
    public private(set) var isScanning = false
    public private(set) var scanProgress = ""
    public private(set) var lastScanDate: Date?
    public private(set) var cleanupResults: [CleanupResult] = []
    public var selection: Set<String> = []

    public var projectRoots: [String] {
        didSet { UserDefaults.standard.set(projectRoots, forKey: "projectRoots") }
    }

    private var scanTask: Task<Void, Never>?
    private let cleanupEngine = CleanupEngine()

    public init() {
        if let stored = UserDefaults.standard.stringArray(forKey: "projectRoots") {
            projectRoots = stored
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            projectRoots = ["dev", "Developer", "Projects", "Documents"]
                .map { home.appendingPathComponent($0).path }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
    }

    public var totalBytes: Int64 { items.compactMap(\.sizeBytes).reduce(0, +) }
    public var safeBytes: Int64 { items.filter { $0.safety == .safe }.compactMap(\.sizeBytes).reduce(0, +) }
    public var selectedItems: [ScanItem] { items.filter { selection.contains($0.id) } }
    public var selectedBytes: Int64 { selectedItems.compactMap(\.sizeBytes).reduce(0, +) }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    public func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = "Preparing…"
        items = []
        selection = []
        scanTask = Task {
            await runScan()
            isScanning = false
            lastScanDate = .now
            scanTask = nil
        }
    }

    private func runScan() async {
        let context = ScanContext(
            processes: await ProcessSnapshot.capture(),
            projectRoots: projectRoots.map { URL(filePath: $0) }
        )
        let scanners: [any StorageScanner] = [
            CodexScanner(),
            ConductorScanner(),
            RepoWorktreeScanner(),
            NodeModulesScanner(),
            PackageCacheScanner(),
            XcodeScanner(),
            ClaudeCodeScanner(),
            CursorScanner(),
        ]

        var collected: [ScanItem] = []
        for scanner in scanners {
            if Task.isCancelled { return }
            scanProgress = "Scanning \(scanner.name)…"
            do {
                collected.append(contentsOf: try await scanner.scan(context: context))
            } catch is CancellationError {
                return
            } catch {
                // One scanner failing must not sink the rest.
            }
            items = deduplicate(collected).sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }
        items = deduplicate(collected)

        scanProgress = "Measuring sizes…"
        await measureSizes()
        items.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        scanProgress = ""
    }

    private func deduplicate(_ items: [ScanItem]) -> [ScanItem] {
        deduplicateScanItems(items)
    }

    private func measureSizes() async {
        let unsized = items.filter { $0.sizeBytes == nil }.map(\.url)
        await withTaskGroup(of: (String, Int64?).self) { group in
            var iterator = unsized.makeIterator()
            var running = 0
            func addNext(_ group: inout TaskGroup<(String, Int64?)>) {
                guard let url = iterator.next() else { return }
                running += 1
                group.addTask {
                    (url.path, try? await DirectorySizer.allocatedSize(of: url))
                }
            }
            for _ in 0..<4 { addNext(&group) }
            while running > 0 {
                guard let (path, size) = await group.next() else { break }
                running -= 1
                if let index = items.firstIndex(where: { $0.path == path }) {
                    items[index].sizeBytes = size
                }
                if Task.isCancelled { group.cancelAll(); break }
                addNext(&group)
            }
        }
    }

    public func clean(_ selected: [ScanItem]) async {
        let results = await cleanupEngine.clean(items: selected)
        cleanupResults = results
        let removed = Set(results.filter(\.success).map(\.path))
        items.removeAll { removed.contains($0.path) }
        selection.subtract(removed)
    }
}
