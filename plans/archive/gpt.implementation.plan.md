# GPT Unified Multi-Agent Implementation Plan

> Target: Claude Code across mobile/cloud, desktop app, and CLI on iOS, Android, Windows, Linux, and macOS.
>
> Source plans independently audited: `first.plan.md` and `fable.multi.agent.plan.md` on `main`.
>
> Status: implementation-ready master plan. This document supersedes neither source plan as historical evidence, but is the single implementation sequence to follow.

## 1. Executive decision

Implement the verified correctness and harness foundations from `first.plan.md`, then layer in the role coverage, routing, deterministic toolbelt, governance, and cost controls from `fable.multi.agent.plan.md`.

The implementation must use a **repo-scoped `.claude/` package as the canonical runtime**, not `~/.claude/`. Global installation may remain an optional convenience for local desktop/CLI users, but it cannot be the source of truth because Claude Code mobile/cloud sessions operate from the repository clone and do not reliably inherit local machine state.

The portable unit is:

```text
.claude/
├── agents/
├── commands/
│   └── ombudsman.md
├── hooks/
├── memory/
├── scripts/
├── settings.json
├── skills/
└── VERSION
```

A user invokes the team through a repo-visible command such as `/ombudsman`, or by the repository's configured orchestrator behavior where custom commands are unavailable. The same files must function on every supported surface. Platform-specific wrappers may exist, but core logic must be portable Python or declarative Markdown/JSON.

## 2. Independent audit: `first.plan.md`

### 2.1 Strengths

`first.plan.md` is the stronger implementation foundation because it is tied to observed repository defects and explicit harness mechanics.

It correctly prioritizes:

1. Broken hook environment propagation and the effectively nonfunctional project-memory path.
2. Hook failure behavior caused by `set -e` and unguarded helper execution.
3. Invalid telemetry assumptions about SubagentStop payload fields.
4. Non-idempotent settings merging during reinstall.
5. Weak tool boundaries where read-only agents retain write-capable shell access.
6. Missing integration verification between QA and final audit.
7. Corruption risk from manually relayed JSON between agents.
8. Transcript-derived token accounting as the measurement source of truth.
9. Test isolation through fixture-local `.claude/`, rather than an assumed `CLAUDE_HOME` override.
10. Numeric trial aggregation, severity levels, adoption checks, and regression thresholds.

Its build order is technically sound: repair the runtime and isolation primitives before trusting any behavioral benchmark.

### 2.2 Weaknesses and omissions

1. It treats the existing ten-agent roster as mostly fixed and therefore does not fully satisfy the requested coverage for data, design, strategy, computation, documentation, adversarial scrutiny, toolsmithing, and evaluation ownership.
2. It does not provide a complete task-size router, so an expansive team could be overused on trivial work.
3. Its mobile solution is directionally correct but not packaged as a single copyable runtime contract with a stable invocation command and a feature-parity test matrix.
4. Git-backed global memory is too operationally heavy for the required default. It should be optional, not required for core correctness.
5. It lacks a complete PR/CI policy describing which checks are blocking, which require secrets, how fork PRs behave, and how expensive evals are authorized.
6. It does not sufficiently distinguish deterministic CI from paid, stochastic model evaluation.
7. It lacks explicit change-impact selection, allowing the full expensive suite to run when only one narrow agent changed.
8. It does not define a capability-degradation contract for surfaces that cannot execute a local shell or persist files after the session.

### 2.3 Verdict

**Adopt as the correctness, security, telemetry, and evaluation-harness base.** Preserve its verified defects, isolation design, transcript parsing, staged implementation, and numeric acceptance thresholds.

## 3. Independent audit: `fable.multi.agent.plan.md`

### 3.1 Strengths

`fable.multi.agent.plan.md` is the stronger organizational and long-term operating model.

It adds:

1. Explicit owners for data, documentation, design, strategy, computation, adversarial scrutiny, deterministic tooling, and self-evaluation.
2. XS/S/M/L task classification to avoid paying for a large agent graph on small work.
3. A deterministic toolbelt and a feedback loop that converts repeated mechanical work into scripts.
4. Separation of proposer and approver for self-modifying agent changes.
5. Per-agent and per-task-class budgets.
6. Holdout evaluations to reduce benchmark overfitting.
7. Prompt-cache discipline, memory decay, drift detection, rollback, and runaway-cost circuit breakers.
8. A useful warning against adding agents merely to create role labels.

### 3.2 Weaknesses and incorrect assumptions

1. It describes existing token telemetry as reliable even though the current SubagentStop payload does not expose the claimed usage data. Token and model accounting must come from captured Claude stream transcripts when available.
2. It places toolbelt scripts under `~/.claude/`, conflicting with mobile/cloud parity. The toolbelt must live under repo `.claude/scripts/` and use repository-relative paths.
3. It assumes shell-based scripts such as `.sh` can be the universal implementation. iOS/Android cloud execution may use Linux internally, but Windows parity and repo portability require portable Python as the core, with tiny optional wrappers.
4. The roadmap adds agents before the full behavioral harness. New agent prompts should not ship before lint, fixture isolation, routing tests, and baseline capture exist.
5. A live automatic `git revert` is too dangerous. Detection may automatically open an issue or prepare a revert branch, but merge/revert authority must remain outside autonomous agents unless explicitly enabled by repository policy.
6. A hook cannot reliably prove that installed agent files came through an approved installer. Enforcement belongs in repository CI, checksums/manifests, protected branches, and code ownership.
7. A fixed “13+ agent” acceptance criterion rewards roster size rather than outcome quality. Agents should remain conditional modules selected by measurable need.
8. N=5 A/B trials may still be statistically weak. The harness needs adaptive sampling, confidence reporting, and spend ceilings rather than presenting one sample size as universally sufficient.
9. Skill-builder integration is underspecified and must be optional, version-detected, and nonblocking when unavailable.

### 3.3 Verdict

**Adopt its coverage model, routing, toolbelt concept, governance, holdout strategy, cache discipline, memory decay, and budget controls.** Reject global-path assumptions, unconditional roster expansion, autonomous rollback, and telemetry claims unsupported by actual event payloads.

## 4. Comparison and unified resolution

| Area | `first.plan.md` | Fable plan | Unified decision |
|---|---|---|---|
| Correctness audit | Detailed and verified | Mostly assumes current system works | Use First findings as mandatory phase 0 |
| Team coverage | Limited | Comprehensive | Add specialist modules after harness baseline |
| Mobile/cloud | Correct repo-scoped direction | Mostly global install oriented | Canonical repo `.claude/` package |
| Telemetry | Transcript is source of truth | Existing JSONL treated as authoritative | Transcript primary; local JSONL diagnostic only |
| Deterministic work | Specific memory/state/verify helpers | Broad toolbelt loop | Combine both under portable Python scripts |
| Evaluation | Strong isolation and grading contract | Strong A/B, holdout, governance | One harness with static, behavioral, comparative, holdout layers |
| CI/PR | Stacked PR suggestion | General CI wiring | Explicit required-check matrix and protected-branch policy |
| Self-modification | Harness-gated | Proposer/approver separation | Both; no direct writes to protected source |
| Rollback | Git-based | Suggests automatic rollback | Automated detection and revert PR, never silent merge/revert |
| Agent count | Existing ten | 18 total implied | Modular roster; only activated by routing need |

## 5. Non-negotiable architecture

### 5.1 Canonical distribution model

The repository contains a complete copyable `.claude/` directory. No installation step is required for the primary mode.

To use the team on another project, the user copies `.claude/` into that project's root. Provide one archive-ready directory and a manifest; do not require shell installation.

Optional convenience paths may be provided:

- a documented manual copy command;
- a release ZIP containing only `.claude/`;
- a Claude plugin package after repo-scoped behavior is proven;
- optional local synchronization into `~/.claude/` for desktop/CLI users.

The optional paths must not contain unique behavior. They only reproduce the canonical repo package.

### 5.2 Invocation contract

Create `.claude/commands/ombudsman.md` as the stable user-facing entrypoint.

Invocation behavior:

1. Load the orchestrator contract.
2. Classify task size and required capabilities.
3. Load only the agent definitions needed for that task.
4. Load a bounded memory brief.
5. Execute deterministic preflight scripts where supported.
6. Route agents and enforce review gates.
7. Produce a concise result plus machine-readable session summary.

Fallback: where custom slash commands are not exposed, `.claude/CLAUDE.md` or the repository instruction file must state that prompts beginning with `ombudsman:` invoke the same workflow.

### 5.3 Cross-platform implementation rules

- Core helpers: Python 3 standard library only.
- Shell and PowerShell files: wrappers only; no duplicated business logic.
- Paths: resolved relative to repository root or script location; never hard-coded to `~/.claude`.
- Encoding: UTF-8.
- Newlines: tolerant of LF and CRLF.
- Subprocess calls: argv arrays, never `eval`, shell interpolation, or sourced repo content.
- Atomic writes: temporary file plus replace.
- Locking: bounded lock files for shared state; stale-lock recovery.
- Network: denied by default in hooks and eval fixtures.
- Secrets: never stored in agent prompts, fixture transcripts, memory, or artifacts.

### 5.4 Capability parity definition

“Equal performance” must be tested as **behavioral parity**, not identical implementation internals.

Required on every surface:

- `/ombudsman` or documented fallback invocation;
- the same routing policy;
- the same agent prompts;
- the same quality gates;
- project memory reading;
- project memory updates where the surface permits branch writes;
- deterministic helper use where execution tools exist;
- equivalent final-answer quality thresholds.

Allowed degradation, which must be visible rather than silent:

- no persistent global memory when unavailable;
- no local telemetry file when storage is ephemeral;
- no headless A/B evaluation inside the mobile session;
- deferred CI evaluation after the mobile-created branch/PR is pushed.

Mobile is a first-class authoring and invocation surface; CI is the portable execution backstop for expensive or unavailable validations.

## 6. Team design

### 6.1 Core agents

Always available:

- `orchestrator`: routing, state, synthesis; does not inspect source directly.
- `researcher`: read-only evidence collection with path/line citations.
- `planner`: bounded implementation sequencing.
- `qa-reviewer`: functional and regression review.
- `auditor`: original-requirement coverage and final gate.
- `librarian`: bounded memory curation.
- `retrospective`: correction and failure learning.

### 6.2 Specialist modules

Loaded only when routing requires them:

- `frontend-engineer`
- `backend-engineer`
- `data-engineer`
- `test-engineer`
- `docs-writer`
- `design-lead`
- `strategist`
- `quant`
- `scrutineer`
- `toolsmith`
- `evaluator`

Do not encode roster size as a success metric. Each agent must justify its existence through distinct tool permissions, distinct judgment criteria, and measurable routing demand.

### 6.3 Task-size routing

- **XS:** direct answer or one specialist; no planner, scrutineer, or auditor unless risk requires it.
- **S:** researcher optional; one specialist; QA; auditor only for repository changes.
- **M:** researcher, planner, one or more specialists, QA, deterministic verify, auditor; scrutineer for security/data/concurrency or broad changes.
- **L:** strategist, researcher, planner, design lead where relevant, parallel specialists with nonoverlapping file ownership, integration verify, QA, scrutineer, auditor, docs writer.

Risk can promote a task independent of size. Authentication, authorization, secrets, migrations, destructive operations, CI configuration, agent/hook changes, and memory-system changes receive at least M-level review.

### 6.4 Checks and balances

- No implementing agent approves its own output.
- QA checks behavior and regression evidence.
- Scrutineer attacks assumptions, security, scale, and failure modes.
- Auditor checks the original user request and required deliverables.
- Evaluator approves agent/skill/hook changes using harness evidence.
- Toolsmith may propose scripts but cannot approve their inclusion.
- Retry loops are capped at two internal correction cycles.
- The third failure returns a structured impasse rather than consuming unbounded tokens.

## 7. Deterministic toolbelt

Create:

```text
.claude/scripts/
├── ombudsman.py
├── state.py
├── verify.py
├── memory.py
├── metrics.py
├── transcript.py
├── agentlint.py
├── hooklint.py
├── manifest.py
├── copy_package.py
└── toolbelt/
    ├── count.py
    ├── jsonmerge.py
    ├── diffstat.py
    ├── csvstat.py
    ├── todo_scan.py
    └── tests/
```

Mandatory first offloads:

1. Root and path derivation.
2. State transitions and schema validation.
3. Memory selection, deduplication, compaction, and size enforcement.
4. Settings merge and manifest generation.
5. Transcript normalization and token extraction.
6. Build/test command discovery and execution.
7. Diff statistics and changed-component detection.
8. Agent-file linting.
9. Evaluation result aggregation.
10. Portable package copying and checksum verification.

Agents must not spend tokens counting, sorting, merging JSON, calculating statistics, enumerating files, rendering large tables, or hand-copying structured payloads.

## 8. Memory architecture

### 8.1 Project memory

Canonical project memory lives under `.claude/memory/` and is versionable.

Separate:

- `facts/`: verified project facts;
- `decisions/`: architectural decisions with date and rationale;
- `mistakes/`: prevention rules and recurrence count;
- `sessions/`: short-lived handoff state;
- `archive/`: expired or superseded records.

Memory writes use structured files and deterministic validation. Raw prompts are untrusted input and must never be promoted directly into durable rules.

### 8.2 Global memory

Global memory is optional. Supported implementations may include a private repository or local user directory, but absence must not reduce core team correctness.

A project may opt in through `.claude/ombudsman.json`; no hook should silently clone or push a private repository.

### 8.3 Memory budgets

- Session brief target: 200 estimated tokens.
- Hard maximum configured and enforced by script.
- Facts include `last_confirmed` and source.
- Unreferenced project facts become archive candidates after 90 days.
- Mistake rules require evidence and recurrence count.
- Memory changes are included in PR review when generated in cloud/mobile sessions.

## 9. Telemetry and token accounting

### 9.1 Source of truth

For harness and CI measurements, parse `claude -p --output-format stream-json --verbose` transcripts.

Capture:

- input, output, cache-read, and cache-creation tokens;
- model per call;
- agent routing and order;
- tool invocations;
- blocked outcomes;
- retries;
- duration;
- task class;
- grader outcomes.

Hook JSONL remains a best-effort operational event log only. Fields not present in an actual hook payload must not be invented or reported as measurements.

### 9.2 Privacy

Stored transcripts for evaluation use synthetic fixtures only. Real-project telemetry records metadata and counts, not source content or full user prompts. Paths are normalized or hashed in shared artifacts.

### 9.3 Budgets

Version `.claude/evals/budgets.yaml` with:

- per-task-class median token budgets;
- per-agent invocation caps;
- retry caps;
- LLM-judge spend ceiling;
- total PR evaluation ceiling;
- cache-hit regression thresholds.

Budget changes require the same evaluator approval as agent changes.

## 10. Evaluation harness

### 10.1 Layout

```text
.claude/evals/
├── manifest.yaml
├── budgets.yaml
├── fixtures/
│   └── sample-project/
├── cases/
│   ├── golden/
│   └── holdout/
├── graders/
│   ├── deterministic.py
│   └── judge.md
├── runner/
│   ├── run.py
│   ├── compare.py
│   └── report.py
└── schemas/
```

Generated results go under ignored `eval-results/` locally and CI artifacts remotely.

### 10.2 Test layers

#### Layer 0: package and syntax

- Markdown frontmatter parse.
- JSON/YAML schema validation.
- Python compile.
- Shell/PowerShell wrapper syntax where present.
- Manifest/checksum consistency.
- No forbidden absolute paths.
- No duplicate hook registration.

#### Layer 1: deterministic unit tests

- memory dedup/compaction;
- state transitions;
- transcript parser fixtures;
- token aggregation;
- settings merge idempotency;
- copy-package behavior;
- permission policy;
- path traversal rejection;
- atomic-write and lock recovery;
- verify-command discovery.

#### Layer 2: installerless lifecycle tests

Using a temporary repository:

1. Copy `.claude/`.
2. Invoke static entrypoint.
3. Re-copy/update.
4. Confirm no duplicate settings or hooks.
5. Remove package.
6. Confirm unrelated project settings remain intact.
7. Assert no writes to real user home.

#### Layer 3: behavioral golden tests

Seed cases include:

- XS typo fix;
- factual question;
- small backend endpoint;
- frontend accessibility change;
- data migration;
- documentation-only task;
- ambiguous strategic request;
- numerical analysis requiring script use;
- security-sensitive change;
- correction and retrospective flow;
- memory recall;
- parallel integration failure;
- mobile/cloud repo-scoped invocation.

Deterministic assertions run first. LLM judging runs only for surviving cases and only for dimensions that cannot be programmatically verified.

#### Layer 4: comparative A/B tests

Compare base and candidate using paired fixture seeds. Use adaptive trials:

- start with 3;
- increase to 5 or 9 when confidence is insufficient and spend remains under cap;
- report PASS, FAIL, or INCONCLUSIVE;
- never treat a single run as proof.

#### Layer 5: holdout release tests

Holdout cases run before release or changes to routing, evaluator, judge prompt, or budgets. They are not exposed during prompt tuning.

#### Layer 6: live observation

After merge, observe aggregate metadata for a defined window. A regression creates an issue or revert PR. It must not silently revert or merge code.

### 10.3 Grading contract

Assertions have severity:

- `critical`: all trials must pass;
- `gate`: configured majority threshold;
- `soft`: informational;
- `budget`: fails when quality is unchanged and cost exceeds threshold.

Candidate acceptance requires:

- no new critical failure;
- suite gate pass-rate drop no greater than 5 percentage points;
- target behavior adopted in at least two thirds of trials;
- median tokens not regressed by more than 10% unless quality materially improves;
- no holdout regression at release;
- no unexplained increase in blocked or retry rates.

Skill-builder or skill-creator scoring is an optional additional signal. Its absence must not fail CI, and its score cannot override repository-specific deterministic failures.

## 11. PR and CI enforcement

### 11.1 Branch protection

Protect `main` with:

- pull requests required;
- no direct pushes;
- required up-to-date branch;
- required status checks;
- conversation resolution;
- at least one human approval for agent, hook, evaluator, budget, or workflow changes;
- CODEOWNERS for `.claude/agents/`, `.claude/hooks/`, `.claude/evals/`, `.github/workflows/`, and budget files.

### 11.2 Pull-request workflow

Every PR runs free deterministic checks:

1. `package-lint`
2. `agent-lint`
3. `hook-lint`
4. `unit-tests`
5. `security-static`
6. `copy-lifecycle`
7. `platform-path-tests` on Linux, Windows, and macOS runners
8. `changed-component-map`

Agent, skill, routing, hook, memory, evaluator, or budget changes additionally require behavioral evaluation.

### 11.3 Expensive evaluation policy

Because model evaluations require credentials and money:

- PRs from trusted branches run affected golden cases automatically.
- Fork PRs run deterministic checks only until manually approved.
- Full A/B runs use a protected environment with spend limits.
- Release PRs run the complete golden and holdout suites.
- A nightly scheduled workflow may track drift against pinned models, but it is nonblocking until confirmed.

Required CI artifacts:

- normalized result JSON;
- human-readable report;
- token/cost delta table;
- routing trace;
- failed assertion evidence;
- package manifest;
- platform matrix result.

### 11.4 Change-impact selection

`changed-component-map` determines affected tests. Examples:

- docs-only change: lint and docs tests;
- one specialist prompt: that specialist's cases plus shared routing cases;
- orchestrator, evaluator, judge, budgets, hooks, or settings: full golden suite;
- release/version change: golden plus holdout plus platform matrix.

A developer can request the full suite with a PR label. CI must show which tests were skipped and why.

### 11.5 Merge gate

The final required `ombudsman-evaluation` check aggregates all required checks and refuses success when:

- a required artifact is absent;
- the candidate was evaluated against the wrong base SHA;
- token data is null for a run expected to expose usage;
- changed components lack mapped cases;
- the candidate exceeds spend caps without explicit approval;
- mobile/cloud smoke validation is missing for release-affecting changes.

## 12. Mobile and cross-surface validation

### 12.1 Automated parity matrix

CI validates the repo package on:

| Surface proxy | Validation |
|---|---|
| Linux CLI | Full headless behavioral suite |
| Windows CLI | Path, wrappers, copy lifecycle, selected behavioral smoke |
| macOS CLI | Path, permissions, copy lifecycle, selected behavioral smoke |
| Claude Code cloud/mobile | Repo-scoped `.claude/` fixture, no user-home dependency, branch-persistent memory behavior |
| iOS/Android user flow | Manual release checklist from mobile app against a dedicated fixture repo |

### 12.2 Mobile release checklist

For each release candidate:

1. Open fixture repo from Claude Code mobile.
2. Invoke `/ombudsman` or fallback phrase.
3. Run one XS and one M task.
4. Confirm routing and gates.
5. Confirm changes and project memory appear in the session branch.
6. Open a PR from mobile.
7. Confirm CI runs and reports the behavioral suite.
8. Confirm no dependency on local `~/.claude/`.
9. Repeat on at least one iOS and one Android device before stable release.

Store the checklist result as a release artifact or signed issue template. Mobile parity is a release gate, not an undocumented assumption.

## 13. Security requirements

1. Read-only agents receive Read/Glob/Grep and no unrestricted shell where avoidable.
2. Engineers receive the narrowest write and execution permissions feasible.
3. Deny destructive commands, direct push, hard reset, credential reads, network tools, and out-of-repo writes by default.
4. Hooks never execute repository-controlled text as code.
5. All payload text is untrusted and JSON-encoded with standard serializers.
6. No prompt or transcript may override tool permissions.
7. Fixture runs use network denial and temporary directories.
8. CI secrets are unavailable to fork PR execution.
9. Generated memory is reviewed like code when committed.
10. Hook and workflow changes always invoke scrutineer/security cases.

## 14. Implementation phases

### Phase 0 — Repair current foundations

- Fix root derivation and project-memory propagation.
- Guard helper failures in all hooks.
- Make settings merge idempotent.
- Descope unsupported telemetry fields.
- Correct pricing tables only after verifying current values during implementation.
- Harden JSON serialization and untrusted retrospective inputs.
- Add matching tests before changing behavior.

**Exit:** current system passes deterministic lifecycle tests and no longer writes null usage claims as authoritative telemetry.

### Phase 1 — Canonical repo package and invocation

- Create canonical `.claude/` package.
- Add `/ombudsman` command and fallback invocation.
- Move core logic to portable Python.
- Add manifest, version, and copy utility.
- Remove runtime dependency on global paths.

**Exit:** copying `.claude/` into a clean fixture is sufficient to invoke the team.

### Phase 2 — Static harness and CI foundation

- Build schemas, linters, unit tests, lifecycle tests, security checks, and platform matrix.
- Add branch protection documentation, CODEOWNERS, and required workflows.
- Commit iteration-0 deterministic baseline.

**Exit:** every subsequent agent or hook file is gated by free deterministic CI.

### Phase 3 — Behavioral harness and trustworthy telemetry

- Implement stream transcript parser.
- Add fixture project and golden cases.
- Add deterministic graders and optional LLM judge.
- Implement adaptive A/B comparison and report artifacts.
- Record base SHA, candidate SHA, model IDs, and runner version.

**Exit:** a deliberately degraded agent is caught and token counts are non-null.

### Phase 4 — Routing and specialist wave 1

- Add XS/S/M/L and risk promotion.
- Add data engineer, docs writer, and scrutineer.
- Update coverage and routing cases.
- Add integration verify between QA and auditor.

**Exit:** specialists are invoked only on relevant cases and improve coverage without broad token regression.

### Phase 5 — Deterministic toolbelt and memory hardening

- Add state, memory, verification, counting, merge, diff, CSV, TODO, and manifest helpers.
- Replace hand-copied JSON relays with state-file references.
- Enforce memory budgets, decay, archive behavior, and schema validation.

**Exit:** targeted classes show measurable token reduction with quality steady.

### Phase 6 — Specialist wave 2 and governance

- Add design lead, strategist, quant, toolsmith, and evaluator.
- Enforce proposer/approver separation.
- Add invocation caps, retry limits, and spend circuit breakers.
- Add holdout suite.

**Exit:** self-modification produces a PR and harness report; no agent can directly approve or merge its own change.

### Phase 7 — Mobile/cloud parity and optional plugin distribution

- Validate project-scoped memory branch persistence.
- Complete iOS and Android release checks.
- Add optional plugin/release ZIP distribution after repo package parity is proven.
- Document unsupported surface capabilities and CI fallback.

**Exit:** mobile can invoke the same team on any repo containing `.claude/`, create changes, and rely on PR CI for full validation.

### Phase 8 — Cost controls and live drift monitoring

- Add budgets, trend reports, cache accounting, drift detection, and issue/revert-PR automation.
- Add nightly nonblocking drift suite.
- Add release rollback procedure.

**Exit:** cost and quality regressions are detected with evidence and produce reviewable remediation, not silent autonomous changes.

## 15. Required files

### Create

- `gpt.implementation.plan.md`
- `.claude/commands/ombudsman.md`
- `.claude/ombudsman.json`
- `.claude/VERSION`
- `.claude/agents/{data-engineer,docs-writer,design-lead,strategist,quant,scrutineer,toolsmith,evaluator}.md`
- `.claude/scripts/*.py`
- `.claude/scripts/toolbelt/*`
- `.claude/evals/**/*`
- `.github/workflows/ombudsman-static.yml`
- `.github/workflows/ombudsman-eval.yml`
- `.github/workflows/ombudsman-release.yml`
- `.github/CODEOWNERS`
- `.github/pull_request_template.md`
- `.github/ISSUE_TEMPLATE/mobile-parity.yml`

### Modify or mirror

- current `claude-system/agents/*`
- current `claude-system/hooks/*`
- metrics scripts
- settings fragment
- README and architecture documentation

During migration, avoid maintaining two divergent implementations. Generate optional legacy/global packaging from canonical `.claude/`, or remove it after one compatibility release.

## 16. Whole-system acceptance criteria

1. A clean project becomes Ombudsman-enabled by copying only `.claude/`.
2. Invocation works through `/ombudsman` or the documented fallback on desktop, CLI, and mobile/cloud.
3. No primary behavior depends on files outside the repository.
4. Linux, Windows, and macOS CI matrices pass path and lifecycle tests.
5. iOS and Android release smoke tests pass.
6. XS tasks use no more than two agent calls unless risk promotion applies.
7. M/L repository changes pass QA, deterministic integration verify, and auditor; high-risk tasks also pass scrutineer.
8. Every requested competency has a routed owner, but irrelevant agents are not loaded.
9. Token accounting comes from real transcript usage and is non-null in behavioral runs.
10. Agent, skill, hook, routing, evaluator, judge, or budget changes cannot merge without appropriate harness evidence.
11. A deliberately degraded agent or broken hook is caught by CI.
12. Re-copy/update is idempotent and preserves unrelated project settings.
13. Eval runs never write to real user home or access network by default.
14. Memory remains bounded, sourced, reviewable, and portable.
15. Deterministic offloads produce measured token savings or are rejected.
16. No autonomous agent can directly merge, silently revert, raise its own budget, or approve its own changes.
17. Release artifacts include the exact `.claude/` package, manifest, evaluation report, token deltas, and mobile parity record.

## 17. PR sequence

Implement as small stacked or sequential PRs targeting `main`:

1. `repair/runtime-foundations`
2. `package/repo-scoped-claude`
3. `test/static-harness-ci`
4. `test/behavioral-harness-telemetry`
5. `agents/routing-wave-one`
6. `tooling/deterministic-toolbelt-memory`
7. `agents/governance-wave-two`
8. `platform/mobile-cloud-parity`
9. `ops/cost-drift-controls`

Every PR must state:

- changed capability;
- source-plan findings addressed;
- affected eval cases;
- deterministic checks;
- behavioral result where required;
- token and cost delta;
- security impact;
- mobile/cross-platform impact;
- rollback method.

## 18. Final recommendation

Do not begin by adding the full specialist roster. First make the current runtime measurable, portable, and test-isolated. Then add routing and specialists behind the harness. This order prevents the project from scaling an unreliable foundation and is the only credible path to the requested equal mobile, desktop, and CLI behavior.
