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

## T3 Code

- Base directory is `$T3CODE_HOME`, default `~/.t3`. Worktrees live at `worktrees/<project>/<name>`, state in `userdata/` (`dev/` for development builds) ([source: `deriveServerPaths`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/config.ts)). Some worktrees sit directly at `worktrees/<name>` (local observation).
- Thread state: `userdata/statev2.sqlite` on current builds, `state.sqlite` on older ones. `orchestration_v2_projection_threads.payload_json` carries `worktreePath` and `lastVisitedAt`; `archived_at`/`deleted_at` are columns. The legacy `projection_threads` table has a `worktree_path` column and is kept, stale, inside statev2 after import, so v2 rows win per thread id (local observation of the schema).
- Users rarely archive threads, so "not archived" protects too much. Reclaim demotes a worktree to Review only when an open thread was visited or messaged in the last 14 days; `updated_at` moves on background bookkeeping and is only a fallback.
- `scratch/<name>` holds the working folder of project-less threads; whatever the agent produced lives there, so it is Review-only.
- `state.sqlite` next to a newer `statev2.sqlite`, untouched for a week, is the pre-migration database: Review with a downgrade caution, never Safe.
- `~/Library/Caches/t3code-updater` is electron-updater's staging folder, like every `~/Library/Caches/<app>-updater`.

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
- SwiftUI preview devices live in `~/Library/Developer/Xcode/UserData/Previews`, a separate simctl device set: `xcrun simctl --set previews delete all`.

## Version managers

- fnm: `node-versions/<v>` under `$FNM_DIR` (default `~/.local/share/fnm`); `aliases/default` is a symlink chain ending in the default version ([fnm](https://github.com/Schniz/fnm/blob/master/docs/configuration.md)).
- nvm: `versions/node/<v>` under `$NVM_DIR`; `alias/default` holds a version spec, which can be symbolic (`lts/*`). Unresolvable specs protect the newest install.
- pyenv: `versions/<v>` under `$PYENV_ROOT`; the global `version` file lists active versions ([pyenv](https://github.com/pyenv/pyenv#understanding-python-version-selection)).
- rustup: `toolchains/<name>` under `$RUSTUP_HOME`; `settings.toml` holds `default_toolchain` and per-directory `[overrides]` ([rustup](https://rust-lang.github.io/rustup/overrides.html)).
- Claude Code native installs keep builds at `~/.local/share/claude/versions/<semver>`; `~/.local/bin/claude` links the active one (local observation).
- Whatever the source, the default version is never offered, and a manager with a single install is skipped.

## Other caches

- Cargo: `~/.cargo/registry` and `~/.cargo/git` are download caches, refetched on build ([Cargo book](https://doc.rust-lang.org/cargo/guide/cargo-home.html#caching-the-cargo-home-in-ci)).
- uv: `~/.cache/uv`, `uv cache clean` ([uv docs](https://docs.astral.sh/uv/concepts/cache/)). pre-commit: `~/.cache/pre-commit`, `pre-commit clean`.
- Puppeteer browsers: `~/.cache/puppeteer` ([docs](https://pptr.dev/guides/configuration)). chrome-devtools-mcp keeps a browser profile in `~/.cache/chrome-devtools-mcp`; clearing signs it out, so it is Review.
- Corepack downloads: `~/.cache/node/corepack`. Prisma engines: `~/.cache/prisma`.
- Project build output detected only next to its manifest: `target` (Cargo.toml, pom.xml), `.build` (Package.swift), `.gradle` (Gradle build files), `.venv` (Python dependency files; Review because hand-installed packages are not recreated).
