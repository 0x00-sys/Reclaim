import Foundation
import Testing
@testable import ReclaimKit

private func makeTree(_ files: [String], dirs: [String]) throws -> URL {
    let root = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("coverage-\(UUID().uuidString)")
    for dir in dirs + [""] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in files {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent(file))
    }
    return root
}

@Suite struct ToolchainScannerTests {
    @Test func fnmDefaultAliasChainIsProtected() async throws {
        let home = try makeTree([], dirs: [
            ".local/share/fnm/node-versions/v20.1.0/installation",
            ".local/share/fnm/node-versions/v22.3.0/installation",
            ".local/share/fnm/node-versions/v24.0.0/installation",
            ".local/share/fnm/aliases",
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let fnm = home.appendingPathComponent(".local/share/fnm")
        let fm = FileManager.default
        // default -> lts-latest -> node-versions/v22.3.0/installation
        try fm.createSymbolicLink(at: fnm.appendingPathComponent("aliases/lts-latest"),
                                  withDestinationURL: fnm.appendingPathComponent("node-versions/v22.3.0/installation"))
        try fm.createSymbolicLink(at: fnm.appendingPathComponent("aliases/default"),
                                  withDestinationURL: fnm.appendingPathComponent("aliases/lts-latest"))
        try fm.createSymbolicLink(at: fnm.appendingPathComponent("aliases/legacy"),
                                  withDestinationURL: fnm.appendingPathComponent("node-versions/v20.1.0/installation"))

        let items = try await ToolchainScanner().scan(context: ScanContext(home: home, environment: [:]))
        let byVersion = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0) })
        #expect(byVersion["v22.3.0"]?.safety == .protected)
        #expect(byVersion["v24.0.0"]?.safety == .review)
        #expect(byVersion["v20.1.0"]?.reasons.contains { $0.contains("“legacy”") } == true)
        #expect(items.allSatisfy { $0.category == .toolchains && $0.tool == .node })
    }

    @Test func unresolvableDefaultProtectsNewestAndSingleVersionIsSkipped() async throws {
        let home = try makeTree([], dirs: [".pyenv/versions/3.9.1", ".pyenv/versions/3.12.4"])
        defer { try? FileManager.default.removeItem(at: home) }
        var items = try await ToolchainScanner().scan(context: ScanContext(home: home, environment: [:]))
        #expect(items.first { $0.safety == .protected }?.url.lastPathComponent == "3.12.4")  // numeric, not lexical

        try FileManager.default.removeItem(at: home.appendingPathComponent(".pyenv/versions/3.9.1"))
        items = try await ToolchainScanner().scan(context: ScanContext(home: home, environment: [:]))
        #expect(items.isEmpty)
    }

    @Test func claudeActiveBuildFollowsLauncherSymlink() async throws {
        let home = try makeTree([".local/share/claude/versions/1.0.9", ".local/share/claude/versions/1.0.10"], dirs: [".local/bin"])
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".local/bin/claude"),
            withDestinationURL: home.appendingPathComponent(".local/share/claude/versions/1.0.9"))
        let items = try await ToolchainScanner().scan(context: ScanContext(home: home, environment: [:]))
        #expect(items.first { $0.safety == .protected }?.url.lastPathComponent == "1.0.9")
        #expect(items.first { $0.url.lastPathComponent == "1.0.10" }?.safety == .review)
    }

    @Test func nvmAliasResolution() {
        let installed = ["v18.20.0", "v20.9.0", "v20.11.1", "v22.0.0"]
        #expect(ToolchainScanner.nvmDefault(spec: "20", installed: installed) == "v20.11.1")
        #expect(ToolchainScanner.nvmDefault(spec: "v20.9.0", installed: installed) == "v20.9.0")
        #expect(ToolchainScanner.nvmDefault(spec: "18.20", installed: installed) == "v18.20.0")
        #expect(ToolchainScanner.nvmDefault(spec: "lts/*", installed: installed) == "v22.0.0")
        #expect(ToolchainScanner.nvmDefault(spec: nil, installed: installed) == nil)
    }

    @Test func rustupSettingsDefaultAndOverrides() {
        let parsed = ToolchainScanner.parseRustupSettings("""
            version = "12"
            default_toolchain = "stable"

            [overrides]
            "/work/legacy" = "1.70.0-aarch64-apple-darwin"
            """)
        #expect(parsed.defaultToolchain == "stable")
        #expect(parsed.overrides.first?.0 == "/work/legacy")
        #expect(ToolchainScanner.rustupToolchain("stable-aarch64-apple-darwin", matches: "stable"))
        #expect(!ToolchainScanner.rustupToolchain("stable2-x", matches: "stable"))
    }
}

@Suite struct BuildDirectoryCoverageTests {
    @Test func markedDirectoriesNeedTheirManifest() throws {
        let root = try makeTree(["swift/Package.swift", "py/pyproject.toml", "java/pom.xml"],
                                dirs: ["swift/.build", "py/.venv", "java/target", "plain/target", "plain/.build"])
        defer { try? FileManager.default.removeItem(at: root) }
        func match(_ name: String, in dir: String) -> NodeModulesScanner.MarkedDirectory? {
            NodeModulesScanner.markedBuildDirectory(named: name, in: root.appendingPathComponent(dir))
        }
        #expect(match(".build", in: "swift")?.title == "SwiftPM build")
        #expect(match("target", in: "java")?.tool == .maven)
        #expect(match(".venv", in: "py")?.caution != nil)
        #expect(match("target", in: "plain") == nil)
        #expect(match(".build", in: "plain") == nil)
    }

    @Test func scannerReportsSwiftPMAndDemotesVirtualenv() async throws {
        let root = try makeTree(["app/Package.swift", "api/requirements.txt"],
                                dirs: ["app/.build/debug", "api/.venv/lib", "web/.vite"])
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try await NodeModulesScanner().scan(context: ScanContext(projectRoots: [root]))
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.displayName, $0) })
        #expect(byTitle["app: SwiftPM build"]?.safety == .safe)
        #expect(byTitle["api: Python virtualenv"]?.safety == .review)
        #expect(byTitle["web: Vite dependency cache"]?.category == .buildCache)
    }

    @Test func artifactLocatorKnowsMoreEcosystems() throws {
        let swift = try makeTree(["Package.swift"], dirs: [".build/debug", "Sources"])
        let elixir = try makeTree(["mix.exs"], dirs: ["_build", "deps", "lib"])
        defer {
            try? FileManager.default.removeItem(at: swift)
            try? FileManager.default.removeItem(at: elixir)
        }
        #expect(BuildArtifactLocator.locate(in: swift).map(\.lastPathComponent) == [".build"])
        #expect(BuildArtifactLocator.locate(in: elixir).map(\.lastPathComponent) == ["_build", "deps"])
    }
}

@Suite struct DevCacheCoverageTests {
    @Test func updaterCachesAreFoundWhenNonEmpty() throws {
        let home = try makeTree(["Library/Caches/some-editor-updater/pending/Setup.zip"],
                                dirs: ["Library/Caches/idle-app-updater", "Library/Caches/unrelated"])
        defer { try? FileManager.default.removeItem(at: home) }
        let items = DevCacheScanner().updaterCaches(context: ScanContext(home: home))
        #expect(items.map(\.displayName) == ["some-editor update downloads"])
        #expect(items.first?.tool == .appUpdater)
        #expect(items.first?.safety == .safe)
    }

    @Test func toolchainsClassifyAsReview() {
        let item = ScanItem(path: "/x", displayName: "x", tool: .node, category: .toolchains)
        #expect(Classifier.classify(item).0 == .review)
    }
}
