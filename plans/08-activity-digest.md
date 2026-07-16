# Phase 8 — User-Facing Activity Digest

**Goal:** The pipeline does a lot per turn — research, planning, parallel engineering, QA retries, scrutineer review, verify runs, audit, memory writes — and deliberately hides all of it. That opacity cuts both ways: the user can't tell what was verified, what was left open, or what the system just learned. This phase surfaces a clean, concise "what happened" digest at the end of each worked turn, without reopening the door to agent-narration noise.

**Relation to phase 7's team status display:** complementary, not overlapping. The status line (`plans/07-team-status-display.md`) is a live, ephemeral, zero-LLM-cost terminal channel showing which agent is active *right now*; it renders nowhere on mobile/web. The activity digest is part of the assistant's final text — it works on every surface and records the *outcome* of the turn: what changed, what was verified, what remains open.

## Design principles

1. **Digest, not narration.** Prose like "I dispatched the backend engineer, then QA…" stays banned. Activity surfaces in exactly one place: a capped, structured block after the main answer.
2. **Traceable, never invented.** Every digest line must come from a structured return the orchestrator holds (engineer `SUMMARY`/`CHANGES`/`TESTS RUN`, QA verdicts, scrutineer findings, the `verify.py` result, auditor `DIGEST`/`USER SUMMARY`, librarian `appended` confirmations).
3. **Honest history.** Retries and QA failures that were later fixed appear ("QA 3/3 pass, after 1 retry"). Verification claims report only what actually ran.
4. **Concise by omission.** Empty lines are dropped, never padded with "none". Hard cap of 7 lines. File lists collapse into counts.
5. **Proportional to the turn.** Turns that dispatched engineers get the full digest; plan requests get an `Open questions:` line only when the researcher reported gaps; XS/conversational/pure-question turns and escalations get nothing.

## Digest shape (rendered by the orchestrator)

```
---
**What happened**
- Changed: <N file(s)> — <path> (<why>); …
- Tests: <command / verify.py> → <result>, or "none run — <reason>"
- Review: QA <passed>/<total> steps[, after N retries][; scrutineer: <n findings>][; audit: <verdict>]
- Open: <follow-ups / advisories>            [omitted when empty]
- Learned: <memory item recorded this turn>  [omitted when empty]
```

## Deliverables

1. `.claude/agents/orchestrator.md` — new **Activity digest** section: shape, sourcing rules, caps, per-class applicability; synthesis-style rule updated so the digest is the sole surface for pipeline activity; retrospective and memory write-back sections reconciled (process stays silent, recorded outcome earns one `Learned:` line).
2. `.claude/agents/auditor.md` — new `DIGEST:` output block (`changed` / `verified` / `open`) so gate 2 hands the orchestrator pre-distilled, plain-English raw material; inputs carry engineer `SUMMARY` lines; line cap raised 50 → 55.
3. `.claude/agents/{backend,frontend,data,test}-engineer.md` — new leading `SUMMARY:` line in the output contract: one plain-English sentence of outcome ("the /orders endpoint now rejects duplicates"), not mechanics ("added a check in orders.py").
4. README — document what the user sees after a worked turn.

## Non-goals

- No hook, telemetry, or gate-state schema changes. The digest is composed from context the orchestrator already holds.
- No digest for the librarian brief, gate-state maintenance, or retrospective mechanics — internals stay internal.
- No per-agent cost/token reporting in the digest; that remains `metrics.py` territory.
- No changes to the phase-7 status line.

## Acceptance criteria

- A turn that dispatched engineers ends with a digest of ≤7 lines covering changes, tests, and review outcome, with `Open`/`Learned` present only when non-empty.
- A pure-question or conversational turn produces no digest.
- A turn where QA failed once then passed shows the retry in the `Review:` line.
- A session that records a memory item shows one `Learned:` line describing the fact, with no mention of the librarian or retrospective machinery.
- `python3 harness/run.py --static` passes with the agent-file edits.
