# Fable Multi-Agent Team Plan

A comprehensive plan for an expansive, self-testing, cost-aware multi-agent team for Claude Code. This document is the single top-level plan; it subsumes and extends the phase plans in `plans/` (phases 1–6, already implemented) with the full team roster, the self-evaluation harness, deterministic offloading, and a gap analysis of what else the system needs to stay effective and efficient as it evolves.

**Reading order:** this file → `plans/00-master-plan.md` (implemented core) → `plans/0N-*.md` (per-phase detail).

---

## 1. Current state (what already exists)

Phases 1–6 are implemented in this repo and installable via `./install.sh` / `.\install.ps1`:

| Capability | Where | Status |
|---|---|---|
| 10-agent core team (orchestrator, librarian, retrospective, researcher, planner, frontend/backend/test engineers, qa-reviewer, auditor) | `claude-system/agents/` | ✅ |
| Two-tier memory (global `~/.claude/memory/` + per-project `.claude/memory/`) curated by the librarian | `claude-system/agents/librarian.md`, hooks | ✅ |
| Quality gates (qa-reviewer before acceptance, auditor before handback) | agents + `stop` hook nag | ✅ |
| Mistake learning (correction detection → retrospective → prevention rules, repeat amplification) | `user-prompt-submit` + `stop` hooks, `retrospective.md` | ✅ |
| Token telemetry (per-invocation JSONL, per-session summaries, rotation, baseline CLI) | `subagent-stop`/`stop` hooks, `scripts/metrics.{sh,ps1}` | ✅ |
| Cross-platform installer/uninstaller with backup + settings merge | `install.*`, `uninstall.*` | ✅ |

Everything below is **additive**: new specialists, a self-testing harness, deterministic offloading, and hardening.

---

## 2. Design principles

1. **The orchestrator's context is the most expensive real estate in the system.** It routes and synthesizes; it never reads files, never pastes code, never does work a specialist or a script can do.
2. **Deterministic work goes to scripts, not agents.** If a task has one correct output for a given input (formatting, counting, diffing, linting, metrics math, file moves, JSON merging), an agent may *invoke* a script but must never *reproduce* its work token-by-token. Agents are for judgment; scripts are for computation.
3. **Every agent has a budget and every budget is measured.** Token telemetry is not a report — it is a regression gate.
4. **The team modifies itself only through the harness.** An edit to an agent file or skill that hasn't passed the eval suite is a bug, not an improvement.
5. **Checks and balances are structural, not aspirational.** No agent reviews its own work; no agent both proposes and approves a self-modification; gates are enforced by hooks, not by convention.
6. **Memory is curated, not accumulated.** The librarian prunes as aggressively as it appends; unbounded memory is a token tax on every future session.

---

## 3. Full team roster

### 3.1 Existing core (implemented, phases 1–6)

| Agent | Role | Model tier |
|---|---|---|
| `orchestrator` | Main session persona. Routes, delegates, synthesizes. Never touches files. | inherits |
| `librarian` | Internal team memory: curates, prunes, dedupes, routes facts to global vs. project tier. | haiku |
| `retrospective` | Post-mortems corrections into prevention rules; amplifies repeat mistakes. | sonnet |
| `researcher` | Read-only investigation; returns `path:line` refs, never contents. | haiku |
| `planner` | Turns research into ≤30-line ordered plans. | sonnet |
| `frontend-engineer` | **Front end**: UI, client logic, styling, accessibility. | sonnet |
| `backend-engineer` | **Back end**: server, APIs, services, infra config. | sonnet |
| `test-engineer` | Tests, fixtures, harnesses for product code. | sonnet |
| `qa-reviewer` | Gate 1: reviews engineering output before the orchestrator accepts it. | sonnet |
| `auditor` | Gate 2: verifies the *original request* was met before user handback. | sonnet |

### 3.2 New specialists (this plan)

| Agent | Role | Model tier | Notes |
|---|---|---|---|
| `data-engineer` | **Data**: schemas, migrations, ETL, query optimization, data validation, analytics pipelines. | sonnet | Peers with backend-engineer; owns anything where the deliverable is data shape or data movement. |
| `docs-writer` | **Documentation**: READMEs, API docs, changelogs, inline doc comments, runbooks. Runs *after* auditor approval so docs describe what shipped, not what was planned. | haiku | Docs are high-volume/low-judgment → cheapest tier. Escalates to sonnet only for architecture docs. |
| `design-lead` | **Design**: UX flows, component/API ergonomics, visual consistency, design-system adherence. Consulted *before* frontend work starts (cheap) rather than reviewing after (expensive rework). | sonnet | Produces constraint lists (≤20 bullets), never mockups-as-prose. |
| `strategist` | **Strategy**: for multi-session or ambiguous work — clarifies goals, sequences milestones, calls out scope creep, decides build-vs-defer. Invoked only when the orchestrator classifies a task as `L` (large) or the user asks "should we…". | opus (capped) | The only agent allowed opus by default, and only ≤1 invocation per task. Its output feeds the planner. |
| `quant` | **Computation**: numerical/algorithmic analysis — complexity tradeoffs, statistics on telemetry, capacity estimates, benchmark interpretation. **Must** delegate arithmetic to scripts (writes a throwaway Python script, runs it, interprets results); never computes in-context. | sonnet | Enforced by prompt rule + eval: any multi-step arithmetic appearing in its output without a script invocation is an eval failure. |
| `scrutineer` | **Scrutinization**: adversarial red-team reviewer. Unlike qa-reviewer (does it work?) and auditor (does it match the ask?), the scrutineer attacks: edge cases, security holes, race conditions, "what breaks at 10× scale", hidden assumptions. Invoked on `M`/`L` tasks and on all self-modifications. | sonnet | Structurally separate from qa-reviewer so the "does it work" and "how does it break" mindsets never share a context. |
| `toolsmith` | **Deterministic offloading**: watches for repeated agent work that is deterministic (via retrospective reports + telemetry patterns) and converts it into scripts under `~/.claude/scripts/toolbelt/`. Owns the toolbelt: writes, tests, documents, versions each script. | sonnet | The mechanism that makes principle #2 self-enforcing over time. See §5. |
| `evaluator` | **Self-testing**: runs the eval harness (§6) against agent-file/skill changes, interprets score deltas and confidence intervals, produces PASS/FAIL/INCONCLUSIVE verdicts. Never edits agent files itself. | sonnet | Separation of powers: proposes-vs-approves split with the retrospective/toolsmith (§7). |

### 3.3 Coverage map (requested areas → owner)

| Requested area | Owner | Supporting cast |
|---|---|---|
| Front end | frontend-engineer | design-lead (upstream), qa-reviewer |
| Back end | backend-engineer | data-engineer, scrutineer |
| Data | data-engineer | quant (analysis), test-engineer (fixtures) |
| Documentation | docs-writer | librarian (indexes docs into memory) |
| Design | design-lead | frontend-engineer |
| Strategy | strategist | planner (executes strategy into steps) |
| Computation | quant + toolbelt scripts | — |
| Scrutinization | scrutineer | qa-reviewer, auditor |
| Checks & balances | qa-reviewer + auditor + scrutineer + hook-enforced gates | §7 |
| Internal team memory | librarian | retrospective (writes), hooks (load/compact) |
| Token optimization | telemetry + budgets + evaluator | §8 |
| Deterministic offloading | toolsmith + toolbelt | §5 |
| Self-testing of skills/agents | evaluator + eval harness | §6 |

---

## 4. Delegation flow (updated)

```
user prompt
  ↓
orchestrator ── classifies task: XS / S / M / L
  │
  ├─ XS (typo, one-liner, factual q):  answer directly or single engineer, skip pipeline  ← §9-G1
  ├─ S:   researcher → engineer → qa-reviewer → auditor
  ├─ M:   researcher → planner → engineer(s) ∥ → qa-reviewer → scrutineer → auditor
  └─ L:   strategist → researcher → planner → design-lead (if UI) → engineers ∥
              → qa-reviewer → scrutineer → auditor → docs-writer
  ↓
[librarian: append facts/decisions]     ← Stop hook
[retrospective: if corrections]         ← Stop hook
[toolsmith: if deterministic-repeat flagged]
  ↓
user
```

Rules:
- Parallel (`∥`) only when work items share no files.
- Every specialist pre-flights: `PROCEED` or `BLOCKED: <missing>` before doing speculative work.
- Gates can return work at most twice; the third failure escalates to the user with a diagnosis instead of burning tokens on retry loops.

---

## 5. Deterministic offloading — the toolbelt

**Goal:** agent tokens are never spent on work a script can do. This is the single biggest recurring cost lever after "orchestrator never opens files."

### 5.1 Toolbelt layout

```
~/.claude/scripts/toolbelt/
├── INDEX.md              # one line per script: name, purpose, usage — loaded by agents on demand
├── <name>.sh / .py       # POSIX sh or python3 only (installer-guaranteed runtimes)
└── tests/<name>.test.sh  # every script ships with a test (run by the harness, §6)
```

Seed scripts (phase 7):
- `count.py` — line/word/token-estimate counts (agents must not count in-context)
- `jsonmerge.py` — deep-merge JSON (used by installer and settings work)
- `diffstat.sh` — summarize a diff without pasting it
- `csvstat.py` — column stats for data-engineer/quant
- `todo-scan.sh` — enumerate TODO/FIXME with `path:line`
- `memlint.py` — validate memory-file structure for the librarian (headings, dedupe candidates)
- `agentlint.py` — static checks on agent files (§6.2)

### 5.2 The offloading loop

1. Telemetry tags each subagent record with a `task_class`. The retrospective and toolsmith periodically scan for **repeat deterministic patterns** (same class, near-identical structure, ≥3 occurrences).
2. Toolsmith writes a script + test, adds it to `INDEX.md`, and the librarian adds a one-line memory rule: *"For X, run `toolbelt/y` — do not do it in-context."*
3. The eval harness (§6) gets a case asserting the pattern is now script-invoked.
4. Telemetry confirms the class's token cost dropped; if not, the script or the rule is wrong → retrospective entry.

### 5.3 Hard rules (prompt-enforced, eval-checked)

- Any arithmetic beyond a single operation → script.
- Any exhaustive enumeration (files, matches, rows) → script.
- Any format conversion (JSON↔CSV↔MD tables) → script.
- Any verbatim transformation of >20 lines → script or editor tool, never retyped.

---

## 6. Self-testing harness (the core new deliverable)

The harness answers one question with measurable confidence: **did this change to an agent file, skill, hook, or toolbelt script make the team better, worse, or neither?**

### 6.1 Layout (in this repo — the harness tests the *source*, the installer ships it)

```
harness/
├── run.sh / run.ps1            # entrypoint: harness on current working tree
├── evals/
│   ├── golden/                 # golden tasks: YAML task + expected-properties rubric
│   │   ├── xs-typo-fix.yaml
│   │   ├── s-add-endpoint.yaml
│   │   ├── m-frontend-feature.yaml
│   │   ├── m-data-migration.yaml
│   │   ├── l-ambiguous-request.yaml
│   │   └── correction-learning.yaml   # inject a correction, assert a mistakes/ rule appears
│   ├── holdout/                # never used for tuning — regression-only (see gap G4)
│   └── rubrics/                # scoring: LLM-judge prompts + deterministic checks
├── static/
│   ├── agentlint.py            # deterministic checks on agent .md files:
│   │                           #   frontmatter valid, model tier declared, output cap present,
│   │                           #   pre-flight clause present, ≤200 lines, no banned phrases
│   └── hooklint.sh             # hooks: shellcheck clean, honor NO_METRICS flag, idempotent
├── scripts/
│   ├── ab.py                   # A/B runner: N runs of each golden task on base vs. candidate
│   │                           #   agent set; Wilson interval on pass-rate delta; token delta
│   └── report.py               # verdict table: PASS / FAIL / INCONCLUSIVE per change
└── budgets.yaml                # per-task-class token budgets (§8.2) — harness fails on breach
```

### 6.2 Three test layers

| Layer | What it checks | Cost | When |
|---|---|---|---|
| **Static (deterministic)** | agentlint + hooklint + toolbelt script tests + installer smoke test in a temp `$HOME` | ~0 tokens | every commit (CI) |
| **Behavioral (golden tasks)** | Each golden task runs headless (`claude -p` with the candidate agent dir), scored by rubric: deterministic assertions first (files created? gate invoked? budget respected?), LLM-judge only for quality dimensions | ~$ per run | before merging any `claude-system/` change |
| **Comparative (A/B)** | For agent/skill edits: N≥5 runs base vs. candidate per affected golden task; report pass-rate delta with confidence interval + token-cost delta | $$ | before adopting a self-modification |

### 6.3 Verdicts

- **PASS** — quality non-inferior (CI lower bound > −5 pts) *and* tokens not regressed >10%, or quality strictly better.
- **FAIL** — quality regression or budget breach. Change is reverted (git makes this trivial — `claude-system/` is the source of truth).
- **INCONCLUSIVE** — interval too wide. Evaluator either increases N (bounded by a spend cap) or reports "change too small to measure; keep only if it reduces tokens."

### 6.4 Skill-builder integration

Claude Code's skill-building tooling (skill-creator / skill evaluation flows) can score how effective a skill update was. The harness treats it as **one judge among several**, not the authority:

- When available, `ab.py --judge=skill-builder` includes its confidence score as an extra rubric column.
- Our own golden-task pass rates remain the gating signal, because (a) skill-builder availability varies by surface, and (b) it doesn't know our token budgets or team-level flows.
- Divergence between skill-builder's verdict and ours is itself logged — persistent divergence means our rubrics need review.

### 6.5 Evolution safety loop

```
retrospective/toolsmith proposes change (branch in this repo)
  → static layer (free, instant)
  → evaluator runs behavioral + A/B on affected tasks
  → PASS → merge → installer syncs → telemetry watches live cost for 7 days
  → live regression? → auto-revert candidate + retrospective entry
```

---

## 7. Checks and balances (structural)

1. **Two-gate review of product work:** qa-reviewer (functional) and auditor (requirements) are separate agents with separate contexts; scrutineer adds adversarial review on M/L tasks. None of them writes code.
2. **Proposer ≠ approver for self-modification:** retrospective/toolsmith *propose* agent-file changes; the *evaluator* passes judgment via the harness; a hook blocks any write to `~/.claude/agents/` that didn't come through the installer (i.e., through the repo + harness path).
3. **Budget authority is external:** budgets live in `budgets.yaml`, checked by scripts and hooks — no agent can raise its own budget.
4. **Escalation over persistence:** two failed gate round-trips → the orchestrator reports the impasse to the user with both sides' one-paragraph positions. No infinite internal loops.
5. **Retry/spend circuit breaker:** the Stop hook flags any session whose token total exceeds 3× the task-class baseline; three consecutive flagged sessions of one class disable that class's autonomous mode pending review (gap G7).
6. **Audit trail:** every self-modification is a git commit in this repo with the harness report linked in the commit body. `git log claude-system/` *is* the team's constitutional history.

---

## 8. Token consumption tracking (extending phase 6)

### 8.1 Already shipped
Per-invocation JSONL, per-session summaries, rotation, `metrics.{sh,ps1}` with per-agent breakdowns and `BASELINE.md`.

### 8.2 Additions

- **`budgets.yaml`** — per-task-class and per-agent budgets, versioned in this repo. The harness fails changes that breach them; the Stop hook warns live sessions.
- **Cost regression detection** — `metrics.sh --trend` compares 7-day rolling median tokens-per-class against `BASELINE.md`; >20% drift prints a warning at session start (via SessionStart hook, one line).
- **Attribution of savings** — when the toolsmith ships a script or the evaluator merges a change, the record includes the task classes it should affect, so `--trend` can attribute deltas to changes (correlational, but enough to catch "improvement made things worse").
- **Cache-hit accounting** — record cache-read vs. fresh input tokens separately; a cheap prompt is one that caches, and agent-file edits that break the stable prefix show up here (gap G2).

---

## 9. Gap analysis — what was asked vs. what's optimal

Things the request didn't name that materially affect efficiency, performance, or both. Each is folded into the roadmap.

**G1 — Task-size router (biggest single saving).** A 13-agent pipeline on a typo fix is waste of the first order. The XS/S/M/L classifier in §4 means small tasks bypass most of the team. Expected effect: majority of real-world prompts are XS/S; pipeline cost concentrates where judgment matters.

**G2 — Prompt-cache discipline.** Token *count* is not token *cost*. Agent files must keep a stable prefix (identity, rules) with volatile content (memory brief, task) appended last, so cached-input pricing applies. The harness's agentlint checks section ordering; telemetry's cache-hit accounting (§8.2) verifies it live. An "optimization" that shuffles a system prompt can raise real cost while lowering token counts — only cache-aware accounting catches this.

**G3 — Eval stochasticity is the default, not the exception.** Single-run A/B verdicts on LLM behavior are noise. Hence N-run comparisons with confidence intervals and an explicit INCONCLUSIVE verdict (§6.3). Without this the team will "learn" from coin flips.

**G4 — Overfitting to the eval suite.** A self-improving team optimizes whatever is measured. The `holdout/` set is never consulted when tuning and is run only at release points; a candidate that wins on golden but slips on holdout is overfit and rejected. Golden tasks rotate quarterly.

**G5 — Drift between repo and installed system.** People hot-fix `~/.claude/agents/` in place; then repo, harness, and reality disagree. The SessionStart hook does a fast checksum of installed agents vs. the repo manifest and prints a one-line drift warning. The installer remains the only sanctioned write path (§7.2).

**G6 — Memory decay.** Append-only memory grows into a token tax on every session. The librarian gets a decay policy: facts carry a last-confirmed date; unreferenced project facts expire to an archive after 90 days; `memlint.py` reports bloat. Memory brief stays ≤200 tokens forever.

**G7 — Runaway-cost circuit breaker.** Self-directed agent loops occasionally spiral. The 3×-baseline session flag and per-class autonomous-mode disable (§7.5) bound the blast radius of any bad self-modification that slips past the harness.

**G8 — Versioning + rollback as first-class.** Because `claude-system/` is git-versioned and the installer is idempotent, rollback = `git revert` + reinstall. The live-telemetry watch (§6.5) makes rollback *triggered*, not just possible. No parallel version scheme needed — git is the version scheme.

**G9 — Security review of the hook surface.** Hooks execute shell on every session for every project, including untrusted clones. Rules: hooks never execute repo-controlled content; project-memory files are read as data, never sourced; hooklint enforces both. The scrutineer reviews any hook change regardless of task size.

**G10 — Don't over-agent.** The optimal team is the smallest one that covers the judgment surface. Several "roles" here are deliberately *not* separate agents: security review folds into the scrutineer; performance analysis into quant; release notes into docs-writer. Every new agent costs a routing decision in the orchestrator (paid on every task) — the roster only grows when telemetry shows an existing agent overloaded across distinct judgment types.

**G11 — Judge cost.** LLM-judged rubrics can cost more than the task under test. Deterministic assertions run first and short-circuit; the LLM judge scores only survivors, on haiku, with the rubric asking for scores only (no prose).

---

## 10. Roadmap

Phases 1–6: ✅ shipped (see `plans/`). New phases, each independently shippable and verified on a clean install:

| # | Phase | Delivers | Depends on |
|---|---|---|---|
| 7 | Toolbelt + toolsmith | `scripts/toolbelt/` seed scripts + tests, toolsmith agent, offload rules in agent prompts, INDEX loading | — |
| 8 | Harness: static layer | `harness/` skeleton, agentlint, hooklint, installer smoke test, CI wiring on this repo | 7 |
| 9 | New specialists, wave 1 | data-engineer, docs-writer, scrutineer + orchestrator routing table update + XS/S/M/L router (G1) | 8 (lint gates their files) |
| 10 | Harness: behavioral + A/B | golden tasks, rubrics, `ab.py`, evaluator agent, verdict policy, skill-builder judge hook-in | 8, 9 |
| 11 | New specialists, wave 2 | design-lead, strategist, quant + gate-escalation rules (§7.4) | 10 (their files must pass the harness) |
| 12 | Cost hardening | `budgets.yaml`, `--trend`, cache-hit accounting, drift check (G5), circuit breaker (G7), memory decay (G6) | 10 |
| 13 | Evolution loop live | proposer/approver hook enforcement (§7.2), live-telemetry watch + auto-revert (§6.5), holdout rotation (G4) | 11, 12 |

## 11. Acceptance criteria (whole system)

1. Clean install on macOS and Windows yields the full 13+ agent team, toolbelt, and harness-verified agent files.
2. An XS task (typo fix) completes with ≤2 agent invocations; an L task traverses strategist → … → docs-writer with every gate firing.
3. `harness/run.sh` on an unmodified tree passes static + behavioral layers.
4. Editing an agent file to be deliberately worse (e.g. delete its output cap) is caught: agentlint FAIL or A/B FAIL with a confidence-bounded delta.
5. A repeated deterministic pattern (e.g. counting matches across files) results, within one retrospective cycle, in a toolbelt script and a measurable token drop for that class.
6. `metrics.sh --trend` reports per-class cost drift vs. baseline, split by cache-read vs. fresh input tokens.
7. A session exceeding 3× class baseline is flagged at Stop; a third consecutive flag disables autonomous mode for that class.
8. `git log claude-system/` shows every team change with its harness verdict; `git revert` + reinstall restores any prior team state.
