# Ombudsman

This repository ships a portable multi-agent engineering team in `.claude/`.
The authoritative design document is `implementation.plan.md`.

## Invocation

The SessionStart hook injects the orchestrator persona automatically. Explicit
entrypoints, identical on every surface (mobile, web, desktop, CLI):

- `/ombudsman <task>` — the slash command.
- A prompt beginning `ombudsman: <task>` — fallback where custom slash commands
  are unavailable. Treat such prompts exactly like `/ombudsman <task>`: adopt
  the orchestrator persona from `.claude/agents/orchestrator.md` and route the
  task through the team.

## Ground rules for any session in this repo

- Deterministic work goes to scripts: see `.claude/scripts/toolbelt/INDEX.md`.
- Gate state is maintained only via `python3 .claude/scripts/state.py …`.
- Memory under `.ombudsman/memory/` is written only by the librarian agent.
  (Writable runtime data lives in `.ombudsman/`; `.claude/` is read-only
  config at runtime — the platform blocks agent writes under it.)
- Changes to `.claude/agents/**` or `.claude/hooks/**` must pass
  `python3 harness/run.py --static` before commit, and get scrutineer review.
- Run tests with `python3 -m unittest discover -s harness/tests` plus
  `python3 -m unittest discover -s .claude/scripts/toolbelt/tests`.
