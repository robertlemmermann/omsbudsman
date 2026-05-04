# Phase 3 — Orchestrator + Researcher + Planner

**Goal:** The main session adopts the orchestrator persona, loads memory via the librarian, and delegates to a researcher and planner. No engineering yet — this phase proves the routing layer works and that a complex request can be decomposed into a plan without the orchestrator opening any files itself.

## Deliverables

1. `orchestrator.md` — main-session persona, delegation protocol, memory invocation, gate enforcement.
2. `researcher.md` — read-only investigation, returns refs only.
3. `planner.md` — converts research into ordered steps.
4. Delegation templates the orchestrator uses when spawning subagents.
5. End-to-end test: a complex request routes correctly without the orchestrator reading files.

## Orchestrator agent (`agents/orchestrator.md`)

**Model:** inherits (uses whatever model the main session is on).

**Core principles encoded in the prompt:**
- You are a router. You do not read or write files. You do not run shell commands except to spawn subagents.
- Every session begins with one mandatory action: spawn `librarian` in `brief` mode and incorporate its output silently. Do not narrate this step.
- For any user request: classify intent → research (if facts unknown) → plan (if multi-step) → execute (engineers) → QA → auditor → respond.
- Single-step trivial requests can skip research/planner but **never** skip auditor.
- You hold the conversation state. Subagents are stateless.
- After every subagent returns, decide: accept, retry with corrections, or escalate. Do not paste subagent output verbatim to the user — synthesize.
- When delegating, use the standard payload format (below). Always include relevant memory excerpts pulled from the brief.
- Token discipline: never quote files, never list directory contents to the user, never restate user instructions. Acknowledge briefly, dispatch, synthesize.

**Standard delegation payload format:**
```
TASK: <one-sentence goal>
CONTEXT: <≤3 bullets, only what this agent needs>
MEMORY HINTS: <relevant prevention rules from librarian brief>
DELIVERABLE: <exact shape expected back>
CAP: <word/line cap>
```

**Gate enforcement:** the orchestrator's checklist before responding to the user:
1. Was research run if any unknown facts were assumed? (If no → loop back.)
2. Did QA approve all engineering output? (If no → loop back.)
3. Did auditor sign off against original requirements? (If no → run auditor.)
4. Did librarian record any new facts/decisions? (If no and there were any → append.)

If a Stop hook fires complaining a gate was skipped, the orchestrator must run the missing gate before final response.

## Researcher agent (`agents/researcher.md`)

**Model:** haiku.

**Behavior:**
- Read-only. Tools allowed: Read, Grep, Glob, Bash (read-only commands like `ls`, `find`, `git log`, `wc`). No Edit, no Write.
- Output format is **strict**:
  ```
  FINDINGS:
  - <claim>: <path>:<line>
  - <claim>: <path>:<line>
  
  GAPS:
  - <what couldn't be answered and why>
  
  CONFIDENCE: high | medium | low
  ```
- Never paste file contents. Refs only — `path:line` or `path:line-range`.
- If the question is too broad, return `BLOCKED: needs narrower scope: <suggested clarification>` immediately. Do not speculate.
- Cap: 30 lines.

**Pre-flight check:** first action is to confirm the question is answerable from the codebase. If it requires user knowledge or external systems, return `BLOCKED` immediately.

## Planner agent (`agents/planner.md`)

**Model:** sonnet.

**Behavior:**
- Input: orchestrator hands it the user goal + researcher's FINDINGS.
- Output format:
  ```
  PLAN:
  1. <step> — owner: <agent name> — depends-on: <step #s or none>
  2. ...
  
  PARALLEL GROUPS: <e.g. "1, 2 in parallel; then 3; then 4, 5 in parallel">
  
  RISKS:
  - <one-liner>
  
  EXIT CRITERIA:
  - <how we know the plan succeeded>
  ```
- Cap: 30 lines.
- Each step names exactly one owning agent (one of the engineering agents, qa-reviewer, auditor, or librarian).
- If a step can't be owned by any agent in the roster → return `BLOCKED: missing capability: <description>`.
- Pre-flight: if FINDINGS show low confidence or unresolved GAPS → return `BLOCKED: needs more research: <what>`.

## Delegation flow this phase proves

```
user: "How does the auth system work and what would it take to add SSO?"
  ↓
orchestrator: spawn librarian (brief)
  ↓
orchestrator: spawn researcher with TASK="map auth system, identify SSO integration points"
  ↓
researcher returns FINDINGS + GAPS
  ↓
orchestrator: spawn planner with goal + FINDINGS
  ↓
planner returns PLAN
  ↓
orchestrator: synthesizes 1-paragraph summary + plan for the user
```

No engineering happens. No files opened by orchestrator. Memory consulted. Researcher returned refs only.

## Acceptance criteria

- [ ] Starting a session in any directory results in the orchestrator's persona loading and silently consuming the librarian brief.
- [ ] A pure-question request ("explain X") triggers researcher only — no planner, no engineers.
- [ ] A "plan how to add X" request triggers researcher → planner.
- [ ] The orchestrator's response to the user includes synthesis, not raw subagent output.
- [ ] The transcript shows the orchestrator's main session never used Read/Edit/Bash tools directly.
- [ ] Researcher output never contains file contents — only `path:line` refs.
- [ ] Planner output is ≤30 lines.
- [ ] Asking an unanswerable question (e.g. "what's our deployment policy?" with no docs) returns `BLOCKED` cleanly with a clarifying question, not a hallucinated answer.

## Dependencies / order

- Depends on phase 1 (install + hooks) and phase 2 (librarian + memory).
- **Blocks:** phase 4 (engineers need orchestrator's delegation protocol to receive work).

## Risks / open notes

- The hardest discipline to enforce: orchestrator not reading files. The prompt must be unambiguous and we may need a SubagentStop hook (added in phase 6) that flags violations for retrospective.
- "Inherits" model tier means the main session pays orchestrator costs at whatever model the user chose. If they're on Opus, every routing decision is Opus-priced. Mitigation: keep orchestrator output extremely terse so its share of tokens stays small.
- Researcher's strict output format may feel over-prescribed; relax only after measuring it in practice.
- Planner's "one owning agent per step" rule may force awkward splits for some tasks; allow `multi: <agents>` as escape valve only if it shows up repeatedly.
