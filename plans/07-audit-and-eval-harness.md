# Plan 07 — Audit + Evaluation Harness

> Status: **proposal, for review.** This document is an audit of the existing system
> plus a design for an evaluation harness. It is intended to be scrutinized by an
> independent reviewing agent before any implementation lands. Every audit finding is
> anchored to a `file:line` so it can be verified directly.

## Context

The system (10 agents, 4 lifecycle hooks, two-tier memory, gate enforcement,
retrospective mistake-learning, local telemetry) is functionally complete through all 6
planned phases (`plans/00-master-plan.md`). Two things are now needed:

1. **A rigorous audit** across five axes — general improvements, token-efficiency
   maximization, token *reduction* by offloading deterministic work to hook scripts,
   security, and inter-agent communication (including whether responsibility/ownership
   has holes and whether the messaging harness can be made leaner without losing
   quality).
2. **An evaluation harness** so any future change to the system gets benchmarked for
   how it performed and whether the change was actually *adopted* (behavior changed as
   intended). This mirrors Anthropic's `skill-creator` eval methodology
   (deterministic + LLM-judge graders, with/without paired comparison, iteration
   benchmarking).

Intended outcome: a measurable, defensible system where prompt/hook edits are validated
against a benchmark instead of by intuition, plus a prioritized fix list from the audit.

**Decided scope for the follow-up implementation:** full scope (harness + all Part A
fixes + A5 mobile repackaging), harness built first. Runner drives the system via
headless `claude -p`.

---

## Part A — Audit findings

### A1. Correctness bugs (fix regardless of everything else)

1. **Env vars don't propagate between hooks/subagents.** `claude-system/hooks/session-start.sh:47-53`
   uses `export LIBRARIAN_GLOBAL_ROOT/LIBRARIAN_PROJECT_ROOT`, but each Claude Code
   hook runs in its own process — exports do not reach `subagent-stop.sh:19-20`,
   `stop.sh:22-23`, `user-prompt-submit.sh:16`, or any subagent. They currently
   survive only because the fallbacks (`$HOME/.claude`, `pwd`) happen to match locally.
   This breaks the moment the layout isn't `~/.claude` (i.e. cloud/plugin/mobile).
   Fix: write to `$CLAUDE_ENV_FILE` (documented mechanism) instead of `export`.
2. **`set -e` + inline Python can abort before the guaranteed `exit 0`.**
   `session-start.sh:6` sets `-e`; if the Python block (`:58-104`) throws, the hook
   exits non-zero and the trailing `exit 0` (`:107`) never runs. The file's own header
   promises "Must exit 0 so it never blocks session startup." Wrap the Python call so
   failures are swallowed (`|| true`) or drop `set -e` in the hooks.
3. **Stale model IDs.** Agents pin `claude-sonnet-4-6` (e.g. `planner.md:5`,
   `backend-engineer.md:5`) and `claude-haiku-4-5`; `metrics.sh:55-61` prices
   `claude-opus-4-7/4-6`. Current models are Opus 4.8, Sonnet 5, Haiku 4.5, Fable 5.
   `claude-sonnet-4-6` likely no longer resolves. Refresh all model refs + the pricing
   table.

### A2. Security

The system's security boundaries are **prompt instructions, not tool grants** — the
single biggest security theme.

1. **"Read-only" agents hold write-capable Bash.** `researcher.md:4` grants full
   `Bash` while the prose (`:16-18`) says read-only only; `qa-reviewer.md:5` same.
   Nothing enforces it — a prompt-injected or drifting agent can mutate the repo.
   Fix: scope Bash via Claude Code permission settings (allow-list read-only commands),
   or drop Bash from researcher/qa in favor of Read/Grep/Glob where possible.
2. **Engineers hold unrestricted Bash + Write** (`backend-engineer.md:5` etc.). Prose
   forbids new deps / `rm` / network, but nothing enforces it. Recommend a project-level
   `deny` permission list for the destructive verbs the prompts already forbid.
3. **Librarian is the "sole memory writer" by convention only** (`librarian.md:4` grants
   Read/Write/Edit/Bash). It is told never to write outside the two memory roots
   (`:143`), but has repo-wide write. Acceptable given it's trusted, but worth a
   path-scoped guard once offloaded to scripts (see B).
4. **No injection surface in hooks** (payloads are passed as argv to Python, not
   `eval`'d) — verified clean. Good.

### A3. Token efficiency — reduce by offloading deterministic work to scripts

The design already tiers models and caps output well. The remaining waste is **model
calls spent on mechanical work that a script can do for zero tokens.**

1. **Memory brief is a haiku subagent call every session** (`orchestrator.md:24-31`
   spawns librarian `mode: brief`). The brief's selection logic — top-3 global by
   recency/recurrence, top-5 project, top-5 mistakes by tag match (`librarian.md:24-29`)
   — is deterministic. **Offload to `session-start.sh`**: read the memory files, rank,
   and inject the brief through `additionalContext` (the hook already builds
   `additionalContext` at `session-start.sh:84-103`). Eliminates one subagent call per
   session — the largest single recurring token cost. *This is the highest-value change.*
2. **Append dedup (Jaccard ≥ 0.6)** (`librarian.md:63`) is done in-model. Move the
   similarity computation into a helper script the librarian calls; the model only
   decides sharpen-vs-concatenate on a match.
3. **Compact (`librarian.md:77-87`)** is ~90% deterministic (dedup, drop-by-date, sort,
   header rewrite). Offload the mechanical passes to a script; leave only tag-merge
   judgment to the model.
4. **Gate-state JSON hand-written by the orchestrator** (`orchestrator.md:167` — it
   `cat`s heredocs). The orchestrator inherits the main (expensive) model; formatting
   JSON by hand burns its tokens. Replace with a tiny `state.sh` helper
   (`state.sh set-qa pass`, `state.sh set-auditor approve`) so the orchestrator emits a
   one-token command, not a JSON blob.

Already correctly offloaded (keep): correction detection (`user-prompt-submit.sh`),
telemetry (`subagent-stop.sh`, `stop.sh`), gate enforcement (`stop.sh:62-88`).

### A4. Inter-agent communication & ownership

The messaging protocol is already lean and disciplined (fixed field blocks, strict
line/token caps, refs-not-contents, no-preamble rules). The gaps are in **ownership**,
not verbosity.

1. **Planner holds `tools: Task`** (`planner.md:5`) but is defined as "You do not read
   files. You do not investigate" and the orchestrator is the sole router. Granting Task
   lets the planner spawn agents — an ownership violation baked into the tool grant.
   Fix: remove Task from planner (it should emit text only).
2. **No agent owns integration coherence.** Engineers each implement one step
   (`backend-engineer.md:10`); QA reviews one step (`qa-reviewer.md:38`); the auditor
   checks requirement coverage but "does not open files" (`auditor.md:10`). Nobody
   verifies that parallel engineer changes actually compile/run *together*. **Hole.**
3. **No whole-suite verification gate.** test-engineer runs its own tests; engineers run
   "existing tests"; the auditor trusts QA verdicts. There is no final "does the whole
   build/test still pass" gate. Recommend a deterministic **verification step** (a
   `verify` hook/script that runs the project's test command and feeds the result to the
   auditor) — this closes both #2 and #3 and is script-cheap.
4. **Minor scope smudges:** `qa-reviewer` (`:5`) and `retrospective` (`:6`) hold Task to
   fetch a librarian brief / re-dispatch researcher. Prefer passing the brief in the
   payload over granting Task. `auditor` holding Task (`:6`) to spawn researcher is
   defensible and documented — keep.
5. **BLOCKED is a prose convention, not a checked schema.** Every agent can emit
   `BLOCKED: <reason>`, and the orchestrator's handling is described in prose
   (`orchestrator.md:108-115`). A machine-checkable output schema (validated by the eval
   harness, below) lets prompts *shrink* — the belt-and-suspenders reminders can be
   trimmed once a grader enforces conformance. This is how we make the harness leaner
   **without** quality loss: move enforcement from repeated prose to deterministic checks.

### A5. Mobile / distribution

The system installs into `~/.claude/` (`install.sh:6`); nothing under `~/.claude`
carries into Claude Code cloud/mobile sessions (per Claude Code on the web docs: cloud
sessions start from a fresh repo clone; user-level `~/.claude` agents/hooks/plugins do
not carry over). The fix is repackaging as a **repo-declared plugin** (agents + hooks +
a committed `.claude/settings.json` plugin declaration), which *does* load into cloud
sessions. De-hardcoding `~/.claude` (A1.1) is a prerequisite. Sequenced after the eval
harness so the repackaging can be benchmarked for regressions.

---

## Part B — Evaluation harness (primary new deliverable)

**Goal:** a repeatable benchmark that answers, for any change to the system:
(a) did quality hold or improve, (b) did token cost move, (c) was the change *adopted*
(did behavior actually change as intended)?

### Design (mirrors Anthropic `skill-creator` evals)

**Layout** (new `evals/` tree in the repo):
```
evals/
├── evals.json                 # case manifest: prompt, expected_behavior, assertions
├── fixtures/                  # a small synthetic target repo the agents operate on
│   └── sample-project/        # deterministic, checked-in, reset per run
├── graders/
│   ├── deterministic.py       # schema/cap/gate/memory checks — no model calls
│   └── judge.md               # LLM-as-judge agent for synthesis/plan/routing quality
├── runner/
│   └── run_evals.py           # drives cases, captures transcript + telemetry
└── results/
    └── iteration-N/           # per-run outputs, grading.json, benchmark.json/.md
```

**Case shape** (`evals.json`, per skill-creator):
```json
{
  "id": "impl-add-endpoint",
  "prompt": "Add a /health endpoint that returns 200",
  "class": "implement",
  "expected_behavior": ["routes researcher→planner→backend→qa→auditor", "auditor approves"],
  "assertions": [
    {"name": "researcher-emits-findings-schema", "type": "programmatic"},
    {"name": "gate-state-has-auditor-verdict", "type": "programmatic"},
    {"name": "synthesis-leads-with-answer", "type": "llm"}
  ]
}
```

**Two grader tiers:**
- **Deterministic** (`graders/deterministic.py`, zero model cost) — this system is
  unusually rich in machine-checkable contracts, which is what makes the harness cheap
  and rigorous:
  - Output-schema conformance: researcher `FINDINGS/GAPS/CONFIDENCE`, engineer
    `CHANGES/RATIONALE/TESTS RUN/HANDOFF`, `VERDICT` blocks, brief `≤200 tokens`,
    researcher `≤30 lines`, engineer `≤50 lines`.
  - Gate-state transitions: `session-<id>.json` ends with non-null `auditor_verdict`
    when `qa_verdicts` is non-empty (the exact invariant `stop.sh:68-72` enforces).
  - Memory mutations: appended entries match `librarian.md:111-127` block format;
    recurrence counter increments on repeat.
  - Efficiency gates: total tokens ≤ threshold, right agents invoked (routing),
    `blocked` rate — **read directly from the telemetry JSONL the system already
    emits** (`subagent-stop.sh`). The existing telemetry is the harness's ground-truth
    backbone; no new instrumentation needed.
- **LLM-as-judge** (`graders/judge.md`) — for synthesis quality, plan quality, and
  routing appropriateness. Emits the skill-creator `{text, passed, evidence}` grading
  shape.

**Paired with/without comparison** (the "adoption" measurement):
- Run each case **with** the multi-agent system and **without** (baseline = plain Claude
  Code on the same fixture). Report paired lift (quality delta) and token delta — exactly
  skill-creator's `with_skill` / `without_skill` variants.
- For iterating on the system itself, run **old vs new** variant and diff
  `benchmark.json` across `iteration-N` dirs. "Adopted" = the targeted assertions flipped
  in the intended direction *and* an unrelated regression set held steady.

**Runner (headless `claude -p`):** `run_evals.py` shells out to `claude -p` once per case
against a fresh copy of the fixture repo, with an isolated temp `CLAUDE_HOME` per run
(installs the system into it so runs never touch the developer's real `~/.claude`). It
captures the transcript (`--output-format stream-json` / `--output-format json`) plus the
telemetry JSONL that run's `CLAUDE_HOME` produced. `--dangerously-skip-permissions` (or a
scoped permission file) is required for unattended runs; document that clearly since it
widens the tool surface for the run. Then `deterministic.py` grades, the judge runs, and
an `aggregate` step emits `benchmark.json` + `benchmark.md` (pass rate per assertion
category, token/cost mean ± delta vs baseline, per-agent adoption). Baseline (`without`)
runs use the same `claude -p` invocation with an empty `CLAUDE_HOME` (no agents/hooks).

**Seed cases (first pass, ~6–8):** one per task class the orchestrator classifies
(`orchestrator.md:35-41`) — pure-question, plan, implement, trivial, conversational —
plus a correction case (exercises the retrospective→librarian loop) and a memory-recall
case (a prevention rule from a prior run is surfaced and satisfied).

---

## Part C — Build order

Harness first (the measuring stick), then all Part A fixes. Committed in this order so
each step is independently reviewable and the benchmark can attribute any regression to a
specific change:

1. **Eval harness** (Part B) + `implement`/`question`/`plan` seed cases + a captured
   pre-change baseline (`benchmark.json` at iteration-0).
2. **A1 correctness bugs** — `$CLAUDE_ENV_FILE` propagation, `set -e` guard, model IDs.
   Prerequisite for mobile; re-run suite, expect no regressions.
3. **A3 token offloads** — deterministic brief in `session-start.sh`, `state.{sh,ps1}`
   helper, scripted dedup/compact. Re-run; expect measurable token drop on
   `question`/`plan` classes, quality steady.
4. **A2 security scoping + A4 ownership fixes** — scoped Bash/deny lists, remove `Task`
   from planner, add the whole-suite `verify` gate feeding the auditor. Re-run; quality
   holds, no new BLOCKED spikes.
5. **A5 mobile plugin repackaging** — `.claude-plugin/` manifest + repo-declared
   `settings.json`; benchmark for regressions, then a manual smoke test from the Claude
   mobile app on a repo that declares the plugin.

Prefer **stacked commits / a sequence of small PRs** over one monolithic diff, so each
layer can be evaluated against its benchmark delta.

---

## Files to create / modify

**Create:** `evals/evals.json`, `evals/fixtures/sample-project/*`,
`evals/graders/deterministic.py`, `evals/graders/judge.md`, `evals/runner/run_evals.py`,
`evals/README.md`, and a `/evals` skill (`claude-system/skills/evals/SKILL.md`) to invoke
it inline.

**Modify (fix phases, post-harness):** all `claude-system/hooks/*.sh` + `*.ps1`
(env-file, `set -e` guard); `claude-system/agents/*.md` (model IDs, remove `Task` from
planner, tighten tool grants); `claude-system/scripts/metrics.sh` + `.ps1`
(pricing/model table); new `claude-system/scripts/state.{sh,ps1}` and
`claude-system/scripts/mem_*.{sh,py}` helpers for the offloads; `session-start.sh`
(deterministic brief injection).

## Verification

- **Harness self-test:** run `run_evals.py` against the checked-in fixture with the
  system installed; confirm `benchmark.json` is produced, deterministic assertions
  pass/fail correctly (deliberately break one agent's schema and confirm the grader
  catches it), and the with/without paired lift is computed.
- **End-to-end sanity:** run the `implement` seed case; confirm the transcript shows
  researcher→planner→engineer→qa→auditor routing (from telemetry) and the gate-state
  file ends with a non-null auditor verdict.
- **Regression guard for fixes:** after each Part A change, re-run the full suite;
  require the targeted assertion(s) to flip as intended and the rest to hold — this is
  the machine-checked definition of "adopted."
- **Offload token check:** compare `metrics.sh --baseline` token totals before/after A3;
  expect a measurable drop on `question`/`plan` classes (brief no longer a subagent call).

## Open questions for the reviewer

- Global-tier memory has no durable home on an ephemeral cloud VM. Options: (a) back it
  with a dedicated private git repo the librarian syncs at session start/end, or
  (b) demote it to local-only best-effort. A5 assumes this is resolved before mobile.
- The `claude -p` runner needs `--dangerously-skip-permissions` for unattended runs.
  Is a scoped permission file preferred instead, accepting some manual approvals?
- Is the `verify` gate (A4.3) better as a hook (runs automatically) or a dedicated
  agent step the planner must include?
