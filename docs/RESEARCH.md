# Tool storage research

Verified 2026-07-14 through official documentation and local inspection. "UNVERIFIED" marks
claims resting only on community sources or local observation of one machine.

## Codex (OpenAI)

- Base directory `~/.codex`, overridable via `CODEX_HOME` ([config reference](https://learn.chatgpt.com/docs/config-file/config-reference)).
- Managed worktrees at `$CODEX_HOME/worktrees` ([docs](https://learn.chatgpt.com/docs/environments/git-worktrees)); the app keeps the 15 most recent by default. Observed layout: `worktrees/<4-hex-or-uuid>/<repo-name>` — real linked git worktrees (`.git` file → `gitdir: <repo>/.git/worktrees/<name>`), mostly detached HEAD, frequently dirty.
- Worktree ↔ session mapping: `state_5.sqlite`, table `threads`, column `cwd` (UNVERIFIED — local schema observation). Also `archived`, `updated_at`, `rollout_path`.
- Session transcripts in `sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` and `archived_sessions/`. **No retention setting exists for these** — manual cleanup is the only option.
- Disposable: `logs_2.sqlite` (telemetry, 1.8 GB observed), `sqlite/` (stale DB snapshots), `cache/`, `shell_snapshots/`, `tmp/`.
- Protect: `auth.json`, `config.toml` (includes per-project trust list), `memories_1.sqlite`, `state_5.sqlite`, `sessions/`.
- Deep link: `codex://new?prompt=<text>&path=<abs>` prefills the composer, does not auto-send ([docs](https://learn.chatgpt.com/docs/reference/commands)).

## Claude Code

- `~/.claude` layout documented at [claude-directory](https://code.claude.com/docs/en/claude-directory): `projects/<encoded-path>/<session>.jsonl` transcripts, `projects/*/memory/`, `file-history/` (checkpoints), `shell-snapshots/`, `paste-cache/`, `image-cache/`, `session-env/`, `tasks/`, `backups/`.
- Retention: `cleanupPeriodDays` (default 30, min 1) auto-deletes old sessions at startup; `claude project purge` (v2.1.124+) removes a project's data on demand.
- No lock files; activity inferred from a running `claude` process plus recent `session-env`/`tasks` mtimes.
- Deep link: `claude-cli://open?q=<prompt>&cwd=<abs>` (max 5000 chars, prefilled not sent) ([docs](https://code.claude.com/docs/en/deep-links)).

## Conductor

- Workspaces at `~/conductor/workspaces/<repo>/<workspace>`; each is a real git worktree ([docs](https://www.conductor.build/docs/concepts/git-worktrees)). Branch-named symlinks alongside workspace dirs alias live workspaces (UNVERIFIED — local observation).
- `~/conductor/archived-contexts/` holds notes/todos/plans only — no code. `~/.conductor/` holds settings and per-workspace run scripts.
- Archiving deletes the workspace directory (weakly verified); archived workspaces restorable including chat.
- Deep link: `conductor://prompt=<encoded>&path=<repo>` — flat key=value form, no host ([docs](https://www.conductor.build/docs/reference/deep-links)).

## Cursor

- Official guidance for disk space is limited to removing extensions and "Clear Editor History".
- Electron caches in `~/Library/Application Support/Cursor` (`Cache`, `CachedData`, `Code Cache`, `GPUCache`, …) are UNVERIFIED (standard Electron layout, community-confirmed). `User/globalStorage/state.vscdb` holds chat history — never delete.
- Deep link: `cursor://anysphere.cursor-deeplink/prompt?text=<prompt>` ([docs](https://cursor.com/docs/reference/deeplinks)).

## git worktree

- `git worktree remove` refuses unclean trees without `--force`; locked trees need `--force` twice; the main worktree can never be removed ([docs](https://git-scm.com/docs/git-worktree)).
- Deleting a worktree directory leaves a prunable admin entry; `git worktree prune` clears it.
- Unpushed detection: `git rev-list --count HEAD --not --remotes` counts commits on no remote ref and works on detached HEADs; `@{upstream}`-based counting errors out when no upstream is set.
- git prints canonical (symlink-resolved) paths; compare with `realpath`.

## npm / pnpm

- npm cache at `~/.npm/_cacache`; `npm cache verify` garbage-collects; clean needs `--force` ([docs](https://docs.npmjs.com/cli/v11/commands/npm-cache)).
- pnpm store at `~/Library/pnpm/store` (authoritative: `pnpm store path`); node_modules are hard links into it, so deleting a project's node_modules never harms others; `pnpm store prune` drops unreferenced packages ([docs](https://pnpm.io/cli/store)).

## Xcode

- DerivedData folders are `<Name>-<hash>` with an `info.plist` containing `WorkspacePath` and `LastAccessedDate` — safe to delete, rebuilt on demand. Shared `*.noindex` caches likewise.
- Archives contain the only copy of each build's dSYMs — Apple says retain them ([docs](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information)). Review-only.
- DeviceSupport re-downloads on next device connection (UNVERIFIED, community).
- Simulator devices: never `rm`; use `xcrun simctl delete unavailable`, `simctl runtime delete --notUsedSinceDays N`, or Xcode ▸ Settings ▸ Components ([Apple forums, DTS](https://developer.apple.com/forums/thread/758703)).
