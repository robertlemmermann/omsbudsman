# Phase 2 — Librarian + Memory

**Goal:** A dedicated agent owns a two-tier memory system (global + per-project). At session start it loads only relevant memory and injects a short brief into the orchestrator. During the session it appends new facts on demand. At session end it compacts: dedupes, summarizes verbose entries, prunes stale ones.

## Deliverables

1. Memory directory layouts (global + per-project) + seed `INDEX.md` files.
2. `librarian.md` agent definition with strict prompt.
3. SessionStart hook that runs the librarian and emits the brief.
4. Append protocol — how the orchestrator delegates writes ("librarian: record X").
5. Compact protocol — runs at session end via Stop hook (added in phase 5; stubbed here).
6. `.gitignore` snippet for projects that don't want to commit `.claude/memory/`.

## Memory layouts

### Global — `~/.claude/memory/`
```
INDEX.md         # what's in here, last updated, size, top tags
facts.md         # cross-project truths, user preferences, conventions
decisions.md     # cross-project decisions with rationale + date
mistakes/
  INDEX.md       # tag → file map
  <topic>.md     # one file per mistake category (e.g. "git-operations.md")
```

### Per-project — `<repo>/.claude/memory/`
```
INDEX.md         # what's in here for this project
project.md       # stack, conventions, gotchas, architecture overview
decisions.md     # project-specific decisions with rationale + date
mistakes/
  INDEX.md
  <topic>.md     # project-specific mistakes
```

## Memory routing rules (enforced by librarian)

A new fact goes **per-project** if it satisfies any of:
- References a specific file path, module, or symbol in this repo.
- References a specific stack choice or convention specific to this codebase.
- Names a person, team, or process tied to the project.

A new fact goes **global** if:
- It's a Claude behavior pattern (e.g. "always quote paths with spaces").
- It's a user preference (e.g. "prefer pnpm over npm").
- It's a general language/tool idiom not specific to one repo.
- It's a recurring mistake pattern observed across more than one project.

When in doubt → per-project (safer; can be promoted to global later if seen elsewhere).

## Markdown format (strict, but human-readable)

Every memory file uses this shape:

```markdown
# <Title>

> Last updated: <ISO date> · Entries: <N>

## <Section / topic>

- **<short label>** — <one-line fact>. Added <ISO date>. Tags: `tag1`, `tag2`.
- ...
```

`mistakes/<topic>.md` adds extra fields per entry:

```markdown
## <mistake label>

- **What went wrong:** <one line>
- **Why it was missed:** <one line — which agent/check failed>
- **Prevention rule:** <imperative, actionable line>
- **Tags:** `tag1`, `tag2`
- **First seen:** <ISO date> · **Recurrences:** <N> · **Last seen:** <ISO date>
```

Headings + bullets only. No tables, no nested code blocks. Keeps grep/diff clean and the librarian's edits surgical.

## Librarian agent (`agents/librarian.md`)

**Model:** haiku.

**System prompt summary:**
- You are the memory keeper. You read, write, dedupe, and compact memory files.
- Two tiers: `~/.claude/memory/` (global), `<project>/.claude/memory/` (project-specific).
- Determine project root via the `LIBRARIAN_PROJECT_ROOT` env var passed by the hook (the orchestrator's cwd at session start). If empty → only global memory exists for this session.
- **Three modes**, selected by the `LIBRARIAN_MODE` env var or first line of input:
  - `brief` — read both tiers, return a ≤200-token brief: top 3 global facts, top 5 project facts, top 5 relevant mistakes (matched by current project's stack tags).
  - `append` — receive a JSON-ish line `{"tier": "global"|"project", "section": "...", "entry": "..."}`. Insert in the correct file, dedupe against existing entries (skip if a near-duplicate exists, log a recurrence count instead).
  - `compact` — for each memory file: dedupe entries, merge similar bullets, drop entries with no recurrence in the last 90 days unless tagged `permanent`, update `INDEX.md`.
- **Output cap:** 200 words for `brief`; one-line confirmation for `append` and `compact`. Never paste file contents back.
- Pre-flight: if a target file doesn't exist, create it from the standard template above.

## SessionStart hook (replaces the phase 1 stub)

`claude-system/hooks/session-start.sh`:
```bash
#!/usr/bin/env bash
# Locate project root (current working dir's git root, fall back to cwd)
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export LIBRARIAN_PROJECT_ROOT="$PROJECT_ROOT"
export LIBRARIAN_MODE="brief"
# Ensure project memory dir exists
mkdir -p "$PROJECT_ROOT/.claude/memory/mistakes" 2>/dev/null
# Hook output is shown to the user; the orchestrator reads memory via librarian agent calls.
echo "[claude-multi-agent] memory tier: ~/.claude/memory/ + $PROJECT_ROOT/.claude/memory/" >&2
```

`session-start.ps1` is the equivalent in PowerShell.

The hook does **not** run the librarian directly — the orchestrator's first action (per its prompt, defined in phase 3) is to invoke the librarian in `brief` mode. Why: keeps the hook fast and lets Claude Code's permission system apply.

## Append protocol

When the orchestrator decides something is worth remembering, it spawns librarian with a payload like:

```
mode: append
tier: project
section: Stack
entry: Backend uses FastAPI with SQLAlchemy 2.0; tests use pytest-asyncio.
tags: stack, python, fastapi
```

Librarian writes it to the right file, dedupes, returns: `appended` or `deduped (recurrence: 2)`.

## Compact protocol

Triggered by the Stop hook (defined in phase 5). Runs `librarian` with `mode: compact`. Librarian:
1. Loads each memory file under both tiers.
2. Deduplicates near-identical bullets (semantic match, not just exact string).
3. Merges bullets with the same tags + topic into a single richer bullet.
4. Drops entries last seen >90 days ago, unless tagged `permanent` or `mistake`.
5. Rewrites `INDEX.md` (timestamp, entry count, top tags).
6. Returns one-line summary.

## Acceptance criteria

- [ ] `~/.claude/memory/INDEX.md` and the seed empty files exist after install.
- [ ] First session in a fresh repo creates `<repo>/.claude/memory/` with stub files.
- [ ] Calling the librarian in `brief` mode returns ≤200 tokens.
- [ ] Calling the librarian in `append` mode adds an entry to the correct tier and file.
- [ ] Appending the same fact twice → dedupes; recurrence counter increments.
- [ ] Calling the librarian in `compact` mode reorganizes a deliberately-bloated test file correctly.
- [ ] If no git repo present, librarian falls back to global memory only without error.

## Dependencies / order

- Depends on phase 1 (install pipeline + hook system).
- **Blocks:** phase 3 (orchestrator depends on the librarian for its memory brief), phase 5 (retrospective writes via librarian).

## Risks / open notes

- Dedupe is the hardest part — naive string match misses paraphrases, semantic match is expensive. Start with normalized-lowercase + token-jaccard threshold; revisit if it's too lossy.
- The 90-day prune window is arbitrary; make it a constant in the librarian prompt so it's easy to tune.
- File locking: two concurrent sessions writing memory could conflict. Acceptable risk for v1; revisit if it bites.
- Project memory in `<repo>/.claude/memory/` vs gitignored: provide README guidance, don't force.
