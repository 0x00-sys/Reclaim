import Foundation
import Testing
@testable import ReclaimKit

private func worktreeItem(
    _ state: WorktreeState,
    activeProcess: Bool = false,
    activeSession: Bool = false
) -> ScanItem {
    ScanItem(
        path: "/tmp/wt", displayName: "wt", tool: .codex, category: .worktree,
        worktree: state, hasActiveProcess: activeProcess, hasActiveSession: activeSession
    )
}

@Suite struct ClassifierWorktreeTests {
    let clean = WorktreeState(
        repositoryPath: "/repo", branch: "feature", isRegistered: true,
        hasModifiedFiles: false, hasUntrackedFiles: false, unpushedCommits: 0
    )

    @Test func cleanRegisteredWorktreeIsSafe() {
        let (safety, reasons) = Classifier.classify(worktreeItem(clean))
        #expect(safety == .safe)
        #expect(!reasons.isEmpty)
    }

    @Test func mainWorktreeIsProtected() {
        var state = clean
        state.isMainWorktree = true
        let (safety, _) = Classifier.classify(worktreeItem(state))
        #expect(safety == .protected)
    }

    @Test func activeProcessProtects() {
        let (safety, _) = Classifier.classify(worktreeItem(clean, activeProcess: true))
        #expect(safety == .protected)
    }

    @Test func activeSessionProtects() {
        let (safety, _) = Classifier.classify(worktreeItem(clean, activeSession: true))
        #expect(safety == .protected)
    }

    @Test func lockedWorktreeIsProtected() {
        var state = clean
        state.isLocked = true
        let (safety, _) = Classifier.classify(worktreeItem(state))
        #expect(safety == .protected)
    }

    @Test func modifiedFilesRequireReview() {
        var state = clean
        state.hasModifiedFiles = true
        let (safety, reasons) = Classifier.classify(worktreeItem(state))
        #expect(safety == .review)
        #expect(reasons.contains { $0.contains("Uncommitted") })
    }

    @Test func untrackedFilesRequireReview() {
        var state = clean
        state.hasUntrackedFiles = true
        let (safety, _) = Classifier.classify(worktreeItem(state))
        #expect(safety == .review)
    }

    @Test func unpushedCommitsRequireReview() {
        var state = clean
        state.unpushedCommits = 3
        let (safety, reasons) = Classifier.classify(worktreeItem(state))
        #expect(safety == .review)
        #expect(reasons.contains { $0.contains("3 commits") })
    }

    @Test func unknownPushStateIsNeverSafe() {
        var state = clean
        state.unpushedCommits = nil
        let (safety, _) = Classifier.classify(worktreeItem(state))
        #expect(safety == .unknown)
    }

    @Test func unregisteredCleanWorktreeStillRequiresAttention() {
        var state = clean
        state.isRegistered = false
        let (safety, _) = Classifier.classify(worktreeItem(state))
        #expect(safety != .safe)
    }

    @Test func modificationBeatsAge() {
        // File-age alone must never make something safe.
        var state = clean
        state.hasModifiedFiles = true
        var item = worktreeItem(state)
        item.lastActivity = Date.distantPast
        let (safety, _) = Classifier.classify(item)
        #expect(safety == .review)
    }
}

@Suite struct ClassifierCategoryTests {
    private func item(_ category: StorageCategory, activeProcess: Bool = false) -> ScanItem {
        ScanItem(path: "/tmp/x", displayName: "x", tool: .xcode, category: category, hasActiveProcess: activeProcess)
    }

    @Test func regenerableCategoriesAreSafe() {
        for category in [StorageCategory.nodeModules, .packageCache, .derivedData, .toolCache] {
            let (safety, _) = Classifier.classify(item(category))
            #expect(safety == .safe, "\(category) should be safe")
        }
    }

    @Test func valuableCategoriesRequireReview() {
        for category in [StorageCategory.archives, .deviceSupport, .simulators, .toolSessions] {
            let (safety, _) = Classifier.classify(item(category))
            #expect(safety == .review, "\(category) should require review")
        }
    }

    @Test func activeProcessProtectsAnyCategory() {
        for category in StorageCategory.allCases {
            let (safety, _) = Classifier.classify(item(category, activeProcess: true))
            #expect(safety == .protected)
        }
    }
}
