import Foundation

/// Snapshot of running processes relevant to classification.
public struct ProcessSnapshot: Sendable {
    /// Full command lines of running processes.
    public var commandLines: [String]

    public init(commandLines: [String]) {
        self.commandLines = commandLines
    }

    /// True when any running process command line references the given path.
    public func referencesPath(_ path: String) -> Bool {
        commandLines.contains { $0.contains(path) }
    }

    public func hasProcess(named name: String) -> Bool {
        commandLines.contains { line in
            line.split(separator: " ").first.map { segment in
                segment.hasSuffix("/\(name)") || segment == Substring(name)
            } ?? false
        }
    }

    public static func capture() async -> ProcessSnapshot {
        guard let result = try? await runSubprocess("/bin/ps", ["-axo", "command"]), result.succeeded else {
            return ProcessSnapshot(commandLines: [])
        }
        return ProcessSnapshot(commandLines: result.stdout.components(separatedBy: "\n"))
    }
}
