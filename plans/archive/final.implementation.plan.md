# Final Implementation Plan — Portable, Self-Testing Multi-Agent Team for Claude Code

> **Status: implementation-ready.** This is the single authoritative plan. It merges and
> supersedes `first.plan.md` (plan 07-R, the audit + eval-harness plan) and
> `fable.multi.agent.plan.md` (the expansive team plan), both of which were independently
> audited against the original criteria before merging — see **Appendix A** for the audits
> and the comparison that produced this document. The phase plans in `plans/` remain as
> historical record of the implemented core (phases 1–7).

---

## 1. Requirements (what this plan must deliver)

From the original criteria:

1. A comprehensive, expansive multi-agent team covering **front end, back end, data,
   documentation, design, strategy, computation, scrutinization, checks and balances,
   internal team memory, and token optimization**.
2. **Deterministic work offloaded to scripts** — agent tokens are never spent on work a
   script can do.
3. The team can **self-test its own skills and agent files** — a mix of self-written
   scripts/tests plus Claude Code's skill-building evaluation flow as a
   confidence signal on how effective an update was.
4. A **comprehensive testing harness** that keeps the team effective and efficient as it
   evolves, with **accurate token-consumption tracking**.
5. **Gap analysis** — differences between what was asked and what is optimal, folded into
   the plan (see §4 principles, §13 gap register).

New, added in this revision:

6. **PR and CI hooks** so every change to the system is tested as far as automation can
   take it before end use (§11).
7. **CRITICAL — platform parity.** The system must work and perform equally well on
   **Claude Code mobile (iOS/Android), desktop, and CLI**, be **invocable from the mobile
   app**, and be **usable on any project**. The code that invokes the team ships in the
   **`.claude/` directory** of this repo, works on iOS, Android, Windows, Linux, and
   macOS, with **no installation scripts** — adoption is an easy copy-over of files (§2).

Requirement 7 is the forcing constraint: it invalidates the `~/.claude/`-global
architecture that both source plans (and phases 1–7) assumed, so it is designed first and
everything else is built to fit it.

---

## 2. Distribution model — repo-committed `.claude/`, no installers

### 2.1 Why the global install dies

Verified finding from plan 07-R (A5): **nothing under `~/.claude/` carries into Claude
Code cloud sessions**, which is what the iOS/Android apps (and claude.ai/code) actually
drive — each mobile session is a fresh Linux VM with a fresh clone of the repo. An
installer-based system is therefore *structurally invisible on mobile*. The only
distribution mechanism with identical semantics on every surface is configuration
**committed to the repo itself**:

| Surface | Runs where | Sees `~/.claude/`? | Sees repo `.claude/`? |
|---|---|---|---|
| iOS / Android app | Cloud Linux VM, fresh clone | ❌ | ✅ |
| claude.ai/code (web) | Cloud Linux VM, fresh clone | ❌ | ✅ |
| CLI / desktop — macOS, Linux | Local machine | ✅ (but not portable) | ✅ |
| CLI / desktop — Windows | Local machine | ✅ (but not portable) | ✅ |

### 2.2 Canonical layout

The **entire runtime system** lives in `.claude/` in this repo. `claude-system/` is
dissolved into it; `install.sh`, `install.ps1`, `uninstall.sh`, `uninstall.ps1` are
**removed** (requirement: no installation scripts). The repo-level `harness/` and
`plans/` directories are development assets and are *not* part of the copy-over.

```
.claude/                          # ← the product; copy this directory to adopt
├── settings.json                 # hook registrations ($CLAUDE_PROJECT_DIR-relative), permissions
├── agents/                       # 18 agent definitions (§5)
├── skills/                       # team skills (e.g. /team-status, /evals)
├── hooks/
│   ├── session_start.py          # all hook LOGIC in portable python3
│   ├── user_prompt_submit.py
│   ├── subagent_stop.py
│   ├── pre_tool_use.py
│   ├── stop.py
│   └── shims/                    # thin per-OS launchers only if §2.4 testing requires them
├── scripts/
│   ├── toolbelt/                 # deterministic offload scripts + INDEX.md + tests/ (§7)
│   ├── state.py                  # gate-state helper (set-qa / set-auditor / get)
│   ├── verify.py                 # whole-suite verify gate (runs project build/test)
│   └── metrics.py                # telemetry reporting (replaces metrics.sh/.ps1)
└── memory/                       # project-tier memory (committed; §8)
    └── INDEX.md
```

### 2.3 Copy-over adoption (the "easy way to copy files")

To adopt the team on any project, copy one directory. Documented in the README, no
scripts:

- macOS/Linux/cloud: `cp -r /path/to/omsbudsman/.claude <project>/`
- Windows: `robocopy \path\to\omsbudsman\.claude <project>\.claude /E`
- No local clone (mobile-friendly): download the repo ZIP from GitHub, extract, copy
  `.claude/` in.
- Project already has a `.claude/`: merge rule is documented — copy `agents/`, `hooks/`,
  `scripts/`, `skills/`, `memory/` subdirectories wholesale (they are namespaced and
  won't collide), and hand-merge the `hooks` and `permissions` keys of `settings.json`
  (the README shows the exact JSON block to paste).

A future **plugin/marketplace packaging** is the sanctioned "phase 2" distribution path
for multi-repo fleets (verified to install at cloud session start), but it depends on
network policy allowing the marketplace source, so the copy-over path remains primary
and must always work.

### 2.4 Portability rules (hard requirements on all shipped code)

1. **All hook and script logic is Python 3** — the one runtime present on cloud VMs,
   macOS, Linux, and (via any standard install) Windows. No bash-only or
   PowerShell-only logic. `.sh`/`.ps1` survive only as ≤3-line shims if hook-command
   invocation on some surface requires them (§2.5).
2. **No path may assume `~/.claude/`.** Hook commands are registered as
   `$CLAUDE_PROJECT_DIR/.claude/hooks/<name>` and every script self-derives its roots
   from the hook stdin payload `cwd` / `git rev-parse --show-toplevel` — never from
   inherited env vars (plan 07-R A1.1: env vars do not propagate between hook processes;
   what must reach subagent Bash goes through `$CLAUDE_ENV_FILE`).
3. **No hook may hard-fail.** All hooks wrap their body so an exception can never
   suppress the context injection or block the session (plan 07-R A1.2).
4. **Every shipped file is exercised by CI on Linux, macOS, and Windows** (§11) — Windows
   parity is verified by machines, not by convention.

### 2.5 Open risk to verify in phase P1 (tracked, not assumed)

Hook-command invocation on **native Windows** (outside Git Bash) must be verified: the
registered command string (`python3` vs `py`/`python`, `$CLAUDE_PROJECT_DIR` expansion)
is confirmed working in the Windows CI job before the `.sh`/`.ps1` shims are deleted. If
a shim is needed, it stays — but the logic it launches is still the shared Python.

### 2.6 What "equal performance on mobile" additionally requires

- **Memory must survive ephemeral VMs** (§8): project-tier memory is committed to the
  repo; in cloud sessions the Stop-hook flow stages `.claude/memory/` changes on the
  session branch so they ride the PR. Without this, the team is amnesiac on mobile —
  a direct parity break.
- **No interactive steps anywhere** in the runtime path (no prompts, no `read`, no
  first-run wizards): mobile sessions are headless.
- **The eval harness fixture uses exactly this repo-`.claude/` mechanism** (§10), so the
  distribution path is exercised by every harness run — mobile compatibility is
  regression-tested for free.

---

## 3. Design principles

1. **Portability is architecture, not packaging.** If a feature can't work from a fresh
   clone of `.claude/` on a cloud VM, it doesn't ship (or ships as an explicitly
   optional desktop enhancement, §8.2).
2. **The orchestrator's context is the most expensive real estate in the system.** It
   routes and synthesizes; it never reads files, never pastes code, never does work a
   specialist or a script can do.
3. **Deterministic work goes to scripts, not agents.** If a task has one correct output
   for a given input, an agent may *invoke* a script but never *reproduce* its work
   token-by-token. Agents are for judgment; scripts are for computation.
4. **Every agent has a budget and every budget is measured** — from transcripts, the
   only accurate source (§9), not from folklore.
5. **The team modifies itself only through the harness.** An edit to an agent file or
   skill that hasn't passed the eval suite is a bug, not an improvement.
6. **Checks and balances are structural.** No agent reviews its own work; no agent both
   proposes and approves a self-modification; gates are enforced by hooks and CI, not
   by convention.
7. **Memory is curated, not accumulated.** The librarian prunes as aggressively as it
   appends; unbounded memory is a token tax on every future session.

---

## 4. Correctness, security, and communication fixes (land before anything new)

Carried from plan 07-R Part A, re-based onto the `.claude/`-first layout. These are
prerequisites: the harness fixture depends on self-derived paths, and every later
claim of savings depends on real measurement.

**Correctness**
- **A1.1 Path self-derivation + env-file plumbing** — as §2.4(2). The project memory
  tier is effectively dead today because `LIBRARIAN_PROJECT_ROOT` never reaches the
  librarian; this fix revives it.
- **A1.2 No-fail hooks** — as §2.4(3); today a Python exception silently kills the
  orchestrator persona + gate-state injection.
- **A1.3 Pricing table** — correct Opus pricing ($5/$25 per MTok, not $15/$75) and add
  current model rows in `pricing.json`/`metrics.py`. Model-ID migrations are tuning
  changes gated by the harness, not correctness fixes.
- **A1.4 Telemetry descope** — the SubagentStop payload carries **no usage fields**;
  stop recording perpetual nulls. Runtime records keep only fields that exist
  (session_id, timestamp, agent-name/BLOCKED parsed from `last_assistant_message`);
  all token/model/routing measurement moves to transcripts (§9).
- *(A1.5 installer idempotency is moot — installers are removed. Its successor is the
  documented settings-merge rule in §2.3 plus the copy-over smoke test in CI.)*

**Security**
- Scope "read-only" agents' tools for real: researcher/qa-reviewer lose unrestricted
  Bash (allow-listed read-only commands or Read/Grep/Glob only).
- Engineers get a project-level `deny` list for destructive verbs (`rm -rf`,
  `git push`, `git reset --hard`, network fetches, package installs unless the step
  authorizes them) in `.claude/settings.json` — which now ships to every adopter.
- Hooks never execute repo-controlled content; memory files are read as data, never
  sourced/eval'd. `retro_prompts` (raw user text) is treated as untrusted data in the
  retrospective prompt. All JSON built with `json.dumps`, never string concatenation.
- `hooklint` (§10) enforces the above statically; the scrutineer reviews every hook
  change regardless of task size.

**Inter-agent communication**
- **Planner tool grant:** `tools: Glob` (benign minimal grant) — omitting `tools:`
  inherits everything; an empty list fails to launch.
- **qa-reviewer** loses `Task` (brief passed in payload); **auditor** keeps `Task` for
  documented researcher escalation.
- **Verify gate:** deterministic `scripts/verify.py` runs the project's build/test
  after the last QA pass; the orchestrator feeds its verbatim result to the auditor as
  `VERIFY RESULT`; a failing result is an automatic `revise`. Closes the
  "nobody checks parallel changes work together" and "no whole-suite gate" holes at
  zero model cost.
- **JSON relay via file:** retrospective writes its payload to a state-dir file; the
  orchestrator passes the *path*; the librarian reads it. Kills silent
  `BLOCKED: malformed` drops from hand-copied JSON.
- **Auditor corroboration:** when COVERAGE would rest on an uncorroborated engineer
  claim, the auditor dispatches the researcher.
- **Stale-brief note:** MEMORY HINTS refresh next session; documented in
  `orchestrator.md`.

---

## 5. Team roster

### 5.1 Existing core (implemented, phases 1–7)

| Agent | Role | Model tier |
|---|---|---|
| `orchestrator` | Main session persona. Routes, delegates, synthesizes. Never touches files. | inherits |
| `librarian` | Internal team memory: curates, prunes, dedupes, routes facts to tiers. | haiku |
| `retrospective` | Post-mortems corrections into prevention rules; amplifies repeats. | sonnet |
| `researcher` | Read-only investigation; returns `path:line` refs, never contents. | haiku |
| `planner` | Turns research into ≤30-line ordered plans. | sonnet |
| `frontend-engineer` | **Front end**: UI, client logic, styling, accessibility. | sonnet |
| `backend-engineer` | **Back end**: server, APIs, services, infra config. | sonnet |
| `test-engineer` | Tests, fixtures, harnesses for product code. | sonnet |
| `qa-reviewer` | Gate 1: functional review before the orchestrator accepts work. | sonnet |
| `auditor` | Gate 2: verifies the *original request* was met before handback. | sonnet |

### 5.2 New specialists

| Agent | Role | Model tier | Notes |
|---|---|---|---|
| `data-engineer` | **Data**: schemas, migrations, ETL, query optimization, validation, analytics pipelines. | sonnet | Peers with backend-engineer; owns anything where the deliverable is data shape/movement. |
| `docs-writer` | **Documentation**: READMEs, API docs, changelogs, doc comments, runbooks. Runs *after* auditor approval so docs describe what shipped. | haiku | High-volume/low-judgment → cheapest tier; escalates to sonnet for architecture docs only. |
| `design-lead` | **Design**: UX flows, component/API ergonomics, design-system adherence. Consulted *before* frontend work (cheap) rather than reviewing after (expensive rework). | sonnet | Produces constraint lists (≤20 bullets), never mockups-as-prose. |
| `strategist` | **Strategy**: multi-session/ambiguous work — clarifies goals, sequences milestones, flags scope creep, build-vs-defer. | opus (capped) | Only agent allowed opus by default; ≤1 invocation per task; only on `L` tasks. Output feeds the planner. |
| `quant` | **Computation**: numerical/algorithmic analysis, telemetry statistics, capacity estimates, benchmark interpretation. **Must** delegate arithmetic to scripts. | sonnet | Any multi-step arithmetic in its output without a script invocation is an eval failure. |
| `scrutineer` | **Scrutinization**: adversarial red-team review — edge cases, security holes, races, 10×-scale breaks, hidden assumptions. | sonnet | Structurally separate from qa-reviewer so "does it work" and "how does it break" never share a context. Reviews all self-modifications and all hook changes. |
| `toolsmith` | **Deterministic offloading**: converts repeated deterministic agent work into toolbelt scripts; owns, tests, documents the toolbelt. | sonnet | Makes principle 3 self-enforcing over time (§7). |
| `evaluator` | **Self-testing**: runs the harness on agent/skill changes, interprets deltas and confidence intervals, issues PASS/FAIL/INCONCLUSIVE. Never edits agent files itself. | sonnet | Proposer ≠ approver split with retrospective/toolsmith (§6, §11). |

### 5.3 Coverage map (requested area → owner)

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
| Checks & balances | qa-reviewer + auditor + scrutineer + hook/CI-enforced gates | §6, §11 |
| Internal team memory | librarian | retrospective (writes), hooks (load/compact) |
| Token optimization | transcripts + budgets + evaluator | §9 |
| Deterministic offloading | toolsmith + toolbelt | §7 |
| Self-testing of skills/agents | evaluator + harness | §10 |

Deliberately **not** separate agents (gap G10, "don't over-agent"): security review folds
into the scrutineer, performance analysis into quant, release notes into docs-writer.
Every new agent costs a routing decision on every task; the roster grows only when
telemetry shows an existing agent overloaded across distinct judgment types.

---

## 6. Delegation flow

```
user prompt
  ↓
orchestrator ── classifies task: XS / S / M / L        ← gap G1: task-size router
  │
  ├─ XS (typo, one-liner, factual q): answer directly or single engineer; skip pipeline
  ├─ S:   researcher → engineer → qa-reviewer → auditor
  ├─ M:   researcher → planner → engineer(s) ∥ → qa-reviewer → scrutineer → auditor
  └─ L:   strategist → researcher → planner → design-lead (if UI) → engineers ∥
              → qa-reviewer → scrutineer → verify.py → auditor → docs-writer
  ↓
[librarian: append facts/decisions]        ← Stop hook
[retrospective: if corrections]            ← Stop hook
[toolsmith: if deterministic-repeat flagged]
  ↓
user
```

Rules:
- Parallel (`∥`) only when work items share no files.
- Every specialist pre-flights: `PROCEED` or `BLOCKED: <missing>` before speculative work.
- The auditor is mandatory only when an engineer produced changes; conversational and
  pure-question turns skip it.
- Gates return work at most twice; the third failure escalates to the user with a
  diagnosis instead of burning tokens on retry loops.
- Gate state is written via `scripts/state.py` subcommands, never hand-written JSON.

---

## 7. Deterministic offloading — the toolbelt

**Location:** `.claude/scripts/toolbelt/` (repo-committed — travels with the copy-over;
the fable plan's `~/.claude/scripts/toolbelt/` location is portability-dead).

```
.claude/scripts/toolbelt/
├── INDEX.md                 # one line per script: name, purpose, usage — loaded on demand
├── <name>.py                # python3 only (§2.4)
└── tests/test_<name>.py     # every script ships with a test (run by harness + CI)
```

**Seed scripts:** `count.py` (line/word/token-estimate counts), `jsonmerge.py` (deep
JSON merge — also documents the settings-merge rule of §2.3), `diffstat.py` (summarize a
diff without pasting it), `csvstat.py` (column stats for data-engineer/quant),
`todo_scan.py` (TODO/FIXME with `path:line`), `memlint.py` (memory-file structure +
bloat report), `agentlint.py` (static agent-file checks, §10).

**Specific offloads carried from plan 07-R A3** (highest-value first):
1. **Memory brief becomes a script** — selection logic moves into the SessionStart hook
   and is injected via `additionalContext`; eliminates one haiku subagent call per
   session.
2. **Append dedup (Jaccard ≥ 0.6)** computed by a helper; the model only decides
   sharpen-vs-concatenate on a match.
3. **Compact** — mechanical passes (dedup, drop-by-date, sort, header rewrite) scripted;
   tag-merge judgment stays with the model.
4. **Gate-state helper** — `state.py` replaces orchestrator-hand-written JSON heredocs.

**The offloading loop** (self-enforcing over time):
1. Telemetry tags each subagent record with a `task_class`; retrospective + toolsmith
   scan for repeat deterministic patterns (same class, near-identical structure, ≥3
   occurrences).
2. Toolsmith writes script + test, updates `INDEX.md`; librarian adds a one-line memory
   rule: *"For X, run `toolbelt/y` — do not do it in-context."*
3. The harness gains a case asserting the pattern is now script-invoked.
4. Transcript metrics confirm the class's token cost dropped; if not, the script or the
   rule is wrong → retrospective entry.

**Hard rules (prompt-enforced, eval-checked):** any arithmetic beyond a single
operation → script; any exhaustive enumeration → script; any format conversion →
script; any verbatim transformation of >20 lines → script or editor tool, never retyped.

---

## 8. Memory (portable two-tier)

### 8.1 Project tier — primary, committed

`<repo>/.claude/memory/` is committed to the project repo. This is the only tier that
exists on every surface. In cloud sessions (`CLAUDE_CODE_REMOTE` set), the Stop-hook
flow stages memory changes on the session branch so they ride the PR; local sessions
commit per the project's convention (documented; a `.gitignore` opt-out remains
possible for projects that refuse committed memory, at the cost of mobile persistence).

### 8.2 Global tier — optional desktop enhancement

Cross-project learning in `~/.claude/memory/`, backed by a **dedicated private git
repo**: pulled by SessionStart, pushed best-effort by Stop, local-only fallback when
unconfigured. Explicitly optional: the system must be fully functional without it
(principle 1), because cloud sessions may have no access to a second repo.

### 8.3 Decay policy (gap G6)

Facts carry a last-confirmed date; unreferenced project facts expire to an archive
after 90 days; `memlint.py` reports bloat; the memory brief stays ≤200 tokens forever.
The librarian remains the sole memory writer (path-scoped guard once memory ops are
scripted).

---

## 9. Token tracking — accurate by construction

**Source of truth: captured `claude -p --output-format stream-json --verbose`
transcripts** (plan 07-R blocker B2). The SubagentStop payload carries no usage data, so
runtime JSONL can never be the measurement layer. Transcripts yield per-message `usage`
blocks (real input/output/**cache-read vs fresh** token counts), Task invocations →
routing, `BLOCKED:` returns → blocked-rate, and model per call. The harness parses this
into `metrics.json` per trial; runtime JSONL is still captured and *graded* (schema
validity) but never used as a measurement source.

On top of that measured base:
- **`harness/budgets.yaml`** — per-task-class and per-agent budgets, versioned in this
  repo. The harness fails changes that breach them; the Stop hook warns live sessions.
  No agent can raise its own budget.
- **Cache-hit accounting** (gap G2) — a cheap prompt is one that caches; agent-file
  edits that break the stable prefix show up as fresh-input inflation even when token
  *counts* fall. `agentlint` checks section ordering (stable identity/rules first,
  volatile brief/task last).
- **Trend + attribution** — `metrics.py --trend` compares rolling per-class medians
  against the committed baseline; merged changes record which task classes they should
  affect so deltas are attributable (correlational, but enough to catch "improvement
  made things worse"). >20% drift prints a one-line SessionStart warning.
- **Circuit breaker** (gap G7) — Stop hook flags sessions >3× class baseline; three
  consecutive flags for one class disable that class's autonomous mode pending review.
- **Pricing** — `pricing.json` corrected (§4 A1.3) and kept as the single pricing table
  for all reporting.

---

## 10. Self-testing harness (core deliverable)

Answers one question with measurable confidence: **did this change to an agent file,
skill, hook, or toolbelt script make the team better, worse, or neither?**

### 10.1 Layout (repo-level; the harness tests the source, the copy-over ships it)

```
harness/
├── run.py                        # entrypoint (python3; works in CI and cloud sessions)
├── budgets.yaml
├── evals/
│   ├── evals.json                # case manifest: prompt, class, expected_behavior, assertions
│   ├── golden/                   # ~8 seed cases (§10.4)
│   ├── holdout/                  # never used for tuning — release-gate only (gap G4)
│   ├── fixtures/
│   │   └── sample-project/       # small deterministic Flask app (~5 files, pytest,
│   │       └── .claude/          #   one seeded latent bug); SYSTEM UNDER TEST installs here
│   ├── graders/
│   │   ├── deterministic.py      # schema/cap/gate/memory/transcript checks — no model calls
│   │   └── judge.md              # LLM-judge prompt, pinned to haiku, {text, passed, evidence}
│   └── results/iteration-N/      # per-run outputs, grading.json, benchmark.json/.md
├── static/
│   ├── agentlint.py              # frontmatter valid, model tier declared, output cap present,
│   │                             #   pre-flight clause present, ≤200 lines, cache-safe ordering
│   └── hooklint.py               # hooks: no-fail wrapper present, no repo-content execution,
│                                 #   self-derived paths, json.dumps-only
└── runner-settings.json          # scoped permission profile for headless runs
```

### 10.2 Isolation (plan 07-R blocker B1 — non-negotiable mechanics)

- The system under test is installed **into the fixture repo's `.claude/`** — identical
  semantics locally and in cloud, and it *is* the §2 distribution path, so every harness
  run regression-tests mobile compatibility for free.
- Fixture copied fresh to a temp dir per trial, deleted after; the developer's real
  `~/.claude` is never touched *by design*. `CLAUDE_CONFIG_DIR` may additionally
  isolate CLI state but is undocumented — the harness self-test asserts zero writes to
  the real `~/.claude` before relying on it.
- Runner passes `--settings runner-settings.json` (scoped allow within the temp
  fixture, deny network and out-of-tree writes) — not `--dangerously-skip-permissions`
  (documented fallback only if scoped settings prove unworkable headless).
- No `CLAUDE_SKIP_AUDIT`: the gate loop is part of the behavior under test. Each trial
  has a hard wall-clock timeout (default 10 min); timeout = failed trial.

### 10.3 Three test layers

| Layer | What it checks | Cost | When |
|---|---|---|---|
| **Static** | agentlint + hooklint + toolbelt tests + copy-over smoke (§11) | ~0 tokens | every commit (CI, all 3 OSes) |
| **Behavioral** | Each golden task headless via `claude -p` against the fixture; deterministic assertions first, LLM-judge only for quality dimensions | ~$ per run | before merging any `.claude/` change |
| **Comparative (A/B)** | Base vs candidate agent set, N runs per affected golden task; pass-rate delta with Wilson confidence interval + token delta | $$ | before adopting a self-modification |

### 10.4 Cases, trials, verdicts

- **Seed cases (~8):** one per task class (XS/S/M/L incl. pure-question, plan,
  implement, conversational) + a correction case (retrospective→librarian loop, hits
  the fixture's seeded bug) + a memory-recall case (seeded prevention rule surfaced and
  satisfied) + an offload case (deterministic pattern must be script-invoked).
- **Assertions** carry `severity`: `critical` (any failure fails the case), `gate`
  (majority-of-trials), `soft` (reported, never failing). Every programmatic assertion
  names its grader function. Token-cap checks use the stated `ceil(len/4)` proxy for
  reproducibility.
- **Trials:** N=3 per case per variant (N=5 for `implement`/A-B). Per-case pass = all
  `critical` pass in all trials AND each `gate` passes in ≥2/3. Token metrics report
  the median; deltas <10% are noise, not wins (gap G3 — stochasticity is the default).
- **Verdicts:** **PASS** — quality non-inferior (CI lower bound > −5 pts) and tokens
  not regressed >10%, or strictly better. **FAIL** — regression or budget breach →
  revert (git is the rollback mechanism, gap G8). **INCONCLUSIVE** — interval too wide;
  evaluator increases N under a spend cap or reports "too small to measure; keep only
  if it reduces tokens."
- **Variants:** `with_system` vs `without_system` (bare fixture) for paired lift, and
  `old` vs `new` across iterations — mirroring skill-creator's `with_skill`/`without_skill`
  methodology.

### 10.5 Skill-builder integration

Claude Code's skill-building evaluation flow is **one judge among several, never the
authority**: `run.py --judge=skill-builder` adds its confidence score as an extra rubric
column when the tooling is available on the surface. Golden-task pass rates remain the
gating signal (skill-builder availability varies by surface and it doesn't know our
budgets or team-level flows). Persistent divergence between its verdict and ours is
logged and means our rubrics need review.

### 10.6 Evolution safety loop

```
retrospective/toolsmith proposes change (branch + PR in this repo)
  → static layer (free, instant, CI)
  → evaluator runs behavioral + A/B on affected tasks; report attached to PR
  → PASS → merge → adopters re-copy .claude/ → telemetry watches live cost 7 days
  → live regression? → git revert + retrospective entry
```

---

## 11. PR and CI hooks (test everything testable before end use)

### 11.1 GitHub Actions workflows (this repo)

**`.github/workflows/ci.yml`** — on every push and PR, matrix
`{ubuntu-latest, macos-latest, windows-latest}`:
1. **Static layer:** `agentlint.py` on all agent files, `hooklint.py` on all hooks,
   `python -m pytest .claude/scripts/toolbelt/tests harness/`, JSON validation of
   `.claude/settings.json` + `pricing.json`, `budgets.yaml` schema check.
2. **Copy-over smoke test** (replaces the old installer test): copy `.claude/` into a
   temp fixture project, assert hook commands resolve and execute under
   `$CLAUDE_PROJECT_DIR`-relative paths on that OS, assert `session_start.py` emits
   valid `additionalContext` JSON from a synthetic payload, assert no writes escape the
   fixture. **This is the §2.5 Windows verification.**
3. **Docs check:** README copy-over instructions reference paths that actually exist.

**`.github/workflows/evals.yml`** — behavioral/A-B layer. Triggered on PRs that touch
`.claude/**` or `harness/**` when the `run-evals` label is applied (model calls cost
money; label-gating keeps drive-by PRs free), plus on a weekly schedule against `main`
as drift detection. Requires `ANTHROPIC_API_KEY` secret; runs
`harness/run.py --changed-only`, uploads `benchmark.md` as an artifact, and posts the
verdict table as a PR comment. A `FAIL` verdict fails the check.

### 11.2 Branch protection + review policy

- `main` is protected: PRs only, `ci.yml` required; `evals.yml` required for PRs
  labeled `run-evals` (and any PR touching `.claude/agents/**` or `.claude/skills/**`
  must carry that label — enforced by a path-filter job that fails without it).
- **Proposer ≠ approver, enforced by the platform:** self-modification PRs authored by
  the retrospective/toolsmith flow are merged only with a green evaluator report
  attached; CI is the impartial approver. `git log .claude/` *is* the team's
  constitutional history — every change carries its harness verdict in the PR.
- PR template asks for: task class affected, expected metric movement, harness verdict
  link.

### 11.3 In-repo git hooks — deliberately none

Local pre-commit hooks are an installation step (violates the no-install requirement)
and don't run on mobile. Everything they would do runs in `ci.yml` instead; developers
who want faster feedback run `python harness/run.py --static` manually.

### 11.4 Runtime PreToolUse gate (already shipped, kept)

The existing PreToolUse hook remains the runtime enforcement point (e.g. blocking
denied verbs, guarding memory writes to librarian-owned paths) — ported to Python per
§2.4 and lint-checked like every other hook.

---

## 12. Roadmap

Phases 1–7 shipped (see `plans/`). New phases, each independently shippable, each PR
carrying its benchmark delta:

| # | Phase | Delivers | Depends on |
|---|---|---|---|
| P1 | **Portability re-base** | `claude-system/` dissolved into `.claude/`; hooks → Python with self-derived paths + no-fail wrappers (§4 A1.1/A1.2); installers/uninstallers removed; README copy-over docs; `ci.yml` static + copy-over smoke on 3 OSes (incl. §2.5 Windows verification) | — |
| P2 | **Measurement truth** | A1.3 pricing fix, A1.4 telemetry descope, transcript-parsing module shared by harness and `metrics.py` | P1 |
| P3 | **Harness core** | fixture, runner, isolation, deterministic graders, judge, seed cases, iteration-0 baseline committed; `evals.yml` + branch protection + PR template | P1, P2 |
| P4 | **Toolbelt + offloads** | seed scripts + tests, toolsmith agent, A3 offloads (memory-brief script, dedup, compact, `state.py`), hard rules in agent prompts | P3 (measured before/after) |
| P5 | **Security + comms fixes** | tool-grant scoping, deny lists, `verify.py` gate, JSON-relay-via-file, auditor corroboration, planner/qa grant fixes | P3 |
| P6 | **Specialists wave 1** | data-engineer, docs-writer, scrutineer; XS/S/M/L router in orchestrator | P3 (lint + evals gate their files) |
| P7 | **Specialists wave 2** | design-lead, strategist, quant; gate-escalation rules | P6 |
| P8 | **Cost hardening** | `budgets.yaml`, `--trend`, cache-hit accounting, drift/staleness warning, circuit breaker, memory decay | P3 |
| P9 | **Memory persistence** | cloud commit-back of `.claude/memory/` on session branch; optional git-backed global tier | P1 |
| P10 | **Evolution loop live** | proposer/approver CI enforcement, live-telemetry watch + revert policy, holdout rotation, skill-builder judge hook-in | P4–P9 |
| P11 | **Plugin packaging (optional)** | `.claude-plugin/` + marketplace declaration for multi-repo fleets; copy-over path remains primary | P10 |

Ordering rationale: measurement (P2/P3) lands before every change that claims savings
(P4+), so no claim is ever folklore; portability (P1) lands first because the harness
fixture depends on self-derived paths.

---

## 13. Gap register (asked-for vs optimal — all folded in above)

| # | Gap | Where handled |
|---|---|---|
| G1 | Task-size router — a 13-agent pipeline on a typo is first-order waste | §6 |
| G2 | Prompt-cache discipline — token *count* ≠ token *cost* | §9, agentlint |
| G3 | Eval stochasticity — single-run verdicts are coin flips | §10.4 |
| G4 | Overfitting to the eval suite — holdout set, quarterly rotation | §10.1, §10.4 |
| G5 | Drift between repo and live copy — staleness warning: SessionStart compares `.claude/` manifest hash against the version recorded at last harness pass | §9, P8 |
| G6 | Memory decay — expiry, archive, memlint | §8.3 |
| G7 | Runaway-cost circuit breaker | §9 |
| G8 | Versioning + rollback — git *is* the version scheme; revert is the rollback | §10.6, §11.2 |
| G9 | Hook security surface — hooks run on every session incl. untrusted clones | §4, hooklint |
| G10 | Don't over-agent — smallest team covering the judgment surface | §5.3 |
| G11 | Judge cost — deterministic assertions short-circuit; haiku judge, scores only | §10.3 |
| G12 | *(new)* Global-install architecture is invisible on mobile — repo-`.claude/` first | §2 |
| G13 | *(new)* Local git hooks are an install step — CI carries all pre-merge testing | §11.3 |

---

## 14. Acceptance criteria (whole system)

1. **Copy-over works everywhere:** copying `.claude/` into a fresh project on macOS,
   Linux, and Windows — and opening that project in a Claude Code **mobile/cloud
   session** — yields the full 18-agent team with hooks firing. No installer executed.
2. **Mobile smoke test (manual, release-gating):** from the iOS or Android app, on a
   project containing the copied `.claude/`, an `S`-class task flows
   researcher → engineer → qa-reviewer → auditor with a non-null auditor verdict, and
   memory changes appear on the session branch.
3. An XS task completes with ≤2 agent invocations; an L task traverses
   strategist → … → docs-writer with every gate firing.
4. `python harness/run.py` on an unmodified tree passes static + behavioral layers;
   deliberately breaking an agent's output schema is caught (agentlint or A/B FAIL with
   a confidence-bounded delta); a harness run writes nothing to the real `~/.claude`.
5. Transcript-derived token counts are non-null and per-class medians are reported
   split by cache-read vs fresh input; deltas <10% are labeled noise.
6. A repeated deterministic pattern results, within one retrospective cycle, in a
   toolbelt script and a measured token drop for that class.
7. A session exceeding 3× class baseline is flagged at Stop; a third consecutive flag
   disables that class's autonomous mode.
8. CI blocks any PR touching `.claude/` that fails static checks on any OS; agent/skill
   PRs without an evaluator verdict cannot merge.
9. `git log .claude/` shows every team change with its harness verdict; `git revert`
   restores any prior team state.

---

## Appendix A — Audits of the two source plans

Each plan was audited independently against the original criteria:
*(1) expansive team covering the 13 named areas, (2) self-testing of skills/agent files
via scripts + skill-builder, (3) comprehensive evolution-safe testing harness,
(4) accurate token tracking, (5) gap analysis toward optimal.*

### A.1 `first.plan.md` (plan 07-R — audit + eval harness)

**Verdict: excellent depth, insufficient breadth.** It is an implementation-grade audit
and harness design for the *existing 10-agent system*, not a plan for the requested
expansive team.

Strengths (all carried into this plan):
- Evidence-grounded correctness findings with `file:line` cites — env-var
  non-propagation killing the project memory tier, `set -e` silently dropping context
  injection, wrong Opus pricing, **telemetry that records nulls** (the SubagentStop
  payload has no usage fields), non-idempotent installer. These invalidate several
  assumptions the other plan builds on.
- The two blocker fixes: harness **isolation** via the fixture repo's `.claude/`
  (which doubles as the mobile distribution proof), and **transcripts as the only
  accurate token source** — the strongest answer in either plan to "accurately track
  token consumption."
- Statistical rigor: N trials, severity classes, numeric "quality steady"/"adopted"
  definitions, with/without paired variants mirroring skill-creator methodology.
- The only plan that addressed mobile/cloud distribution at all (A5), including memory
  persistence on ephemeral VMs.

Gaps against the criteria:
- **No team expansion.** Data, documentation, design, strategy, computation, and
  scrutinization have no owners; criteria area coverage ≈ 7/13.
- Skill-builder is mirrored as methodology but not integrated as a judge signal.
- No budgets, trend detection, circuit breaker, cache-hit accounting, or
  proposer≠approver structure — evolution-safety is limited to re-running the suite.
- Gap analysis is an audit of the implementation, not of the request-vs-optimal space.
- CI appears only as "stacked small PRs"; no workflows, no branch protection.

### A.2 `fable.multi.agent.plan.md` (expansive team plan)

**Verdict: excellent breadth and governance, built on two false foundations.**

Strengths (all carried into this plan):
- **Full criteria coverage of the team surface** — 8 new specialists with an explicit
  requested-area → owner map; disciplined by G10 ("don't over-agent").
- The **toolbelt + toolsmith offloading loop** makes deterministic offloading
  self-enforcing rather than a one-time list; hard eval-checked rules.
- Three-layer harness (static/behavioral/A-B) with Wilson intervals, an explicit
  INCONCLUSIVE verdict, holdout set, budgets.yaml, and **explicit skill-builder
  integration as one judge among several** — the best answer to criteria (2) and (3).
- Governance: proposer≠approver, budget authority external to agents, circuit breaker,
  git-as-constitutional-history.
- The G1–G11 gap analysis — the best answer to criteria (5); adopted nearly verbatim.

Gaps against the criteria and against reality:
- **Portability-dead architecture.** Everything anchors on `~/.claude/` (toolbelt
  location, drift checksums vs installed copies, hooks blocking writes to
  `~/.claude/agents/`, installer-as-sync). None of it exists in a cloud/mobile session.
- **Builds on measurement that doesn't measure.** It marks phase-6 telemetry "✅
  shipped" and stacks budgets, `--trend`, and the 3×-baseline breaker on per-invocation
  JSONL — which plan 07-R proved records null tokens. As written, its cost governance
  is unfalsifiable.
- Ignores the five verified correctness bugs; no isolation design for the harness
  (risking eval runs against the developer's real `~/.claude`); CI is a two-word
  bullet ("CI wiring").

### A.3 Comparison → merge decisions

The plans are complementary along a clean axis: **fable defines what the team should
be; 07-R defines how to know any of it is true.** Merge rules applied:

| Dimension | Taken from | Adaptation |
|---|---|---|
| Team roster, coverage map, XS/S/M/L router | fable | unchanged (§5, §6) |
| Correctness/security/comms fixes | 07-R | re-based onto `.claude/`-first layout (§4) |
| Token measurement | 07-R (transcripts) | fable's budgets/trend/breaker rebuilt on top of it (§9) |
| Harness | both | fable's three layers + skill-builder judge + holdout, on 07-R's isolation, trials, severity, and verdict math (§10) |
| Toolbelt | fable | relocated into repo `.claude/scripts/toolbelt/` (§7) |
| Distribution | 07-R A5, promoted | from "repackaging step" to the architecture's first principle; installers removed per the new requirement (§2) |
| Gap analysis | fable G1–G11 | + G12/G13 from the new platform-parity and no-install requirements (§13) |
| Governance/evolution loop | fable | proposer≠approver enforcement moved from local hooks to CI/branch protection, which works from mobile (§11) |
| CI/PR | new | neither plan had it concretely; specified in §11 per the new requirement |
