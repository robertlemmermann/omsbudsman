# Plan 07-R (Revised) — Audit + Evaluation Harness

> Status: **implementation-ready, post-review.** This document supersedes
> `plans/07-audit-and-eval-harness.md` (the original proposal, kept unchanged for
> comparison). An independent adversarial review (PR #12 comment) verified every
> finding against the repo and current Claude Code docs, confirmed the core audit,
> and required 10 amendments — 2 of them blockers in the harness plumbing. All 10
> are folded in below and marked `[AMENDED]`. Original findings that survived review
> unchanged are marked `[VERIFIED]`.

## Context

The system (10 agents, 4 lifecycle hooks, two-tier memory, gate enforcement,
retrospective mistake-learning, local telemetry) is functionally complete through all 6
planned phases (`plans/00-master-plan.md`). Two things are needed:

1. **A rigorous audit** across five axes — general improvements, token-efficiency
   maximization, token *reduction* by offloading deterministic work to hook scripts,
   security, and inter-agent communication (ownership holes + a leaner messaging
   harness without quality loss).
2. **An evaluation harness** so any change to the system gets benchmarked for
   performance and *adoption* (behavior changed as intended), mirroring Anthropic's
   `skill-creator` eval methodology.

**Decided scope:** full scope (harness + all Part A fixes + A5 mobile repackaging).
Runner drives the system via headless `claude -p`.

---

## Part A — Audit findings

### A1. Correctness bugs (fix regardless of everything else)

1. **[VERIFIED, remedy AMENDED] Env vars don't propagate between hooks/subagents.**
   `claude-system/hooks/session-start.sh:47-48` uses
   `export LIBRARIAN_GLOBAL_ROOT/LIBRARIAN_PROJECT_ROOT`, but each Claude Code hook
   runs in its own process — exports reach neither the other hooks
   (`subagent-stop.sh:19-20`, `stop.sh:22-23`, `user-prompt-submit.sh:16`) nor any
   subagent. Review escalation: since no export ever reaches the model's Bash
   environment and `librarian.md:17` falls back to global-only when
   `$LIBRARIAN_PROJECT_ROOT` is unset, **the project memory tier is effectively dead
   today** — a present-tense break of master-plan goal 1, not just a future cloud
   concern.
   **Fix (two parts, both required):**
   - Write `LIBRARIAN_*` to `$CLAUDE_ENV_FILE` in the SessionStart hook. This is
     documented to persist variables **for subsequent Bash commands only** — it fixes
     the subagent/Bash path (librarian can finally see the project root), NOT the
     other hooks.
   - Each other hook must **self-derive** its roots from its own stdin payload: use
     the payload's `cwd`, run `git rev-parse --show-toplevel` for the project root,
     and compute the global root from its own install location — never trust an
     inherited env var.
   - **Windows:** `CLAUDE_ENV_FILE` semantics are documented as bash `export` lines
     only; the `.ps1` hooks must rely solely on self-derivation from the payload
     `cwd`. Every `.sh` change in this plan has a matching `.ps1` change.
2. **[VERIFIED] `set -e` + inline Python can abort before the guaranteed `exit 0`.**
   `session-start.sh:6` sets `-e`; if the Python block (`:58-104`) throws, the trailing
   `exit 0` (`:107`) never runs. Review escalation: the real damage is not blocked
   startup (SessionStart non-zero doesn't block) but **silent loss of the entire
   orchestrator persona + gate-state contract injection**. All four hooks share the
   pattern. Fix: `python3 … || true` (and PowerShell equivalent) in all hooks.
3. **[AMENDED — original finding was wrong] Model IDs and pricing.**
   `claude-sonnet-4-6` and `claude-haiku-4-5` are **active** models (July 2026) — the
   original claim that they "likely no longer resolve" was false. Migrating agents to
   newer IDs (e.g. Sonnet 5) is a **tuning change** that must go through the harness
   (new tokenizer/behavior), not a correctness fix. The genuine bug is in
   `claude-system/scripts/metrics.sh:55-61`: Opus is priced at $15/$75 per MTok;
   actual Opus 4.6/4.7/4.8 pricing is **$5/$25** (Haiku $1/$5 and Sonnet $3/$15 rows
   are correct). Fix the pricing table and add missing current model rows in both
   `metrics.sh` and `metrics.ps1`.
4. **[NEW, from review] Telemetry records nulls — the measurement layer doesn't
   measure.** The documented SubagentStop hook payload carries **no** usage fields
   (no `usage`, `input_tokens`, `output_tokens`, `model`, `duration_ms`,
   `subagent_type`, `blocked`). `subagent-stop.sh:48-67` probes for all of these
   speculatively, so JSONL records have null tokens/model/agent, and `metrics.sh`'s
   cost/cache/per-agent tables plus `stop.sh`'s session summaries are largely vacuous.
   Fix: descope the SubagentStop record to fields that actually exist in the payload
   (session_id, timestamp, and whatever `last_assistant_message` parsing can reliably
   yield, e.g. agent-name/BLOCKED detection from the output block), and source
   token/model/routing data from transcripts (see Part B). Update `metrics.sh`/.ps1
   to stop reporting fields that are always null.
5. **[NEW, from review] `install.sh` is not idempotent — re-installs corrupt
   settings.** `install.sh:83-91` merges settings lists with `a[k] = a[k] + v`, so
   every re-run appends duplicate hook registrations; each hook then fires N times per
   event (duplicated context injection, duplicated gate evaluation, duplicated
   telemetry). The header's "Idempotent — re-runs are safe" (`install.sh:3`) is false.
   Fix: dedupe hook entries on merge (match by command path, the same key
   `uninstall.sh` scrubs by), in both `install.sh` and `install.ps1`. Also note:
   backups (`~/.claude.backup-<ts>`) accumulate without pruning — add a note or a
   `--prune` flag; and `uninstall.sh`'s settings scrub silently no-ops without
   python3 — emit a warning.

### A2. Security **[VERIFIED]**

The system's security boundaries are **prompt instructions, not tool grants**.

1. **"Read-only" agents hold write-capable Bash.** `researcher.md:4` and
   `qa-reviewer.md:4` grant full `Bash` while their prose demands read-only behavior
   (`researcher.md:16-18`). Fix: scope Bash via permission settings (allow-list
   read-only commands) or drop Bash where Read/Grep/Glob suffice.
2. **Engineers hold unrestricted Bash + Write** (`backend-engineer.md:4` etc.). Add a
   project-level `deny` permission list for the destructive verbs the prompts already
   forbid. **[AMENDED]** The implementer must enumerate the exact deny entries; start
   from: `rm -rf`, `git push`, `git reset --hard`, `curl`/`wget` (network), package
   installs (`npm install`, `pip install`) unless the step authorizes them.
3. **Librarian is the "sole memory writer" by convention only** (`librarian.md:4`
   grants Read/Write/Edit/Bash vs `:143`'s prose confinement). Acceptable near-term;
   path-scoped guard once memory ops are scripted (A3).
4. **No shell-injection surface in hooks** (payloads passed as argv to Python, never
   eval'd) — verified clean. **[AMENDED]** Two content-level notes from review:
   `user-prompt-submit.sh:69-72` persists raw user prompt text that is later forwarded
   into retrospective context (an indirect prompt-injection channel — treat
   `retro_prompts` as untrusted data in the retrospective prompt); and
   `session-start.sh:72-73` builds JSON by string concatenation around `session_id` —
   use `json.dumps` throughout.

### A3. Token efficiency — offload deterministic work to scripts **[VERIFIED]**

Targets confirmed by review; note the savings claims cannot be verified from current
telemetry (A1.4) — the harness baseline (Part B) is what makes them measurable.

1. **Memory brief as a script, not a subagent call.** The brief's selection logic
   (`librarian.md:25-28`) is near-deterministic; move it into `session-start.sh`/.ps1
   and inject via the existing `additionalContext` path (`session-start.sh:84-103`).
   Eliminates one haiku subagent call per session. Highest-value change.
2. **Append dedup (Jaccard ≥ 0.6)** (`librarian.md:63`): compute similarity in a
   helper script; the model only decides sharpen-vs-concatenate on match.
3. **Compact** (`librarian.md:76-87`): script the mechanical passes (dedup,
   drop-by-date, sort, header rewrite); leave tag-merge judgment to the model.
4. **Gate-state helper.** Replace orchestrator-hand-written JSON heredocs
   (`orchestrator.md:167`) with `state.sh`/`state.ps1` subcommands
   (`state set-qa pass`, `state set-auditor approve`).

All new helpers ship as `.sh` **and** `.ps1` (or portable `python3` invoked by both).

### A4. Inter-agent communication & ownership

1. **[VERIFIED, fix AMENDED] Planner's Task grant.** `planner.md:4` grants `tools:
   Task` while the prose forbids routing. **Trap the fix must avoid:** omitting
   `tools:` makes the subagent **inherit all tools** (worse), and an empty list
   **fails to launch** (v2.1.208). Fix: set `tools: Glob` — a benign, minimal grant
   present only to satisfy the non-empty requirement — with a prose line telling the
   planner not to use it.
2. **[VERIFIED] No integration-coherence owner.** Engineers implement one step each;
   QA reviews one step; the auditor doesn't open files. Nobody verifies parallel
   changes work *together*.
3. **[VERIFIED, decided] No whole-suite verification gate.** **Decision (was an open
   question):** a deterministic `verify` **script** (`claude-system/scripts/verify.sh`
   /.ps1) that runs the project's build/test command; the **orchestrator invokes it**
   after the last QA pass and feeds its verbatim result to the auditor as a new
   `VERIFY RESULT` input field. Script, not hook (hooks can't sit between QA and
   auditor in the dispatch order); auditor treats a failing VERIFY RESULT as an
   automatic `revise`. Closes #2 and #3 at zero model cost.
4. **[VERIFIED] Task-grant smudges.** Remove Task from `qa-reviewer.md` (pass the
   brief in the payload instead) — it keeps Read/Grep/Glob/Bash, so the
   non-empty-tools rule is satisfied. Keep Task for `auditor` (documented researcher
   escalation; nested subagents supported since v2.1.172) and `retrospective`.
5. **[AMENDED — reframed] Schema conformance: measure at eval time, optionally
   enforce at runtime.** The original claim that a grader "enforces" conformance
   conflated measurement with enforcement. Correct framing: the eval harness
   **measures** schema conformance on the benchmark; prompt-trimming decisions are
   made from that data. If runtime enforcement is wanted later, the documented
   mechanism is a **SubagentStop hook** that validates `last_assistant_message`
   against the owning agent's output schema and emits corrective `additionalContext`.
   Optional; not in the initial build.
6. **[NEW, from review] Missed communication failure modes** (recorded as findings;
   cheap mitigations in scope):
   - **Verbatim JSON relay corruption:** `retrospective.md:100-106` emits a one-line
     JSON payload the orchestrator must hand-copy into a librarian dispatch
     (`orchestrator.md:140`); a mis-copy is silently dropped as
     `BLOCKED: malformed`. Mitigation: retrospective writes the payload to a file
     under the state dir via one Bash call; the orchestrator passes the *path*;
     librarian reads it.
   - **Lossy summary chain to the final gate:** the auditor judges requirement
     coverage from twice-truncated summaries (engineer ≤50 lines → QA ≤30 lines).
     The `verify` gate (#3) covers build/test truth; for coverage truth, add one line
     to `auditor.md` telling it to dispatch researcher whenever COVERAGE would
     otherwise rest on an engineer claim it cannot corroborate.
   - **Stale brief:** MEMORY HINTS are fetched once at session start and never
     refreshed after mid-session appends. Accepted for now; note in
     `orchestrator.md` that post-append hints apply from the next session.

### A5. Mobile / distribution **[VERIFIED, scope AMENDED]**

Nothing under `~/.claude/` carries into Claude Code cloud/mobile sessions (verified
against web docs). Two documented paths, in order:

1. **Repo-committed `.claude/`** — agents in `.claude/agents/`, hooks in the repo's
   `.claude/settings.json` ("Part of the clone"; zero infrastructure; also exactly
   what the eval harness fixture uses — see Part B — so this path gets exercised for
   free).
2. **Repo-declared plugin** (`.claude-plugin/` + marketplace declaration in committed
   settings) — verified to install at cloud session start; requires network access to
   the marketplace source, so it degrades under restricted network policies.
   Preferred for multi-repo distribution once path 1 is proven.

**[AMENDED] Memory persistence is a prerequisite for BOTH tiers, not just global:**
- **Project tier in cloud:** sessions start from a fresh clone, so librarian writes to
  `<repo>/.claude/memory/` vanish with the VM unless committed. **Decision:** in
  cloud sessions (`CLAUDE_CODE_REMOTE` set), the end-of-session flow commits
  `.claude/memory/` changes to the session branch so they ride the PR. Local sessions
  keep the current uncommitted behavior.
- **Global tier:** **Decision (was an open question):** back it with a dedicated
  private git repo, pulled by the SessionStart hook and pushed best-effort by the
  Stop hook. Local-only fallback when the repo isn't configured.

A1.1 (de-hardcoding `~/.claude`) is a prerequisite. Benchmark before/after
repackaging; manual smoke test from the Claude mobile app afterward.

---

## Part B — Evaluation harness (primary new deliverable)

**Goal:** for any change to the system, answer (a) did quality hold or improve,
(b) did token cost move, (c) was the change *adopted* (targeted behavior changed as
intended, nothing else regressed).

### Layout

```
evals/
├── evals.json                 # case manifest: prompt, expected_behavior, assertions
├── fixtures/
│   └── sample-project/        # small deterministic target repo, reset per run
│       └── .claude/           # THE SYSTEM UNDER TEST installs here (see Isolation)
├── graders/
│   ├── deterministic.py       # schema/cap/gate/memory/transcript checks — no model calls
│   └── judge.md               # LLM-as-judge for synthesis/plan/routing quality
├── runner/
│   ├── run_evals.py           # drives cases, captures stream-json transcript
│   └── runner-settings.json   # scoped permission profile for headless runs
└── results/
    └── iteration-N/           # per-run outputs, grading.json, benchmark.json/.md
```

### [AMENDED — BLOCKER B1 fix] Isolation mechanism

The original design used a temp `CLAUDE_HOME`, **which the `claude` CLI does not
read** (only this repo's own scripts honor it as a fallback) — runs would have
silently executed against the developer's real `~/.claude`. Replacement design:

- The system under test is installed **into the fixture repo's `.claude/` directory**
  (project-scoped agents + `settings.json` hooks — fully documented, identical
  semantics locally and in cloud, and doubles as the A5 path-1 proof).
- The runner passes `--settings <file>` for run-scoped settings (permissions, model
  pins) — a documented CLI flag.
- The fixture copy is created fresh in a temp dir per trial and deleted after; the
  developer's `~/.claude` is never touched *by design* rather than by env var.
- `CLAUDE_CONFIG_DIR` may additionally be set to a temp dir to isolate CLI state, but
  it is **undocumented** — the harness self-test must verify it took effect (assert
  zero writes to the real `~/.claude` during a run) before relying on it.
- Because hooks live in the fixture's settings, repo-relative hook paths must work —
  which A1.1's self-derivation fix provides. **The harness therefore depends on A1.1
  landing first** (reflected in the build order).

### [AMENDED — BLOCKER B2 fix] Metrics source of truth

The original design read tokens/routing/blocked-rate from the system's telemetry
JSONL; the SubagentStop payload carries no usage data, so those fields are null
(A1.4). Replacement: **the captured `claude -p --output-format stream-json --verbose`
transcript is the single source of truth** for:
- per-message `usage` blocks (real input/output/cache token counts),
- Task tool invocations → routing (which agents ran, in what order),
- `BLOCKED:` returns → blocked-rate,
- model per call.

`run_evals.py` parses the stream-json into a normalized `metrics.json` per trial. The
system's own JSONL is still captured and *graded* (schema validity, record presence)
but never used as a measurement source.

### Case shape (`evals.json`)

```json
{
  "id": "impl-add-endpoint",
  "prompt": "Add a /health endpoint that returns 200",
  "class": "implement",
  "expected_behavior": ["routes researcher→planner→backend→qa→auditor", "auditor approves"],
  "assertions": [
    {"name": "researcher-emits-findings-schema", "type": "programmatic", "grader": "check_findings_schema", "severity": "gate"},
    {"name": "gate-state-has-auditor-verdict",  "type": "programmatic", "grader": "check_gate_state",       "severity": "critical"},
    {"name": "total-tokens-under-budget",        "type": "programmatic", "grader": "check_token_budget", "params": {"max_tokens": 150000}, "severity": "soft"},
    {"name": "synthesis-leads-with-answer",      "type": "llm", "severity": "gate"}
  ]
}
```

**[AMENDED]** Every `programmatic` assertion names its grader function in
`deterministic.py` and carries a `severity`: `critical` (any failure fails the case),
`gate` (majority-of-trials semantics), `soft` (reported, never failing).

### Graders

- **Deterministic** (`graders/deterministic.py`, zero model cost):
  - Output-schema conformance: researcher `FINDINGS/GAPS/CONFIDENCE`, engineer
    `CHANGES/RATIONALE/TESTS RUN/HANDOFF`, `VERDICT` blocks; researcher ≤30 lines,
    engineer ≤50 lines. **[AMENDED]** The brief "≤200 tokens" check uses the
    deterministic proxy `ceil(len(text)/4)` chars-per-token — no tokenizer API call;
    the proxy is stated in the grader so pass/fail is reproducible.
  - Gate-state transitions: `session-<id>.json` ends with non-null `auditor_verdict`
    when `qa_verdicts` is non-empty (the invariant `stop.sh:68-73` enforces).
  - Memory mutations: appended entries match `librarian.md:111-127` block format;
    recurrence increments on repeat.
  - Transcript-derived (per B2 fix): routing correctness, token budgets, blocked-rate.
- **LLM-as-judge** (`graders/judge.md`): synthesis quality, plan quality, routing
  appropriateness. **[AMENDED]** Judge model pinned to `claude-haiku-4-5` (cheap,
  stable; change only via a benchmarked revision), judge prompt checked into
  `graders/judge.md`, output shape `{text, passed, evidence}`, pass criterion: all
  judge assertions `passed: true`.

### [AMENDED] Trials, aggregation, thresholds

Agent runs are stochastic; single runs cannot distinguish regression from noise.

- **N = 3 trials** per case per variant (**5** for the `implement` class).
- Aggregation: per-assertion **pass fraction** across trials. Per-case pass =
  every `critical` assertion passes in all trials AND each `gate` assertion passes
  in ≥2/3 trials. Token metrics report the **median** across trials.
- **"Quality steady"** (regression gate for Part C steps): suite-level gate-assertion
  pass rate drops ≤5 percentage points vs the previous iteration AND no `critical`
  assertion that passed 3/3 now fails ≥2/3.
- **"Adopted"**: the change's targeted assertions flip in the intended direction at
  ≥2/3, with quality steady elsewhere.
- Token deltas under 10% of the median are reported as noise, not wins.

### Variants (paired comparison)

- `with_system` vs `without_system` (bare fixture, no `.claude/` config) → paired
  lift, per skill-creator's `with_skill`/`without_skill`.
- `old` vs `new` across `iteration-N` dirs when iterating on the system itself.

### Runner

Per case × variant × trial: copy fixture to a temp dir → install the system into
`<fixture>/.claude/` (with_system only) → run
`claude -p "<prompt>" --output-format stream-json --verbose --settings runner-settings.json`
→ capture transcript, fixture git diff, gate-state file, memory files → grade →
aggregate into `benchmark.json` + `benchmark.md`.

**[AMENDED — decided] Permissions:** a scoped `--settings` permission profile (allow
the tools the system needs within the temp fixture; deny network and out-of-tree
writes) instead of `--dangerously-skip-permissions`. Fall back to the latter only if
scoped settings prove unworkable headless, documented in `evals/README.md`.
**[AMENDED] Stop-gate handling:** the runner does **not** set `CLAUDE_SKIP_AUDIT` —
the gate loop is part of the behavior under test. Instead each trial has a hard
wall-clock timeout (default 10 min); a timeout is recorded as a failed trial.

### Seed cases (~6–8)

One per orchestrator task class (`orchestrator.md:36-41`) — pure-question, plan,
implement, trivial, conversational — plus a correction case (retrospective→librarian
loop) and a memory-recall case (a prevention rule seeded in fixture memory is
surfaced and satisfied).

### Fixture spec **[AMENDED]**

`fixtures/sample-project/`: a small Python + Flask app (~5 files: `app.py`, one
module, `tests/test_app.py` with pytest configured, `README.md`), with one seeded
latent bug (an unhandled `None` path) exercised by the correction case. Python chosen
because `python3` is already the system's only hard dependency.

---

## Part C — Build order

1. **A1.1 env/self-derivation + A1.2 `set -e` guard + A1.5 installer idempotency.**
   Small, mechanical; the harness fixture's repo-relative hooks depend on A1.1.
2. **Eval harness** (Part B as amended) + seed cases + committed iteration-0 baseline.
3. **A1.3 pricing fix + A1.4 telemetry descope** — re-run; expect no behavior change
   (measurement-only edits).
4. **A3 token offloads** — re-run; expect median token drop on `question`/`plan`
   classes, quality steady.
5. **A2 security scoping + A4 ownership/communication fixes** (planner/qa tool
   grants, verify gate, JSON-relay-via-file, auditor corroboration line) — re-run;
   quality steady, no BLOCKED spike.
6. **A5 repackaging** (repo-`.claude/` path first, plugin second) + memory
   commit-back — re-run + manual mobile smoke test.

Stacked small PRs, one per numbered step, each with its benchmark delta.

---

## Files to create / modify

**Create:** `evals/evals.json`, `evals/fixtures/sample-project/*` (incl. `.claude/`
install target), `evals/graders/deterministic.py`, `evals/graders/judge.md`,
`evals/runner/run_evals.py`, `evals/runner/runner-settings.json`, `evals/README.md`,
`claude-system/scripts/state.sh` + `state.ps1`, `claude-system/scripts/verify.sh` +
`verify.ps1`, memory helper scripts (portable `python3`, invoked from both `.sh` and
`.ps1` wrappers), `claude-system/skills/evals/SKILL.md`.

**Modify:** all `claude-system/hooks/*.sh` **and** `*.ps1` (self-derivation,
`set -e` guard, env-file write, deterministic brief injection, memory commit-back);
`claude-system/agents/planner.md` (`tools: Glob`), `qa-reviewer.md` (drop Task),
`auditor.md` (VERIFY RESULT input + corroboration line), `orchestrator.md`
(state-helper usage, verify dispatch, JSON-relay-via-file), `retrospective.md`
(payload-to-file); `claude-system/scripts/metrics.sh` + `.ps1` (pricing, null-field
descope); `install.sh` + `install.ps1` (idempotent merge, warnings);
`settings.fragment.json` (updated command paths if needed).

## Verification

- **Harness self-test:** run against the checked-in fixture; confirm
  `benchmark.json` is produced; deliberately break one agent's output schema and
  confirm the grader catches it; **assert zero writes to the real `~/.claude` during
  a run** (B1 regression check); confirm transcript-derived token counts are non-null
  (B2 regression check).
- **Installer lifecycle test:** install → re-install → uninstall against a temp HOME;
  assert hook registrations appear exactly once after re-install and are gone after
  uninstall.
- **End-to-end sanity:** the `implement` seed case shows
  researcher→planner→engineer→qa→auditor routing in the transcript and a non-null
  auditor verdict in the gate-state file.
- **Regression guard:** after each Part C step, re-run the full suite at N trials and
  apply the numeric "quality steady"/"adopted" definitions from Part B.
- **Offload token check:** median tokens on `question`/`plan` classes drop after
  step 4 — measured from transcripts, not the system's own telemetry.

## Resolved questions (previously open)

1. **Global-tier memory on ephemeral VMs:** git-backed private repo, pulled at
   SessionStart, pushed best-effort at Stop; local-only fallback. Project tier:
   committed back on the session branch in cloud sessions.
2. **Runner permissions:** scoped `--settings` permission profile over
   `--dangerously-skip-permissions`; fallback documented if unworkable.
3. **Verify gate:** deterministic script invoked by the orchestrator between the last
   QA pass and the auditor; result passed to the auditor as `VERIFY RESULT`; failing
   result → automatic `revise`.

## Review traceability

Independent review verdict: *implement with amendments* (2 blockers, 8 majors). All
10 amendments are incorporated: B1 → Isolation mechanism; B2 → Metrics source of
truth + A1.4; M1 → A1.1; M2 → A4.1; M3 → A1.3; M4 → A1.5; M5 → Trials/thresholds;
M6 → A4.5; M7 → A4.6; M8 → A5 memory decisions. Minor findings (line anchors, `.ps1`
parity, `--verbose`, non-plugin A5 path, permission-flag resolution) are folded into
their sections. The original, pre-review proposal remains unchanged at
`plans/07-audit-and-eval-harness.md`; the full review text is on PR #12.
