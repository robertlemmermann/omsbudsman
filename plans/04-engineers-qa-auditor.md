# Phase 4 — Engineers + QA + Auditor

**Goal:** Close the loop. Three engineering specialists do the actual work, a QA reviewer gates their output before it reaches the orchestrator, and an auditor verifies the final result against the user's original requirements before handback.

## Deliverables

1. `frontend-engineer.md`, `backend-engineer.md`, `test-engineer.md` — implementation agents.
2. `qa-reviewer.md` — gates engineering output (functional correctness, scope, side effects).
3. `auditor.md` — final gate, requirements verification.
4. Stop hook update: refuses to terminate cleanly if auditor wasn't run.
5. End-to-end test: a "make a real change" request flows through all gates and produces a working diff.

## Engineer agents

All three share a common contract; differences are scope-only.

**Model:** sonnet for all three.

**Common contract:**
- Receive a single planned step (from planner) with its dependency outputs.
- Output format:
  ```
  CHANGES:
  - <file>:<line> — <one-line description of edit>
  - ...
  
  RATIONALE: <≤3 lines, why these specific changes>
  
  TESTS RUN: <command + result, or "none — see test-engineer">
  
  HANDOFF: <what QA needs to verify, or "none">
  ```
- Cap: 50 lines.
- Do not implement beyond the planned step. If the step is wrong → return `BLOCKED: step issue: <description>`.
- Do not add error handling, comments, or abstractions not required by the step.
- Pre-flight: confirm all dependencies named in the step exist in the codebase. If not → `BLOCKED`.

### `frontend-engineer.md` scope
UI components, client-side state, styling, accessibility, browser-side data fetching. Allowed languages: JS/TS/JSX/TSX, HTML, CSS/SCSS, Vue/Svelte/Astro templates. Refuses backend or test work.

### `backend-engineer.md` scope
Server-side logic, APIs, data models, database migrations, background jobs, infra config. Allowed: Python, Go, Rust, Node server code, SQL, IaC files. Refuses UI or test-only work.

### `test-engineer.md` scope
Unit/integration/e2e tests, fixtures, mocks, test harnesses, coverage configuration. Refuses production code changes (only test files + test config).

**Why split this strictly:** the orchestrator's plan can dispatch FE + BE + tests in parallel without conflict because each agent's allowed-files set is disjoint by convention. The QA reviewer enforces this.

## QA reviewer agent (`agents/qa-reviewer.md`)

**Model:** sonnet.

**Behavior:**
- Receives the engineer's CHANGES output + the planned step it was meant to implement.
- Checks (in order — first failure short-circuits):
  1. **Scope match** — every changed file is within the engineer's allowed scope.
  2. **Step match** — changes implement the planned step, no more, no less.
  3. **Functional sanity** — code reads correctly, no obvious bugs (off-by-one, wrong types, missing await, unhandled None).
  4. **Side-effect check** — no unintended file changes, no commented-out code left behind, no debug prints.
  5. **Convention match** — uses patterns recorded in project memory (gets these from librarian on demand).
- Output format:
  ```
  VERDICT: pass | fail
  
  ISSUES (if fail):
  - <category>: <file>:<line> — <description> — <suggested fix>
  
  NOTES (if pass): <optional ≤2 lines>
  ```
- Cap: 30 lines.
- Pre-flight: if the planned step or engineer output is malformed → `BLOCKED: cannot review: <reason>`.

**Loopback:** orchestrator routes failed reviews back to the same engineer with the ISSUES list. Maximum two retry cycles before escalating to user.

## Auditor agent (`agents/auditor.md`)

**Model:** sonnet.

**Behavior:**
- Receives: original user request, the planner's PLAN, all engineer CHANGES summaries, all QA VERDICTs.
- Checks:
  1. **Requirements coverage** — every explicit requirement from the user request maps to at least one PLAN step that produced a passing QA verdict.
  2. **Implicit requirements** — common-sense expectations not stated (e.g. user asked for a button → button is keyboard-accessible) are flagged for orchestrator's awareness, not failure.
  3. **No regressions claimed** — if the change touches existing behavior, were tests run? Asks test-engineer to confirm if not.
  4. **User-visible state** — what will the user see when they pull this? Summarize in one paragraph.
- Output format:
  ```
  VERDICT: approve | revise | escalate
  
  COVERAGE:
  - "<requirement>" → step #<N> → <pass/fail>
  - ...
  
  GAPS (if revise/escalate):
  - <description> — <suggested next action>
  
  USER SUMMARY: <one paragraph for the orchestrator to relay to the user>
  ```
- Cap: 40 lines.
- The auditor never opens files itself — it works from the structured inputs. (If it needs evidence, it asks orchestrator to dispatch researcher.)

## Stop hook update

`claude-system/hooks/stop.sh` (and `.ps1`) checks a session-state file (`~/.claude/state/session-<id>.json`, written by the orchestrator on each major step):
```json
{
  "auditor_verdict": "approve" | "revise" | "escalate" | null,
  "qa_verdicts": ["pass", "pass", "fail", "pass"],
  "retro_needed": false
}
```

If `auditor_verdict` is null AND any work was done this session (any QA verdicts present), the Stop hook emits a non-zero exit and message: `auditor not run — run auditor before responding`. This blocks clean termination, forcing the orchestrator to circle back.

If no work was done (pure-question session) → Stop hook exits 0 silently.

Implementation note: orchestrator writes this state file at each gate; we already have the directory in phase 1.

## Acceptance criteria

- [ ] A "rename function X to Y across the codebase" request flows: research → plan → backend-engineer → QA pass → auditor approve → user.
- [ ] If backend-engineer accidentally edits a test file, QA fails with a scope-match issue.
- [ ] If frontend-engineer is dispatched a backend task, it returns `BLOCKED` immediately.
- [ ] Orchestrator skipping the auditor → Stop hook fires, orchestrator runs auditor, then completes cleanly.
- [ ] Auditor flagging a missing requirement → orchestrator loops back through plan/engineer cycle.
- [ ] All three engineers can run in parallel on disjoint files (FE component + BE endpoint + new test) without merge conflicts.
- [ ] Orchestrator's main-session transcript still shows zero direct file reads/writes.

## Dependencies / order

- Depends on phases 1, 2, 3.
- **Blocks:** phase 5 (retrospective consumes QA failures + auditor revisions as learning signal).

## Risks / open notes

- The strict scope split (FE / BE / test) breaks down for full-stack files (Next.js pages, monorepos with shared packages). Define the rule: if a file lives under a shared/`packages/`-style path, the orchestrator picks the agent best suited and notes the override in memory. QA accepts the override if explicitly logged.
- QA rejecting twice in a row should escalate to user, not infinite-loop. Two-retry cap is enforced in orchestrator prompt; verify in test.
- Auditor "implicit requirements" check is fuzzy and could over-trigger. Keep it advisory (NOTES, not failures) until we measure false-positive rate.
- Stop hook blocking clean termination is intrusive — make sure the bypass message tells the user how to skip it (e.g. `/no-audit` slash command) for cases where they're explicitly mid-work.
