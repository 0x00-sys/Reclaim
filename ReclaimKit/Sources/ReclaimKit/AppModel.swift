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
    private var cleanedPaths: Set<String> = []
    private let cleanupEngine = CleanupEngine()

    public var isBusy: Bool { isScanning || isCleaning }

    public init() {
        if let stored = UserDefaults.standard.stringArray(forKey: "projectRoots") {
            projectRoots = stored
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            projectRoots = ["dev", "Developer", "Projects", "Documents"]
                .map { home.appendingPathComponent($0).path }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
        loadSnapshot()
    }

    // MARK: Scan snapshot (last results survive relaunch; a few hundred KB of JSON)

    private struct Snapshot: Codable {
        var date: Date
        var items: [ScanItem]
    }

    private static let snapshotURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reclaim", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("last-scan.json")
    }()

    private func saveSnapshot() {
        guard let date = lastScanDate else { return }
        if let data = try? JSONEncoder().encode(Snapshot(date: date, items: items)) {
            try? data.write(to: Self.snapshotURL, options: .atomic)
        }
    }

    /// Restores the previous scan on launch. Verdicts may be stale, but every
    /// destructive path re-verifies at deletion time, so acting on them is safe.
    private func loadSnapshot() {
        guard items.isEmpty,
              let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        items = snapshot.items
        lastScanDate = snapshot.date
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
        cleanedPaths = []
        scanTask = Task {
            await runScan()
            // A cancelled task must not stomp the state of a newer scan.
            guard !Task.isCancelled else { return }
            isScanning = false
            lastScanDate = .now
            scanTask = nil
            saveSnapshot()
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
            if Task.isCancelled { return }
            // Don't resurrect items the user cleaned while the scan was running.
            collected.removeAll { cleanedPaths.contains($0.path) }
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
        let indexByPath = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.path, $0) })

        // items can shrink while we await (cleaning is allowed mid-scan), so a
        // snapshotted index is only a hint — validate it before writing through it.
        func applySize(_ size: Int64?, forPath path: String) {
            if let index = indexByPath[path], index < items.count, items[index].path == path {
                items[index].sizeBytes = size
            } else if let index = items.firstIndex(where: { $0.path == path }) {
                items[index].sizeBytes = size
            }
        }
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
                if Task.isCancelled { group.cancelAll(); break }
                applySize(size, forPath: path)
                addNext(&group)
            }
        }
    }

    public func clean(_ selected: [ScanItem], force: Bool = false) async {
        guard !isCleaning else { return }
        isCleaning = true
        cleaningStatus = "Preparing…"
        var done = 0
        var freed: Int64 = 0
        let total = selected.count
        let results = await cleanupEngine.clean(items: selected, force: force) { [weak self] result in
            done += 1
            freed += result.freedBytes ?? 0
            self?.cleaningStatus = "Cleaning \(done) of \(total) · \(freed.formattedBytes) freed"
            // Keep the list live: successfully removed items disappear as they go.
            if result.success {
                self?.items.removeAll { $0.path == result.path }
                self?.selection.remove(result.path)
                self?.cleanedPaths.insert(result.path)
            }
        }
        cleanupResults = results
        isCleaning = false
        cleaningStatus = ""
        saveSnapshot()
    }
}
