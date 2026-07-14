import Foundation

public enum Tool: String, Sendable, Codable, CaseIterable, Identifiable {
    case git = "Git"
    case npm = "npm"
    case pnpm = "pnpm"
    case xcode = "Xcode"
    case codex = "Codex"
    case claudeCode = "Claude Code"
    case conductor = "Conductor"
    case cursor = "Cursor"

    public var id: String { rawValue }
}

public enum StorageCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case worktree = "Git Worktrees"
    case nodeModules = "node_modules"
    case packageCache = "Package Caches"
    case derivedData = "Derived Data"
    case archives = "Xcode Archives"
    case deviceSupport = "Device Support"
    case simulators = "Simulators"
    case toolSessions = "Agent Sessions"
    case toolCache = "Tool Caches"

    public var id: String { rawValue }
}

public enum Safety: String, Sendable, Codable, CaseIterable, Identifiable, Comparable {
    case safe = "Safe to clean"
    case review = "Review first"
    case protected = "Active or protected"
    case unknown = "Unknown"

    public var id: String { rawValue }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .unknown: 2
        case .protected: 3
        }
    }

    public static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rank < rhs.rank }
}

/// Git state observed for a worktree at scan time.
public struct WorktreeState: Sendable, Codable, Equatable {
    public var repositoryPath: String?
    public var branch: String?
    public var isRegistered: Bool
    public var isMainWorktree: Bool
    public var isLocked: Bool
    /// Registration exists but the working tree directory is gone (git marks it prunable).
    public var isPrunable: Bool
    public var hasModifiedFiles: Bool
    public var hasUntrackedFiles: Bool
    /// Commits on the checked-out branch that exist on no remote ref. nil = could not determine.
    public var unpushedCommits: Int?
    public var lastCommitDate: Date?

    public init(
        repositoryPath: String? = nil,
        branch: String? = nil,
        isRegistered: Bool = false,
        isMainWorktree: Bool = false,
        isLocked: Bool = false,
        isPrunable: Bool = false,
        hasModifiedFiles: Bool = false,
        hasUntrackedFiles: Bool = false,
        unpushedCommits: Int? = nil,
        lastCommitDate: Date? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.isRegistered = isRegistered
        self.isMainWorktree = isMainWorktree
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.hasModifiedFiles = hasModifiedFiles
        self.hasUntrackedFiles = hasUntrackedFiles
        self.unpushedCommits = unpushedCommits
        self.lastCommitDate = lastCommitDate
    }
}

public struct ScanItem: Sendable, Codable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var tool: Tool
    public var category: StorageCategory
    public var sizeBytes: Int64?
    /// Most recent meaningful activity we could establish (commit, session write, file change).
    public var lastActivity: Date?
    public var worktree: WorktreeState?
    public var hasActiveProcess: Bool
    public var hasActiveSession: Bool
    public var safety: Safety
    public var reasons: [String]

    public init(
        path: String,
        displayName: String,
        tool: Tool,
        category: StorageCategory,
        sizeBytes: Int64? = nil,
        lastActivity: Date? = nil,
        worktree: WorktreeState? = nil,
        hasActiveProcess: Bool = false,
        hasActiveSession: Bool = false,
        safety: Safety = .unknown,
        reasons: [String] = []
    ) {
        self.path = path
        self.displayName = displayName
        self.tool = tool
        self.category = category
        self.sizeBytes = sizeBytes
        self.lastActivity = lastActivity
        self.worktree = worktree
        self.hasActiveProcess = hasActiveProcess
        self.hasActiveSession = hasActiveSession
        self.safety = safety
        self.reasons = reasons
    }

    public var url: URL { URL(filePath: path) }
}
