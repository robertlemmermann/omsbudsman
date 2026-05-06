# Claude Code Multi-Agent System

A globally-installable, persistent, self-improving multi-agent system for Claude Code. Lives in `~/.claude/`, works across any session, on any project, on macOS and Windows.

**Status:** phase 6 — complete. Full agent loop, two-tier memory, retrospective self-improvement, and per-invocation telemetry with a baseline-reporting CLI. See `plans/00-master-plan.md` for the full architecture and `plans/0N-*.md` for each phase.

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
├── scripts/               # metrics.{sh,ps1} reporting CLI + pricing.json
├── commands/              # slash commands (e.g. /forget-rule)
├── memory/                # global tier — cross-project learning
│   ├── INDEX.md           # rest is created lazily by the librarian
│   └── .archive/          # soft-deleted entries (compact + /forget-rule)
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

## Telemetry

Every subagent return appends one JSONL record to `~/.claude/metrics/sessions.jsonl`; every Stop appends a per-session summary. Records carry a `schema_version` and the optional `claude_code_version` so future schema changes don't silently corrupt baselines. The active file rotates to:
- `sessions.<UTC-timestamp>.jsonl.gz` when it exceeds 10 MB (last 4 archives retained), OR
- `sessions.<YYYY-MM>.jsonl.gz` at the first append after a month boundary (kept indefinitely so you can answer "show me April").

Reports:

```bash
~/.claude/scripts/metrics.sh                       # last 7 days summary
~/.claude/scripts/metrics.sh --agent researcher    # per-agent breakdown
~/.claude/scripts/metrics.sh --session <id>        # one session's flow
~/.claude/scripts/metrics.sh --baseline            # writes/updates metrics/BASELINE.md
~/.claude/scripts/metrics.sh --json                # raw summary JSON
~/.claude/scripts/metrics.sh --days 30             # widen the window
~/.claude/scripts/metrics.sh --exclude-outliers    # trim top/bottom 5% from stats
~/.claude/scripts/metrics.sh --histograms          # text-mode bars per agent
~/.claude/scripts/metrics.sh --check               # exit non-zero if tokens/task drift > threshold
~/.claude/scripts/metrics.sh --regress-pct 30      # threshold for --check (default 20%)
```

`--check` reads `BASELINE_TOKENS_PER_TASK` from `metrics/BASELINE.md` (written by `--baseline`) and compares it to the last-7-days mean. Wire it into your shell's `PROMPT_COMMAND` or a CI cron to surface cost drift early.

PowerShell users have the matching `metrics.ps1` with `-Agent`, `-Session`, `-Baseline`, `-Json`, `-Days` switches.

Pricing lives in `~/.claude/scripts/pricing.json` (per-1M-token rates as `[input, output]` plus a `last_updated` field). Edit that file when Anthropic changes rates; `metrics.sh` warns when the file is more than 90 days old.

### Privacy / opt-out

Telemetry is local-only — nothing is sent off your machine. The records contain `project_root` (filesystem path) and `task_class`, but no source-code contents and no user prompts.

To disable telemetry entirely, set `CLAUDE_MULTIAGENT_NO_METRICS=1` in your environment. Both the SubagentStop and Stop hooks honor it. Existing files in `~/.claude/metrics/` are preserved on uninstall.

## Slash commands

Installed to `~/.claude/commands/`:

- `/forget-rule [filter]` — list recent learned mistake-prevention rules and soft-delete (archive) one. Use when a wrongly-learned rule is polluting your sessions. The archived entry lives at `<tier>/.archive/forget-<UTC-date>.md` and can be restored by hand.

## Roadmap

| Phase | Status | Sub-plan |
|---|---|---|
| 1. Skeleton + installer | ✅ implemented | `plans/01-skeleton-and-installer.md` |
| 2. Librarian + memory | ✅ implemented | `plans/02-librarian-and-memory.md` |
| 3. Orchestrator + researcher + planner | ✅ implemented | `plans/03-orchestrator-research-planner.md` |
| 4. Engineers + QA + auditor | ✅ implemented | `plans/04-engineers-qa-auditor.md` |
| 5. Retrospective + mistake learning | ✅ implemented | `plans/05-retrospective-mistake-learning.md` |
| 6. Cost telemetry + tuning | ✅ implemented | `plans/06-cost-telemetry-tuning.md` |
