# Master Plan — Claude Code Multi-Agent System

A globally-installable, persistent, self-improving multi-agent system for Claude Code. Lives in `~/.claude/`, works across any session, on any project, on macOS and Windows.

## Goals

1. **Persistent memory** curated by a dedicated agent, not just dumped files.
2. **Specialist agents with delegation** — orchestrator routes, specialists execute.
3. **Hyper-efficient context use** — minimize tokens at every layer.
4. **Quality gates** — QA before accepting engineering output, auditor before user handback.
5. **Self-improving** — learns from corrections and avoids repeat mistakes.
6. **Portable** — installable from this repo onto any macOS/Windows machine, works with any Claude Code setup.

## Agent roster

| Agent | Role | Model tier |
|---|---|---|
| `orchestrator` | Main session persona. Routes only — never reads/writes files itself. | inherits |
| `librarian` | Dedicated memory agent. Curates, prunes, dedupes, summarizes. | haiku |
| `retrospective` | Mistake-learning agent. On corrections, post-mortems and writes prevention rules. | sonnet |
| `researcher` | Read-only investigation. Returns file:line refs, never file contents. | haiku |
| `planner` | Research → ordered steps. Caps output at ~30 lines. | sonnet |
| `frontend-engineer` | Implementation — UI, client, styling. | sonnet |
| `backend-engineer` | Implementation — server, data, APIs. | sonnet |
| `test-engineer` | Implementation — tests, fixtures, harnesses. | sonnet |
| `qa-reviewer` | Gates engineering output before orchestrator accepts it. | sonnet |
| `auditor` | Final gate before user handback. Verifies original requirements met. | sonnet |

## Directory layout (after install)

```
~/.claude/
├── agents/                       # Claude Code auto-discovers these
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
│   ├── session-start.sh / .ps1
│   ├── user-prompt-submit.sh / .ps1
│   ├── subagent-stop.sh / .ps1
│   └── stop.sh / .ps1
├── memory/
│   ├── INDEX.md                  # librarian-maintained map
│   ├── facts/global.md           # cross-project truths
│   ├── projects/<repo-hash>.md   # per-repo knowledge
│   ├── decisions/<date>.md       # decision log
│   └── mistakes/
│       ├── INDEX.md              # tag → file map
│       └── <topic>.md            # prevention rules
├── metrics/                      # optional token telemetry
│   └── sessions.jsonl
└── settings.json                 # registers hooks, may be merged with user's existing
```

## Repo layout (this repo, the installer source)

```
omsbudsman/
├── plans/                        # this directory
├── claude-system/                # mirror of ~/.claude/ contents installed by the installer
│   ├── agents/
│   ├── hooks/
│   ├── memory/                   # seeded with empty INDEX.md only
│   └── settings.fragment.json    # merged into user's settings.json
├── install.sh                    # macOS/Linux installer
├── install.ps1                   # Windows installer
├── uninstall.sh / .ps1           # restores backups
└── README.md
```

## Delegation flow

```
user prompt
  ↓
orchestrator (main session)
  ↓
[librarian: load relevant memory slice]   ← SessionStart hook
  ↓
researcher → planner
  ↓
frontend-engineer / backend-engineer / test-engineer (parallel where independent)
  ↓
qa-reviewer  ← gate
  ↓
auditor      ← gate (verifies original requirements)
  ↓
[librarian: append new facts/decisions]
[retrospective: if corrections happened this session]   ← Stop hook
  ↓
user
```

Orchestrator never opens files itself. It dispatches and synthesizes.

## Hooks

| Event | Action |
|---|---|
| `SessionStart` | Run librarian → inject ≤200-token memory brief into orchestrator |
| `UserPromptSubmit` | Regex scan for correction signals → set `RETRO_NEEDED` flag |
| `SubagentStop` | (optional) log token usage to `metrics/sessions.jsonl` |
| `Stop` | If auditor not run → nag. If `RETRO_NEEDED` → launch retrospective. Then librarian compact. |

## Cost-reduction mechanics

1. **Model tiering** — Haiku for librarian/researcher (volume work), Sonnet for engineering/QA/auditor, Opus only when orchestrator escalates explicitly.
2. **Orchestrator never opens files** — biggest reduction. The main session's context is the most expensive.
3. **Subagent output caps** — every agent prompt enforces "≤150 words. File refs as `path:line`, never paste contents."
4. **Researcher returns refs, not text.**
5. **Pre-flight check** — each subagent declares "I have enough info" or returns `BLOCKED: <missing>` before doing speculative work.
6. **Memory slice, not dump** — librarian filters by current project + active topics.
7. **Parallelism only when independent** — sequential when downstream depends on upstream.
8. **Stable system prompt** — maximize prompt-cache hits.
9. **No preambles** — agent prompts forbid "Sure, I'll…" filler.
10. **Telemetry** — `metrics/sessions.jsonl` lets us measure tokens-per-task and tighten over time.

## Decisions (tentative, confirm before relevant phase)

- **Memory format:** Markdown with YAML frontmatter. Human-readable, structured enough for librarian.
- **Retrospective trigger sensitivity:** Start strict — only explicit signals like "that's wrong", "you missed", "should have been", "actually no", "broken because", "fix this". Tune later.
- **Project identity:** SHA-256 hash of `git config --get remote.origin.url` (truncated 12 chars). Falls back to cwd basename hash if no git remote.
- **Per-project override:** Yes — if `<repo>/.claude/agents/<name>.md` exists, it overrides the global. Standard Claude Code behavior; we just document it.

## Build phases

Each phase is a separate sub-plan. Each phase ends with verification on a clean install.

| # | Phase | Sub-plan |
|---|---|---|
| 1 | Skeleton + installer | `01-skeleton-and-installer.md` |
| 2 | Librarian + memory layout | `02-librarian-and-memory.md` |
| 3 | Orchestrator + researcher + planner | `03-orchestrator-research-planner.md` |
| 4 | Engineers + QA + auditor | `04-engineers-qa-auditor.md` |
| 5 | Retrospective + correction detection | `05-retrospective-mistake-learning.md` |
| 6 | Cost telemetry + tuning pass | `06-cost-telemetry-tuning.md` |

## Acceptance criteria for the system as a whole

- Fresh `git clone` + `./install.sh` (or `.\install.ps1`) on a clean machine yields a working setup.
- `claude` started in any directory loads the orchestrator persona and a memory brief.
- A trivial change ("add a hello world function") flows: orchestrator → researcher → planner → engineer → QA → auditor → user.
- Issuing a correction ("no, that's wrong") leads to a `mistakes/<topic>.md` entry by session end.
- Next session, that prevention rule is surfaced before the relevant agent runs.
- Total tokens per simple task measured; baseline established for future tuning.
- Uninstall restores the pre-install state.
