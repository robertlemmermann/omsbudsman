# Claude Code Multi-Agent System

A globally-installable, persistent, self-improving multi-agent system for Claude Code. Lives in `~/.claude/`, works across any session, on any project, on macOS and Windows.

**Status:** phase 2 — installer + librarian/memory. Other agents are stubs; functional behavior is implemented in subsequent phases. See `plans/00-master-plan.md` for the full architecture and `plans/0N-*.md` for each phase.

## Install

### macOS / Linux

```bash
git clone https://github.com/robertlemmermann/omsbudsman.git
cd omsbudsman
./install.sh
```

Requires `bash` and `python3` (both standard on macOS and any modern Linux).

### Windows

```powershell
git clone https://github.com/robertlemmermann/omsbudsman.git
cd omsbudsman
.\install.ps1
```

Requires PowerShell 5.1 or later. If script execution is blocked, run once with:
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

### What the installer does

1. Backs up any existing `~/.claude/` to `~/.claude.backup-<UTC-timestamp>/`.
2. Copies agent definitions to `~/.claude/agents/`.
3. Copies hook scripts to `~/.claude/hooks/` (executable bit set on Unix).
4. Seeds `~/.claude/memory/INDEX.md` only if not present (existing memory is never overwritten).
5. Merges hook registrations into `~/.claude/settings.json`, preserving every existing key and **appending** to hook arrays (no clobbering).

Re-running the installer is safe — it creates a fresh backup each time.

### Verify

Start a new Claude Code session in any directory. You should see this on stderr:

```
[claude-multi-agent] memory tiers ready: <global>/memory + <project>/.claude/memory
```

The session-start hook also creates `<project>/.claude/memory/` on first run if you're inside a git repo (or any directory).

## Uninstall

### macOS / Linux

```bash
./uninstall.sh
```

### Windows

```powershell
.\uninstall.ps1
```

Uninstall:
- Backs up the current `~/.claude/` to `~/.claude.preuninstall-<UTC-timestamp>/`.
- Removes only our agent files (matched by name against `claude-system/agents/`).
- Removes only our hook files (matched by name against `claude-system/hooks/`).
- Removes only our entries from `settings.json` (matched by command path).
- **Preserves all memory** under `~/.claude/memory/`.

## Layout (after install)

```
~/.claude/
├── agents/                # 10 agent definition files
├── hooks/                 # 8 hook scripts (4 events × 2 OS variants)
├── memory/                # global tier — cross-project learning
│   └── INDEX.md           # rest is created lazily by the librarian
└── settings.json          # registers our hooks (merged with your existing config)
```

Project-tier memory is created on the first session inside any project, at:

```
<your-project>/.claude/memory/
├── INDEX.md
├── project.md             # (created by librarian on first append)
├── decisions.md           # (created by librarian on first append)
└── mistakes/
    └── INDEX.md
```

### Should I commit `<repo>/.claude/memory/`?

Your call. Commit it to share learning across the team; gitignore it for personal-only notes. To exclude:

```gitignore
# .gitignore
.claude/memory/
```

## Repo layout

```
omsbudsman/
├── plans/                 # master plan + per-phase sub-plans
├── claude-system/         # mirrors ~/.claude/ contents
│   ├── agents/
│   ├── hooks/
│   ├── memory/
│   └── settings.fragment.json
├── install.sh
├── install.ps1
├── uninstall.sh
└── uninstall.ps1
```

## Roadmap

| Phase | Status | Sub-plan |
|---|---|---|
| 1. Skeleton + installer | ✅ implemented | `plans/01-skeleton-and-installer.md` |
| 2. Librarian + memory | ✅ implemented | `plans/02-librarian-and-memory.md` |
| 3. Orchestrator + researcher + planner | planned | `plans/03-orchestrator-research-planner.md` |
| 4. Engineers + QA + auditor | planned | `plans/04-engineers-qa-auditor.md` |
| 5. Retrospective + mistake learning | planned | `plans/05-retrospective-mistake-learning.md` |
| 6. Cost telemetry + tuning | planned | `plans/06-cost-telemetry-tuning.md` |
