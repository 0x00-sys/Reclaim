# Reclaim

Find your lost gigabytes. Reclaim is a macOS app that safely cleans the disk space eaten by git worktrees, build caches, and AI coding agents.

[![Download](https://img.shields.io/github/v/release/0x00-sys/Reclaim?label=Download&color=4DE68A)](https://github.com/0x00-sys/Reclaim/releases/latest)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ReclaimKit)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-40%20passing-4DE68A)](ReclaimKit/Tests)

[![Reclaim banner](docs/banner.png)](docs/banner.png)

## Install

Download the latest `Reclaim-x.y.z.dmg` from [Releases](https://github.com/0x00-sys/Reclaim/releases/latest), open it, and drag Reclaim into Applications.

Reclaim isn't signed with an Apple developer certificate yet, so the first launch needs one extra step. macOS will tell you it can't verify the app. Close that dialog, open System Settings, go to Privacy & Security, scroll down, and click **Open Anyway**. That's a one-time thing; after that it opens like any other app.

A Homebrew tap is planned. If you'd rather build from source:

```sh
git clone https://github.com/0x00-sys/Reclaim.git
cd Reclaim
open Reclaim.xcodeproj
```

***

## Why Reclaim

- AI agents create a git worktree per task. A busy month leaves tens of gigabytes of abandoned repo copies in hidden folders.
- Every worktree gets a real git inspection: uncommitted changes, untracked files, commits that exist nowhere else, lock state, live sessions.
- Nothing is classified by file age alone, and nothing is deleted without your confirmation.
- Deletion is Trash-first and re-verified at the moment of removal. If work appeared since the scan, the item is refused.
- One-click clean of everything Safe, driven by your filters: category, tool, status, idle time.
- Artifact-only cleaning: a worktree with unpushed work keeps its code while the node_modules or target folder inside it gets reclaimed. Only directories with zero git-tracked files qualify.
- Transcript folders for projects you deleted are detected as orphans and become safe to clean; sessions for living projects stay protected.
- Pushed your commits since the scan? Re-check flips the worktree to Safe without rescanning, and it happens automatically when you come back to the app.
- A notch panel shows live scan and cleanup progress, with pixel-art sprites per tool.
- 8-bit chime when it's done. Optional everything.

**Scans:** Codex · Claude Code · Conductor · Cursor · git worktrees · node_modules · `.next`/`.nuxt`/`.turbo`/cargo target · npm · pnpm · Bun · Go · Playwright · Homebrew · pip · Gradle · CocoaPods · Xcode · Ollama · Hugging Face · LM Studio · leftover installers in Downloads

***

## Safety model

Every item gets a verdict with reasons: **Safe to clean**, **Review first**, **Active or protected**, or **Unknown**. The cleanup engine independently refuses anything dirty, unpushed, locked, in use by a running process, or holding open files, even if asked. The main worktree of a repository can never be removed. Force-cleaning refused items exists, but only behind a double confirmation, and it still can't touch the hard refusals.

Details and per-tool storage research with sources: [docs/RESEARCH.md](docs/RESEARCH.md)

***

## FAQ

**Where do deleted files go?**
The macOS Trash, always. Registered worktrees are additionally pruned from their repository so `git worktree list` stays truthful.

**Why isn't the app sandboxed?**
It scans development directories across your home folder, which the sandbox forbids. It is read-only except for the explicit, confirmed cleanup flow, and every git call uses argument arrays, never shell strings.

**Can I check what it would find without the app?**
Yes: `cd ReclaimKit && swift run reclaim-scan ~/dev --sizes` prints a read-only report.

**A tool I use isn't supported.**
Open an issue with where it stores data. If it can't be supported safely, Reclaim shows it as detected but unsupported rather than guessing.

***

## Under the hood

A thin SwiftUI app over `ReclaimKit`, a Swift package that owns scanning, classification, and cleanup. The engine is tested against fixture git repositories, including every refusal path and the race where a clean worktree becomes dirty between scan and delete.

```sh
cd ReclaimKit && swift test
```

## License

MIT
