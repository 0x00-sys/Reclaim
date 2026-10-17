import Foundation

/// Old versions kept by version managers: fnm and nvm Node installs, pyenv
/// Pythons, rustup toolchains, and Claude Code's previous native binaries.
/// The default/active version of each manager is protected; every other
/// version is a reviewable item on its own.
public struct ToolchainScanner: StorageScanner {
    public let name = "Toolchains"

    public init() {}

    struct Manager {
        var title: String
        var tool: Tool
        /// Directory holding one entry per installed version.
        var versionsDirectory: URL
        /// Versions that must never be offered (the default/active one).
        var active: Set<String>
        /// Lower-priority evidence shown as a caution (e.g. pinned by a project).
        var pinned: [String: String] = [:]
        var restoreHint: String
        /// Claude's versions are single files; everything else is a directory.
        var entriesAreFiles = false
    }

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for manager in Self.managers(home: context.home, environment: context.environment) {
            try Task.checkCancellation()
            let entries = FileManager.default.contentsOfDirectoryIfPresent(manager.versionsDirectory)
                .filter { manager.entriesAreFiles || FileManager.default.directoryExists($0) }
            // A single installed version is the one in use, whatever the alias says.
            guard entries.count > 1 else { continue }
            // Unresolvable default (missing alias, broken launcher link): protect
            // the newest install rather than offering every version.
            let names = entries.map(\.lastPathComponent)
            var active = manager.active.intersection(names)
            if active.isEmpty, let newest = names.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                active = [newest]
            }
            for entry in entries {
                let version = entry.lastPathComponent
                let isActive = active.contains(version)
                var item = ScanItem(
                    path: entry.path,
                    displayName: "\(manager.title) \(version)",
                    tool: manager.tool,
                    category: .toolchains,
                    lastActivity: latestModification(in: entry, maxDepth: 0),
                    hasActiveProcess: context.processes.referencesPath(entry.path),
                    cautionNote: manager.pinned[version]
                )
                (item.safety, item.reasons) = Classifier.classify(item)
                if isActive {
                    item.safety = .protected
                    item.reasons = ["This is the default \(manager.title) version."]
                } else if item.safety == .review {
                    item.reasons.append("Not the default version. \(manager.restoreHint)")
                }
                items.append(item)
            }
        }
        return items
    }

    static func managers(home: URL, environment: [String: String]) -> [Manager] {
        var managers: [Manager] = []
        let fm = FileManager.default
        func directory(_ envKey: String, _ fallbacks: [String]) -> URL? {
            if let value = environment[envKey], !value.isEmpty { return URL(filePath: value) }
            return fallbacks.map { home.appendingPathComponent($0) }.first(where: fm.directoryExists)
        }

        // fnm: aliases/<name> are symlink chains ending in node-versions/<v>/installation.
        if let fnm = directory("FNM_DIR", [".local/share/fnm", "Library/Application Support/fnm", ".fnm"]) {
            let versions = fnm.appendingPathComponent("node-versions")
            var active: Set<String> = []
            var pinned: [String: String] = [:]
            for alias in fm.contentsOfDirectoryIfPresent(fnm.appendingPathComponent("aliases")) {
                guard let version = versionName(resolving: alias, under: versions) else { continue }
                if alias.lastPathComponent == "default" {
                    active.insert(version)
                } else {
                    pinned[version] = "The fnm alias “\(alias.lastPathComponent)” points at this version."
                }
            }
            managers.append(Manager(title: "Node.js (fnm)", tool: .node, versionsDirectory: versions,
                                    active: active, pinned: pinned,
                                    restoreHint: "`fnm install` restores it."))
        }

        // nvm: alias/default holds a version spec ("22", "v22.1.0", "lts/*", "node").
        if let nvm = directory("NVM_DIR", [".nvm"]) {
            let versions = nvm.appendingPathComponent("versions/node")
            let installed = fm.contentsOfDirectoryIfPresent(versions).map(\.lastPathComponent)
            var active: Set<String> = []
            if let current = versionName(resolving: nvm.appendingPathComponent("current"), under: versions) {
                active.insert(current)
            }
            let spec = (try? String(contentsOf: nvm.appendingPathComponent("alias/default"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = nvmDefault(spec: spec, installed: installed) {
                active.insert(match)
            }
            managers.append(Manager(title: "Node.js (nvm)", tool: .node, versionsDirectory: versions,
                                    active: active,
                                    restoreHint: "`nvm install` restores it."))
        }

        // pyenv: the global version file lists one version per line ("system" = none).
        if let pyenv = directory("PYENV_ROOT", [".pyenv"]) {
            let global = (try? String(contentsOf: pyenv.appendingPathComponent("version"), encoding: .utf8)) ?? ""
            let active = Set(global.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty })
            managers.append(Manager(title: "Python (pyenv)", tool: .python,
                                    versionsDirectory: pyenv.appendingPathComponent("versions"),
                                    active: active,
                                    restoreHint: "`pyenv install` restores it."))
        }

        // rustup: settings.toml names the default toolchain and per-directory overrides.
        if let rustup = directory("RUSTUP_HOME", [".rustup"]) {
            let toolchains = rustup.appendingPathComponent("toolchains")
            let installed = fm.contentsOfDirectoryIfPresent(toolchains).map(\.lastPathComponent)
            let settings = (try? String(contentsOf: rustup.appendingPathComponent("settings.toml"), encoding: .utf8)) ?? ""
            let parsed = parseRustupSettings(settings)
            let active = Set(installed.filter { name in
                parsed.defaultToolchain.map { rustupToolchain(name, matches: $0) } ?? false
            })
            var pinned: [String: String] = [:]
            for (path, toolchain) in parsed.overrides {
                for name in installed where rustupToolchain(name, matches: toolchain) {
                    pinned[name] = "rustup overrides \(path) to use this toolchain."
                }
            }
            managers.append(Manager(title: "Rust toolchain", tool: .rust, versionsDirectory: toolchains,
                                    active: active, pinned: pinned,
                                    restoreHint: "`rustup toolchain install` restores it."))
        }

        // Claude Code native installs: versions/<semver> binaries, ~/.local/bin/claude links the active one.
        let claudeVersions = home.appendingPathComponent(".local/share/claude/versions")
        if fm.directoryExists(claudeVersions) {
            let launcher = home.appendingPathComponent(".local/bin/claude")
            let active = Set([URL(filePath: canonicalPath(launcher.path)).lastPathComponent])
            managers.append(Manager(title: "Claude Code", tool: .claudeCode, versionsDirectory: claudeVersions,
                                    active: active,
                                    restoreHint: "The updater keeps previous builds for rollback; the active build is untouched.",
                                    entriesAreFiles: true))
        }
        return managers
    }

    /// Follows a symlink chain and returns the version directory name directly
    /// under `versions` that it lands in, if any.
    static func versionName(resolving link: URL, under versions: URL) -> String? {
        guard FileManager.default.fileExists(atPath: link.path) else { return nil }
        let resolved = canonicalPath(link.path)
        let base = canonicalPath(versions.path) + "/"
        guard resolved.hasPrefix(base) else { return nil }
        return resolved.dropFirst(base.count).split(separator: "/").first.map(String.init)
    }

    /// Best-effort nvm alias resolution: exact ("v22.1.0"), numeric prefix ("22",
    /// "22.1") → newest match. Symbolic aliases ("lts/*", "node", "stable") can't
    /// be resolved offline, so the newest install is protected instead.
    static func nvmDefault(spec: String?, installed: [String]) -> String? {
        let sorted = installed.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard let spec, !spec.isEmpty else { return nil }
        let normalized = spec.hasPrefix("v") ? spec : "v" + spec
        if installed.contains(normalized) { return normalized }
        if spec.first?.isNumber == true || spec.hasPrefix("v") {
            return sorted.first { $0.hasPrefix(normalized + ".") }
        }
        return sorted.first
    }

    static func parseRustupSettings(_ text: String) -> (defaultToolchain: String?, overrides: [(String, String)]) {
        var defaultToolchain: String?
        var overrides: [(String, String)] = []
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard parts.count == 2 else { continue }
            if section.isEmpty && parts[0] == "default_toolchain" {
                defaultToolchain = parts[1]
            } else if section == "[overrides]" {
                overrides.append((parts[0], parts[1]))
            }
        }
        return (defaultToolchain, overrides)
    }

    /// "stable" matches "stable-aarch64-apple-darwin"; full names match exactly.
    static func rustupToolchain(_ installed: String, matches spec: String) -> Bool {
        installed == spec || installed.hasPrefix(spec + "-")
    }
}
