# Phase 1 — Skeleton + Installer

**Goal:** A user can `git clone` this repo, run one command, and end up with a working `~/.claude/` setup that loads cleanly in any new Claude Code session. No agents are functional yet — this phase only proves the install pipeline works end-to-end on macOS and Windows.

## Deliverables

1. Repository directory layout (`claude-system/` mirroring `~/.claude/`).
2. `install.sh` (macOS/Linux) — Bash, no extra dependencies.
3. `install.ps1` (Windows) — PowerShell 5.1+ compatible.
4. `uninstall.sh` / `uninstall.ps1` — restores backups.
5. `settings.fragment.json` — hook + permission entries to merge into the user's `~/.claude/settings.json`.
6. SessionStart hook stub that prints a confirmation banner.
7. `README.md` with install/uninstall instructions.

## Files to create

```
omsbudsman/
├── README.md
├── install.sh
├── install.ps1
├── uninstall.sh
├── uninstall.ps1
└── claude-system/
    ├── agents/                       # empty stub files (one per agent name)
    │   ├── orchestrator.md
    │   ├── librarian.md
    │   ├── retrospective.md
    │   ├── researcher.md
    │   ├── planner.md
    │   ├── frontend-engineer.md
    │   ├── backend-engineer.md
    │   ├── test-engineer.md
    │   ├── qa-reviewer.md
    │   └── auditor.md
    ├── hooks/
    │   ├── session-start.sh
    │   ├── session-start.ps1
    │   ├── user-prompt-submit.sh
    │   ├── user-prompt-submit.ps1
    │   ├── subagent-stop.sh
    │   ├── subagent-stop.ps1
    │   ├── stop.sh
    │   └── stop.ps1
    ├── memory/
    │   └── INDEX.md                  # seed: empty index
    └── settings.fragment.json
```

## Installer behavior

### `install.sh` / `install.ps1`
1. Detect prior `~/.claude/` install. If present, back up to `~/.claude.backup-<ISO8601>/` (atomic rename).
2. Copy `claude-system/agents/*` → `~/.claude/agents/`. Files with the same name are overwritten (the user is replacing the team).
3. Copy `claude-system/hooks/*` → `~/.claude/hooks/`. Set executable bit on `.sh` files.
4. Copy `claude-system/memory/INDEX.md` → `~/.claude/memory/INDEX.md` only if it doesn't already exist (don't clobber learned memory).
5. Merge `claude-system/settings.fragment.json` into `~/.claude/settings.json`:
   - If `settings.json` doesn't exist → copy fragment as-is.
   - If it exists → JSON-merge: preserve existing keys, add ours, **append** to `hooks` arrays (don't overwrite). Use `jq` on Unix, `ConvertFrom-Json`/`ConvertTo-Json` on PowerShell.
6. Print summary: what was added, what was backed up, where to look.
7. Exit 0 on success, non-zero with clear error on failure.

### `uninstall.sh` / `uninstall.ps1`
1. Look for the most recent `~/.claude.backup-*` directory.
2. Back up the current `~/.claude/` to `~/.claude.preuninstall-<ISO8601>/`.
3. Remove our agent files (by name match against `claude-system/agents/`).
4. Remove our hook files (by name match).
5. Remove our entries from `settings.json` (best-effort: matching hook commands).
6. **Memory is preserved** — never deleted by uninstall.
7. Print what was removed and where backups live.

## SessionStart hook stub

`claude-system/hooks/session-start.sh`:
```bash
#!/usr/bin/env bash
# Phase 1 stub — replaced in phase 2 with librarian invocation.
echo "[claude-multi-agent] system loaded — phase 1 stub" >&2
```

`claude-system/hooks/session-start.ps1`:
```powershell
# Phase 1 stub
Write-Host "[claude-multi-agent] system loaded — phase 1 stub"
```

Both hooks must exit 0 quickly so they never block session startup.

## settings.fragment.json (initial)

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/session-start.sh" }
        ]
      }
    ]
  }
}
```

Note: Windows path resolution handled by the installer at merge time — the merger writes `%USERPROFILE%\.claude\hooks\session-start.ps1` on Windows.

## Acceptance criteria

- [ ] `./install.sh` on a clean macOS account creates `~/.claude/` with all expected files.
- [ ] `.\install.ps1` on a clean Windows account does the same.
- [ ] If `~/.claude/settings.json` already exists with unrelated keys, those keys survive.
- [ ] If `~/.claude/settings.json` already has a `SessionStart` hook, ours is appended, not replacing.
- [ ] Starting `claude` in any directory prints the `[claude-multi-agent] system loaded` banner.
- [ ] `./uninstall.sh` restores the previous state (backup directory available for diff).
- [ ] Re-running the installer is idempotent (creates a new backup, doesn't error).
- [ ] All agent stub files are valid Markdown (load without parse errors in Claude Code).

## Dependencies / order

- No dependencies on other phases.
- **Blocks:** all subsequent phases. They all assume install pipeline works.

## Risks / open notes

- Windows path separators in the JSON fragment: handle at merge time, not by hand-writing a Windows-specific fragment.
- `jq` is not always available on bare macOS; fall back to a small Python or Node JSON merger if absent. Prefer detecting and using whatever's installed.
- Permission errors on Windows when `~/.claude/` doesn't exist: handle with explicit `New-Item -ItemType Directory -Force`.
- A user's existing `settings.json` may be invalid JSON. Don't silently corrupt it — back up first, then warn.
