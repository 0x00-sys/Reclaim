import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public private(set) var items: [ScanItem] = []
    public private(set) var isScanning = false
    public private(set) var scanProgress = ""
    /// Tool whose storage is being scanned right now (drives the notch sprite).
    public private(set) var currentTool: Tool?
    public private(set) var lastScanDate: Date?
    public private(set) var cleanupResults: [CleanupResult] = []
    public private(set) var isCleaning = false
    public private(set) var cleaningStatus = ""
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

    public var totalBytes: Int64 { items.totalSizeBytes }
    public var safeBytes: Int64 { items.filter { $0.safety == .safe }.totalSizeBytes }
    public var selectedItems: [ScanItem] { items.filter { selection.contains($0.id) } }
    public var selectedBytes: Int64 { selectedItems.totalSizeBytes }

    /// The one status line the notch, menu bar, and hero all render.
    public var statusLine: String {
        if isCleaning { return cleaningStatus }
        if isScanning { return scanProgress.isEmpty ? "Scanning…" : scanProgress }
        return "\(safeBytes.formattedBytes) safe to clean"
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentTool = nil
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
        var collected: [ScanItem] = []
        for (scanner, tool) in defaultScanners {
            if Task.isCancelled { return }
            scanProgress = "Scanning \(scanner.name)…"
            currentTool = tool
            do {
                collected.append(contentsOf: try await scanner.scan(context: context))
            } catch is CancellationError {
                return
            } catch {
                // One scanner failing must not sink the rest.
            }
            items = deduplicateScanItems(collected).sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }

        scanProgress = "Measuring sizes…"
        currentTool = nil
        await measureSizes()
        items.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        scanProgress = ""
    }

    private func measureSizes() async {
        let unsized = items.filter { $0.sizeBytes == nil }.map(\.url)
        var indexByPath = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.path, $0) })
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
                if let index = indexByPath[path] {
                    items[index].sizeBytes = size
                }
                if Task.isCancelled { group.cancelAll(); break }
                addNext(&group)
            }
        }
    }

    public func clean(_ selected: [ScanItem]) async {
        guard !isCleaning else { return }
        isCleaning = true
        cleaningStatus = "Preparing…"
        var done = 0
        var freed: Int64 = 0
        let total = selected.count
        let results = await cleanupEngine.clean(items: selected) { [weak self] result in
            done += 1
            freed += result.freedBytes ?? 0
            self?.cleaningStatus = "Cleaning \(done) of \(total) · \(freed.formattedBytes) freed"
            // Keep the list live: successfully removed items disappear as they go.
            if result.success {
                self?.items.removeAll { $0.path == result.path }
                self?.selection.remove(result.path)
            }
        }
        cleanupResults = results
        isCleaning = false
        cleaningStatus = ""
    }
}
