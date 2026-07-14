import Foundation

/// Snapshot of running processes relevant to classification.
public struct ProcessSnapshot: Sendable {
    /// Full command lines of running processes.
    public var commandLines: [String]
    /// Current working directories of running processes: a dev server or agent
    /// sitting inside a directory rarely has that path in its command line.
    public var workingDirectories: Set<String>

    public init(commandLines: [String], workingDirectories: Set<String> = []) {
        self.commandLines = commandLines
        self.workingDirectories = workingDirectories
    }

    /// True when any running process references the path on its command line
    /// or is currently working inside it.
    public func referencesPath(_ path: String) -> Bool {
        if commandLines.contains(where: { $0.contains(path) }) { return true }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return workingDirectories.contains { $0 == path || $0.hasPrefix(prefix) }
    }

    public func hasProcess(named name: String) -> Bool {
        commandLines.contains { line in
            line.split(separator: " ").first.map { segment in
                segment.hasSuffix("/\(name)") || segment == Substring(name)
            } ?? false
        }
    }

    public static func capture() async -> ProcessSnapshot {
        async let psResult = try? runSubprocess("/bin/ps", ["-axo", "command"])
        async let cwdResult = try? runSubprocess("/usr/sbin/lsof", ["-w", "-d", "cwd", "-F", "n"], timeout: 15)

        let commandLines = (await psResult)?.stdout.components(separatedBy: "\n") ?? []
        let workingDirectories = Set(
            ((await cwdResult)?.stdout.split(separator: "\n") ?? [])
                .filter { $0.hasPrefix("n") }
                .map { String($0.dropFirst()) }
        )
        return ProcessSnapshot(commandLines: commandLines, workingDirectories: workingDirectories)
    }
}
