# Reclaim

Your AI coding agents are eating your disk. Reclaim gives it back.

<!-- screenshot goes here -->

Codex, Claude Code, Conductor and friends create a git worktree for almost every task, each with its own checkout and its own `node_modules`. A few busy weeks later there are 60 GB of abandoned copies of your repos sitting in hidden folders, and no safe way to tell which ones still hold real work. Generic disk cleaners see folders. Reclaim sees git.

## What it does

Reclaim scans your Mac for development storage and tells you, item by item, whether it is safe to remove and why:

- Git worktrees left behind by Codex, Conductor, Claude Code, or created by hand
- `node_modules` folders across your projects
- npm and pnpm caches
- Xcode DerivedData, archives, device support and simulator data
- Caches and session data from Codex, Claude Code, Cursor and Conductor

Every worktree gets a real git inspection: uncommitted changes, untracked files, commits that exist nowhere else, lock status, whether an agent session is still using it. Nothing is ever classified by file age alone.

## Why you can trust it

- Everything goes to the Trash, so any cleanup can be undone
- Worktrees are re-checked at the moment of deletion, not just at scan time. If work appeared since the scan, the item is refused
- Anything dirty, unpushed, locked, active or unclear is refused by the cleanup engine itself, not just hidden in the UI
- The main worktree of a repository can never be removed
- Simulator data is never deleted directly; Reclaim points you to `simctl` instead
- After cleanup, stale registrations are pruned from the parent repo so `git worktree list` stays truthful

If Reclaim is not sure about something, it says so and leaves it alone. For anything questionable you can hand it to your AI tool of choice with one click: Reclaim opens Codex, Claude Code, Conductor or Cursor with a prefilled prompt asking it to inspect the workspace, commit and push what matters, and clean up the rest.

## Install

Build from source for now:

```sh
git clone <repo-url>
cd Reclaim
open Reclaim.xcodeproj
```

Requires macOS 26 and Xcode 26. Homebrew tap planned.

## Under the hood

The app is a thin SwiftUI shell over `ReclaimKit`, a Swift package that does all scanning, classification and cleanup. The engine is fully tested against fixture git repositories, including every refusal path: dirty trees, untracked files, unpushed commits, locked worktrees, races where a clean worktree becomes dirty between scan and delete.

```sh
cd ReclaimKit
swift test              # engine tests
swift run reclaim-scan ~/dev --sizes   # read-only scan from the terminal
```

Storage locations and cleanup rules for every supported tool are documented with sources in [docs/RESEARCH.md](docs/RESEARCH.md). If a tool cannot be supported safely, Reclaim shows it as detected but unsupported instead of guessing.

## License

MIT
