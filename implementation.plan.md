# Ombudsman — The Implementation Plan

> **Status: authoritative.** This is the single plan for the Ombudsman multi-agent system.
> It was derived from two independently-audited source plans —
> `plans/archive/final.implementation.plan.md` and `plans/archive/gpt.implementation.plan.md` —
> which are retained only as historical record. Where the two disagreed, the resolution is
> recorded in §2. Everything in §§3–10 is binding; §11 tracks what has shipped.

---

## 1. Requirements

1. An expansive multi-agent team covering **front end, back end, data, documentation,
   design, strategy, computation, scrutinization, checks and balances, internal team
   memory, and token optimization**.
2. **Deterministic work offloaded to scripts** — agent tokens are never spent on work a
   script can do.
3. The team can **self-test its own skills and agent files** (scripts + eval harness,
   with Claude Code's skill-building evaluation flow as an optional extra judge).
4. A **comprehensive testing harness** with **accurate token-consumption tracking**.
5. **Gap analysis** folded in (§9).
6. **PR and CI hooks** so every change is machine-tested before end use (§8).
7. **CRITICAL — platform parity.** Works identically on **Claude Code mobile
   (iOS/Android), web, desktop, and CLI**, on any project, with **no installation
   scripts** — adoption is copying the `.claude/` directory.

Requirement 7 is the forcing constraint. Nothing under `~/.claude/` exists in the cloud
VMs that back mobile/web sessions; the only distribution channel with identical semantics
on every surface is configuration **committed to the repo itself**.

## 2. Merge resolutions (where the source plans differed)

| Question | final.plan said | gpt.plan said | Resolution |
|---|---|---|---|
| Harness location | repo-level `harness/` | `.claude/evals/` | **`harness/`** — dev asset; adopters copy a lean `.claude/`. Lints + toolbelt tests ship inside `.claude/scripts/` so adopters can still self-check. |
| Entry point | orchestrator persona via SessionStart hook | explicit `/ombudsman` command | **Both.** The SessionStart hook injects the persona automatically; `.claude/commands/ombudsman.md` is the stable explicit entrypoint and the documented fallback is a prompt starting `ombudsman:`. |
| Regression response | `git revert` automatically | detection opens an issue/revert-PR; humans merge | **gpt.plan.** No autonomous merge/revert. Detection produces a reviewable remediation. |
| A/B trial count | fixed N=3/N=5 | adaptive 3→5→9 under a spend cap | **gpt.plan** — adaptive, with PASS/FAIL/INCONCLUSIVE verdicts and Wilson intervals. |
| Routing | XS/S/M/L by size | size + **risk promotion** | **Both**: size classes, and risk promotes (auth, secrets, migrations, destructive ops, CI config, agent/hook/memory changes get ≥M review regardless of size). |
| CI selection | run evals when labeled | changed-component map picks affected cases | **Both**: label-gating controls spend; the changed-component map picks which cases run. |
| Roster metric | 18 agents listed as deliverable | roster size must never be a success metric | **gpt.plan** — the 18 definitions ship, but acceptance is measured on coverage + routing behavior, never on count. |
| Degradation | not specified | explicit capability-degradation contract | **gpt.plan** — degradations must be visible, never silent (§3.4). |

Everything else in the two plans was already convergent and is restated below.

## 3. Architecture

### 3.1 Canonical layout — the product is `.claude/`

```
.claude/                          # ← copy this directory to adopt; no installer
├── settings.json                 # hook registrations ($CLAUDE_PROJECT_DIR-relative), permission denies
├── .gitignore                    # runtime state/metrics stay out of git
├── VERSION
├── agents/                       # 18 agent definitions (§4)
├── commands/
│   ├── ombudsman.md              # stable invocation entrypoint
│   └── forget-rule.md            # archive a wrongly-learned rule
├── hooks/                        # ALL hook logic in stdlib Python 3
│   ├── _common.py                # shared: no-fail wrapper, root self-derivation
│   ├── session_start.py          # persona + gate-state injection, memory seeding
│   ├── user_prompt_submit.py     # correction detector → retro_needed
│   ├── pre_tool_use.py           # Task-dispatch activity tracking
│   ├── subagent_stop.py          # descoped telemetry (only fields that exist)
│   └── stop.py                   # auditor/retro gate + session summary
├── scripts/
│   ├── state.py                  # gate-state helper (writes .ombudsman/state)
│   ├── verify.py                 # whole-suite verify gate (discovers + runs project tests)
│   ├── metrics.py                # telemetry reporting + cost estimates
│   ├── transcript.py             # stream-json transcript parser (the measurement layer)
│   ├── agentlint.py              # static agent-file checks
│   ├── hooklint.py               # static hook-safety checks
│   ├── memlint.py                # memory structure/bloat report
│   ├── pricing.json              # corrected pricing table
│   └── toolbelt/                 # deterministic offload scripts + INDEX.md + tests/
└── (read-only at runtime — see §3.2 rule 5)

.ombudsman/                       # writable runtime home, created lazily by the hook
├── memory/                       # project-tier memory (committed, librarian-owned)
├── state/                        # gate state, activity, retro bundles (gitignored)
└── metrics/                      # sessions.jsonl, baseline.json (gitignored)
```

Repo-level (not copied by adopters): `harness/`, `.github/`, `README.md`, this plan,
`plans/` history.

### 3.2 Portability rules (hard requirements)

1. **All hook/script logic is Python 3 standard library.** No bash/PowerShell logic;
   no third-party imports.
2. **No path assumes `~/.claude/`.** Every hook/script self-derives the project root:
   its own file location (`<root>/.claude/hooks/x.py`) first, then payload `cwd` /
   `git rev-parse --show-toplevel`. Env vars are never relied on to propagate between
   hook processes (verified defect in the old system).
3. **No hook may hard-fail.** Every hook body runs inside a catch-all wrapper; an
   exception can never block a session or suppress context injection.
4. **No interactive steps** anywhere in the runtime path — mobile sessions are headless.
5. **All writable runtime data lives in `.ombudsman/`, never `.claude/`.**
   Verified platform constraint: Claude Code's sensitive-file protection blocks
   agent writes under `.claude/` in headless sessions and allow-rules cannot
   override it — so `.claude/` is read-only config (which the platform guard
   then protects for us: no agent can silently edit its own definition), and
   the SessionStart hook lazily creates `.ombudsman/` with `memory/`
   (committed; rides the session branch/PR) plus `state/` and `metrics/`
   (gitignored). Adoption still copies only `.claude/`.
6. Windows hook invocation (`python3` vs `py`) is an open risk verified by the Windows
   CI job, not by convention.

### 3.3 Adoption (copy-over)

- macOS/Linux/cloud: `cp -r omsbudsman/.claude <project>/`
- Windows: `robocopy omsbudsman\.claude <project>\.claude /E`
- No clone (mobile-friendly): download repo ZIP → extract → copy `.claude/` in.
- Existing `.claude/`: copy the subdirectories wholesale (namespaced, no collisions);
  hand-merge `hooks` + `permissions` keys of `settings.json` (README shows the block;
  `toolbelt/jsonmerge.py` automates it).
- Plugin/marketplace packaging is a sanctioned later phase; copy-over remains primary.

### 3.4 Capability-degradation contract

Equal performance means **behavioral parity**, not identical internals. On every surface:
same routing, same agent prompts, same gates, memory reads. Allowed degradations, always
visible (stated in the session summary), never silent: no global memory tier when
`~/.claude/` is absent; no persistent metrics on ephemeral storage; behavioral evals
deferred to CI when the surface can't run headless `claude -p`.

## 4. Team

### 4.1 Roster

Core (always routed): `orchestrator` (inherit), `researcher` (haiku), `planner` (sonnet),
`qa-reviewer` (sonnet), `auditor` (sonnet), `librarian` (haiku), `retrospective` (sonnet).

Specialists (loaded by routing need): `frontend-engineer`, `backend-engineer`,
`test-engineer`, `data-engineer`, `docs-writer` (haiku), `design-lead`, `strategist`
(opus, ≤1 invocation, L-tasks only), `quant`, `scrutineer`, `toolsmith`, `evaluator`
(all sonnet unless noted).

Coverage: front end → frontend-engineer (+design-lead upstream); back end →
backend-engineer; data → data-engineer; documentation → docs-writer; design →
design-lead; strategy → strategist; computation → quant + toolbelt; scrutinization →
scrutineer; checks & balances → qa-reviewer + auditor + scrutineer + hook/CI gates;
memory → librarian (+retrospective); token optimization → transcripts + budgets +
evaluator; deterministic offloading → toolsmith + toolbelt; self-testing → evaluator +
harness.

Deliberately not separate agents: security review folds into scrutineer, performance
analysis into quant, release notes into docs-writer. The roster grows only when telemetry
shows an agent overloaded across distinct judgment types.

### 4.2 Tool scoping (checks and balances are structural)

- researcher: `Read, Grep, Glob` only (no shell).
- planner: `Glob` (benign minimal grant — omitting `tools:` inherits everything).
- qa-reviewer: `Read, Grep, Glob, Bash` — no `Task` (brief arrives in the payload).
- auditor: keeps `Task` for documented researcher/test-engineer escalation.
- scrutineer/design-lead/strategist/quant/evaluator: read-only tool sets.
- Engineers: full edit tools; destructive verbs (`git push`, `rm -rf`, hard reset,
  package installs) denied via `.claude/settings.json` permissions — which now ship to
  every adopter.
- No agent reviews its own work; no agent both proposes and approves a self-modification;
  no agent can raise its own budget.

### 4.3 Routing (task size + risk promotion)

- **XS** (typo, one-liner, factual q): direct answer or single specialist; ≤2 agent calls.
- **S**: researcher optional → engineer → qa-reviewer → auditor (auditor only when files changed).
- **M**: researcher → planner → specialist(s) ∥ → qa-reviewer → `verify.py` → auditor;
  scrutineer when security/data/concurrency is touched.
- **L**: strategist → researcher → planner → design-lead (if UI) → specialists ∥ →
  qa-reviewer → scrutineer → `verify.py` → auditor → docs-writer.
- **Risk promotion**: auth/secrets/migrations/destructive ops/CI config/agent-hook-memory
  changes get at least M-level review regardless of size.
- Parallel dispatch only when work items share no files. Gates return work at most
  twice; the third failure escalates to the user with a diagnosis.

## 5. Deterministic offloading — the toolbelt

`.claude/scripts/toolbelt/` ships `INDEX.md` + stdlib-Python scripts, each with a test:
`count.py`, `jsonmerge.py`, `diffstat.py`, `csvstat.py`, `todo_scan.py`. Plus the
system helpers in `.claude/scripts/`: `state.py` (kills hand-written JSON heredocs),
`verify.py` (whole-suite gate at zero model cost), `transcript.py`, `metrics.py`,
`memlint.py`.

Hard rules (prompt-enforced, eval-checked): arithmetic beyond one operation → script;
exhaustive enumeration → script; format conversion → script; verbatim transformation of
>20 lines → script/editor tool, never retyped.

The offloading loop: telemetry tags task classes → retrospective/toolsmith spot repeat
deterministic patterns (≥3 occurrences) → toolsmith writes script + test + INDEX line →
librarian records the rule → harness gains a case asserting script-invocation → metrics
confirm the drop, or the rule is wrong and a retrospective entry says so.

## 6. Memory

- **Project tier (primary, committed):** `.ombudsman/memory/` — facts, decisions,
  `mistakes/<topic>.md` prevention rules. In cloud sessions, changes ride the session
  branch/PR. This is the only tier that exists on every surface.
- **Global tier (optional desktop enhancement):** `~/.claude/memory/` when present;
  absence never reduces correctness (§3.4).
- **Decay:** entries carry `Last seen`; unreferenced project facts archive after 90 days;
  `memlint.py` reports bloat; the session brief stays ≤200 tokens; librarian is the sole
  writer; raw user prompts are untrusted and never promoted directly into durable rules.

## 7. Token tracking — accurate by construction

**Source of truth: `claude -p --output-format stream-json --verbose` transcripts**,
parsed by `.claude/scripts/transcript.py` (shared by harness and metrics). Per-message
`usage` blocks give real input/output/cache-read/cache-creation counts, model per call,
Task routing, and `BLOCKED:` returns. The SubagentStop hook payload carries **no usage
fields**, so runtime JSONL records only fields that actually exist and is never used as
a measurement source (descoped by design, not folklore).

On that base: `harness/budgets.json` (per-class/per-agent budgets, versioned, breaches
fail the harness); cache-hit accounting (agentlint checks stable-prefix section
ordering); `metrics.py --trend` vs committed baseline (>20% drift warns at SessionStart);
circuit breaker (session >3× class baseline flagged at Stop; three consecutive flags
disable that class's autonomous mode pending review); corrected `pricing.json`.

## 8. Self-testing harness + CI

### 8.1 Layers

| Layer | Checks | Cost | When |
|---|---|---|---|
| **Static** | agentlint, hooklint, settings/JSON validation, toolbelt + hook + script unit tests, copy-over lifecycle test | 0 tokens | every push/PR, 3-OS matrix |
| **Behavioral** | golden cases headless via `claude -p` against the fixture; deterministic graders first, haiku judge only for quality dimensions | $ | PRs touching `.claude/**` with the `run-evals` label; weekly drift run |
| **Comparative (A/B)** | base vs candidate, adaptive trials 3→5→9 under spend cap, Wilson CI; PASS / FAIL / INCONCLUSIVE | $$ | before adopting any self-modification |
| **Holdout** | never used for tuning; release gate only | $$ | releases + routing/judge/budget changes |
| **Live** | post-merge telemetry watch; regression → issue/revert-PR (human merges) | 0 | continuous |

### 8.2 Isolation (non-negotiable)

The system under test installs into the **fixture repo's `.claude/`** — which *is* the
distribution path, so every harness run regression-tests mobile compatibility for free.
Fixture copied fresh to a temp dir per trial; the harness self-test asserts zero writes
to the real `~/.claude`. Runner uses a scoped `--settings` profile, never
`--dangerously-skip-permissions`. No gate bypass envs: the gate loop is part of the
behavior under test. Hard per-trial wall-clock timeout.

### 8.3 Grading contract

Assertion severities: `critical` (any failure fails the case), `gate`
(majority-of-trials), `soft` (informational), `budget` (fails when cost regresses with
quality unchanged). Acceptance: no new critical failure; gate pass-rate drop ≤5 pts;
target behavior adopted in ≥⅔ trials; median tokens not regressed >10% unless quality
materially improves; token deltas <10% are labeled noise. Skill-builder scoring is an
optional, version-detected, nonblocking extra judge — never the authority.

### 8.4 CI/PR policy

- `ci.yml`: on every push/PR — full static layer on ubuntu/macos/windows, including the
  copy-over lifecycle test (this is the Windows §3.2(6) verification).
- `evals.yml`: behavioral/A-B on PRs touching `.claude/**` when labeled `run-evals`
  (spend authorization); changed-component map selects affected cases and reports what
  was skipped and why; weekly scheduled drift run; fork PRs get deterministic checks
  only. Requires `ANTHROPIC_API_KEY` secret; posts the verdict table on the PR.
- Branch protection on `main`: PRs only; `ci` required; agent/skill PRs must carry the
  evals label; human approval required for agent/hook/evaluator/budget/workflow changes.
- Proposer ≠ approver enforced by the platform: self-modification PRs merge only with a
  green evaluator report; `git log .claude/` is the team's constitutional history;
  `git revert` (via a PR) is the rollback mechanism.
- **No local git hooks** — an install step that mobile never runs; CI carries all
  pre-merge testing.

## 9. Gap register

| # | Gap | Handled |
|---|---|---|
| G1 | Task-size router — 13-agent pipeline on a typo is first-order waste | §4.3 |
| G2 | Prompt-cache discipline — token count ≠ token cost | §7, agentlint |
| G3 | Eval stochasticity — single-run verdicts are coin flips | §8.1, adaptive trials |
| G4 | Overfitting to the suite — holdout set, rotation | §8.1 |
| G5 | Drift between repo and live copy — manifest-hash staleness warning | §7 |
| G6 | Memory decay | §6 |
| G7 | Runaway-cost circuit breaker | §7 |
| G8 | Versioning/rollback — git is the scheme; revert-PR is the rollback | §8.4 |
| G9 | Hook security surface — hooks run on every session incl. untrusted clones | §10 |
| G10 | Don't over-agent — smallest team covering the judgment surface | §4.1 |
| G11 | Judge cost — deterministic assertions short-circuit; haiku judge | §8.1 |
| G12 | Global-install architecture is invisible on mobile | §3 |
| G13 | Local git hooks are an install step | §8.4 |
| G14 | Autonomous rollback is dangerous — detection yes, merge authority human | §2 |
| G15 | Silent degradation on constrained surfaces | §3.4 |

## 10. Security requirements

1. Read-only agents get Read/Glob/Grep, no unrestricted shell.
2. Engineers get the narrowest feasible grants; destructive verbs denied in settings.
3. Hooks never execute repository-controlled text; memory read as data, never sourced.
4. All JSON via `json.dumps`; subprocess via argv arrays; no `shell=True`, no `eval`.
5. Atomic writes (temp file + replace); UTF-8; LF/CRLF tolerant.
6. Fixture runs: network denied, temp dirs only, no writes to real user home.
7. CI secrets unavailable to fork PRs; `hooklint` enforces the above statically;
   scrutineer reviews every hook change.
8. Raw user text (`retro_prompts`) is untrusted data in every prompt that embeds it.

## 11. Phases

| # | Phase | Delivers | Status |
|---|---|---|---|
| P1 | Portability re-base | `claude-system/`+installers dissolved into repo `.claude/`; Python hooks (self-derived paths, no-fail); README copy-over docs | **this PR** |
| P2 | Measurement truth | pricing fix, telemetry descope, `transcript.py` shared parser | **this PR** |
| P3 | Harness core + CI | lints, unit tests, lifecycle test, fixture, golden cases, budgets, `ci.yml`/`evals.yml`, PR template | **this PR** (static+lifecycle+behavioral runner; A/B compare runner is P10) |
| P4 | Toolbelt + offloads | seed scripts + tests, `state.py`, toolsmith agent, hard rules in prompts | **this PR** |
| P5 | Security + comms fixes | tool-grant scoping, deny lists, `verify.py` gate, JSON-relay-via-file, auditor corroboration | **this PR** |
| P6–P7 | Specialists | all 8 new agents + XS/S/M/L+risk router in orchestrator | **this PR** |
| P8 | Cost hardening | budgets.json, `--trend`, circuit breaker, memory decay | **this PR** (baseline capture continues post-merge) |
| P9 | Memory persistence | committed project tier riding session branches | **this PR** |
| P10 | Evolution loop live | A/B compare runner, holdout rotation, live-watch + revert-PR automation, skill-builder judge | follow-up PR |
| P11 | Plugin packaging | optional marketplace distribution | follow-up PR |

## 12. Acceptance criteria

1. Copying `.claude/` into a fresh project on macOS/Linux/Windows — and opening it in a
   Claude Code **mobile/cloud session** — yields the full team with hooks firing. No
   installer executed.
2. Invocation via `/ombudsman`, the auto-injected persona, or the `ombudsman:` fallback.
3. XS ≤2 agent calls; L traverses strategist→…→docs-writer with every gate firing.
4. `python3 harness/run.py --static` passes on an unmodified tree; a deliberately broken
   agent/hook is caught; a harness run writes nothing to the real `~/.claude`.
5. Transcript-derived token counts are non-null, split cache-read vs fresh.
6. Repeated deterministic patterns become toolbelt scripts with measured drops.
7. Sessions >3× class baseline are flagged at Stop.
8. CI blocks `.claude/` PRs failing static checks on any OS; agent/skill PRs need an
   evaluator verdict.
9. No agent can merge, silently revert, raise its own budget, or approve its own change.
10. Mobile release checklist (manual, release-gating): from the iOS/Android app on a
    project containing the copied `.claude/`, an S-task flows researcher→engineer→QA→
    auditor with a non-null verdict and memory changes on the session branch.
