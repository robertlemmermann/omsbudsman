# Claude Code Multi-Agent System

A globally-installable, persistent, self-improving multi-agent system for Claude Code. Lives in `~/.claude/`, works across any session, on any project, on macOS and Windows.

**Status:** phase 7 — complete. Full agent loop, two-tier memory, retrospective self-improvement, per-invocation telemetry with a baseline-reporting CLI, and a user-facing activity digest at the end of every worked turn. See `plans/00-master-plan.md` for the full architecture and `plans/0N-*.md` for each phase.

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
├── scripts/               # metrics.{sh,ps1} reporting CLI
├── memory/                # global tier — cross-project learning
│   └── INDEX.md           # rest is created lazily by the librarian
├── state/                 # per-session gate state (one JSON per session)
├── metrics/               # sessions.jsonl (append-only telemetry) + BASELINE.md
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

## What you see after a worked turn

The pipeline itself stays silent — no "dispatching the backend engineer…" narration. Instead, any turn that changed code ends with a compact digest of what actually happened:

```
---
**What happened**
- Changed: 3 files — api/orders.py (duplicate-submit guard); ui/Checkout.tsx (disable on submit); …
- Tests: pytest tests/orders → 14 passed
- Review: QA 3/3 steps pass, after 1 retry; audit: approve
- Learned: this repo requires idempotency keys on all POST endpoints
```

Rules of the digest:

- Capped at 7 lines; file lists collapse into counts when long.
- Every line is traceable to an agent's structured return — nothing is invented.
- Retries and QA failures that were fixed are shown, not hidden.
- `Open:` (follow-ups, advisories) and `Learned:` (memory items recorded this session) appear only when non-empty.
- Pure questions and conversational turns get no digest; plan requests end with an `Open questions:` line only when research surfaced gaps.

See `plans/07-activity-digest.md` for the full design.

## Telemetry

Every subagent return appends one JSONL record to `~/.claude/metrics/sessions.jsonl`; every Stop appends a per-session summary. The active file rotates to `sessions.<UTC>.jsonl.gz` once it exceeds 10 MB; the last 4 archives are retained.

Reports:

```bash
~/.claude/scripts/metrics.sh                    # last 7 days summary
~/.claude/scripts/metrics.sh --agent researcher # per-agent breakdown
~/.claude/scripts/metrics.sh --session <id>     # one session's flow
~/.claude/scripts/metrics.sh --baseline         # writes/updates metrics/BASELINE.md
~/.claude/scripts/metrics.sh --json             # raw summary JSON
~/.claude/scripts/metrics.sh --days 30          # widen the window
```

PowerShell users have the matching `metrics.ps1` with `-Agent`, `-Session`, `-Baseline`, `-Json`, `-Days` switches.

Pricing constants are embedded in the scripts and need a manual edit when Anthropic changes prices.

### Privacy / opt-out

Telemetry is local-only — nothing is sent off your machine. The records contain `project_root` (filesystem path) and `task_class`, but no source-code contents and no user prompts.

To disable telemetry entirely, set `CLAUDE_MULTIAGENT_NO_METRICS=1` in your environment. Both the SubagentStop and Stop hooks honor it. Existing files in `~/.claude/metrics/` are preserved on uninstall.

## Roadmap

| Phase | Status | Sub-plan |
|---|---|---|
| 1. Skeleton + installer | ✅ implemented | `plans/01-skeleton-and-installer.md` |
| 2. Librarian + memory | ✅ implemented | `plans/02-librarian-and-memory.md` |
| 3. Orchestrator + researcher + planner | ✅ implemented | `plans/03-orchestrator-research-planner.md` |
| 4. Engineers + QA + auditor | ✅ implemented | `plans/04-engineers-qa-auditor.md` |
| 5. Retrospective + mistake learning | ✅ implemented | `plans/05-retrospective-mistake-learning.md` |
| 6. Cost telemetry + tuning | ✅ implemented | `plans/06-cost-telemetry-tuning.md` |
| 7. User-facing activity digest | ✅ implemented | `plans/07-activity-digest.md` |
