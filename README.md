# Ombudsman

A portable, self-testing multi-agent engineering team for Claude Code. The
entire runtime lives in this repo's `.claude/` directory — **no installer** —
so it works identically on Claude Code **mobile (iOS/Android), web, desktop,
and CLI**, on macOS, Linux, and Windows.

The authoritative design document is [`implementation.plan.md`](implementation.plan.md).

## Adopt it on any project (copy one directory)

- **macOS / Linux / cloud:** `cp -r omsbudsman/.claude <your-project>/`
- **Windows:** `robocopy omsbudsman\.claude <your-project>\.claude /E`
- **No clone needed (mobile-friendly):** download this repo's ZIP from GitHub,
  extract, copy `.claude/` into your project, commit.

That's the whole installation. Open the project in any Claude Code surface and
the team is live: the SessionStart hook injects the orchestrator persona and
seeds project memory automatically.

**Project already has a `.claude/`?** Copy the `agents/`, `commands/`,
`hooks/`, `scripts/`, and `memory/` subdirectories wholesale (they're
namespaced and won't collide), then merge the `hooks` and `permissions` keys
of `settings.json` — automated by:

```bash
python3 .claude/scripts/toolbelt/jsonmerge.py yours.json ombudsman-settings.json -o .claude/settings.json
```

## Invoking the team

| How | Where it works |
|---|---|
| Just talk — the persona is auto-injected at session start | everywhere |
| `/ombudsman <task>` | everywhere slash commands exist |
| A prompt starting `ombudsman: <task>` | fallback, everywhere |

## The team

18 agents, routed by task size (XS/S/M/L) with risk promotion — a typo never
pays for a 13-agent pipeline, and an auth change never skips scrutiny:

- **Core:** orchestrator (router), researcher, planner, qa-reviewer (gate 1),
  auditor (gate 2), librarian (memory), retrospective (mistake learning).
- **Engineers:** frontend, backend, data, test.
- **Specialists:** docs-writer, design-lead, strategist (opus, L-tasks only),
  quant, scrutineer (red team), toolsmith, evaluator.

Checks and balances are structural: no agent reviews its own work, proposer ≠
approver for self-modifications, gates are enforced by hooks (`.claude/hooks/stop.py`
refuses to end a session whose audit is missing) and by CI — not by convention.

Deterministic work never costs tokens: see `.claude/scripts/toolbelt/INDEX.md`
and the system helpers (`state.py`, `verify.py`, `transcript.py`, `metrics.py`).

## Memory

`.ombudsman/memory/` is the committed project tier — facts, decisions, and
mistake-prevention rules curated exclusively by the librarian. Because it's
committed, it survives ephemeral mobile/cloud VMs: memory changes ride the
session branch and get reviewed like code. An optional global tier under
`~/.claude/memory/` is used when present (desktop); its absence never reduces
functionality — degradations are stated, never silent.

## Self-testing harness

```bash
python3 harness/run.py --static        # free: lints, schemas, 41 unit + lifecycle tests
python3 harness/run.py --behavioral    # golden cases headless via `claude -p` (needs credentials)
```

The behavioral layer copies `.claude/` into a temp fixture project — the exact
adoption path — so every eval run regression-tests mobile/cloud distribution.
Token accounting comes only from stream-json transcripts (the hook payloads
carry no usage data, so runtime telemetry records only fields that exist).

CI (`.github/workflows/ci.yml`) runs the static layer on Linux, macOS, and
Windows on every push/PR; `evals.yml` runs the behavioral layer on PRs labeled
`run-evals` and weekly against `main`. PRs touching `.claude/agents/**` or
`.claude/commands/**` fail CI without that label.

## Runtime notes

- Gate bypass for one stop (after verifying work yourself):
  `CLAUDE_SKIP_AUDIT=1`. Telemetry opt-out: `CLAUDE_OMBUDSMAN_NO_METRICS=1`.
- All writable runtime data lives in `.ombudsman/` (created lazily by the
  SessionStart hook — adopters still copy only `.claude/`): `memory/` is
  committed, `state/` and `metrics/` are gitignored. `.claude/` itself is
  read-only at runtime — Claude Code's sensitive-file protection blocks agent
  writes under it (verified), which doubles as free enforcement that no agent
  can silently edit its own definition.
- Hooks are stdlib Python 3 with no-fail wrappers and self-derived paths —
  registered as `python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/<name>.py"`. On
  native Windows without a `python3` shim, alias it (`doskey python3=python $*`)
  or adjust the six command strings in `.claude/settings.json` to `python`;
  the Windows CI job tracks this (plan §3.2 rule 6).
- Telemetry: `python3 .claude/scripts/metrics.py summary` /
  `--trend`. Cost from transcripts: `metrics.py cost <transcript.jsonl>`.

## Repository layout

| Path | What |
|---|---|
| `.claude/` | **The product** — copy this directory to adopt |
| `harness/` | Self-testing harness (dev asset, not copied) |
| `implementation.plan.md` | The single authoritative plan |
| `plans/` | Historical phase plans + archived source plans |
