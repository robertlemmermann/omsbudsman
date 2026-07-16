# Phase 7 — User-Facing Activity Digest

**Goal:** The pipeline does a lot per turn — research, planning, parallel engineering, QA retries, audit, memory writes — and until now deliberately hid all of it. That opacity cuts both ways: the user can't tell what was verified, what was left open, or what the system just learned. This phase surfaces a clean, concise "what happened" digest at the end of each worked turn, without reopening the door to agent-narration noise.

## Design principles

1. **Digest, not narration.** Prose like "I dispatched the backend engineer, then QA…" stays banned. Activity surfaces in exactly one place: a capped, structured block after the main answer.
2. **Traceable, never invented.** Every digest line must come from a structured subagent return the orchestrator holds (engineer `SUMMARY`/`CHANGES`/`TESTS RUN`, QA verdicts, auditor `DIGEST`/`USER SUMMARY`, librarian `appended` confirmations).
3. **Honest history.** Retries and QA failures that were later fixed appear ("QA 3/3 pass, after 1 retry"). Verification claims report only what actually ran.
4. **Concise by omission.** Empty lines are dropped, never padded with "none". Hard cap of 7 lines. File lists collapse into counts.
5. **Proportional to the turn.** Implementation turns get the full digest; plan turns get an `Open questions:` line only when the researcher reported gaps; pure-question, conversational, and escalation turns get nothing.

## Digest shape (rendered by the orchestrator)

```
---
**What happened**
- Changed: <N file(s)> — <path> (<why>); …
- Tests: <command> → <result>, or "none run — <reason>"
- Review: QA <passed>/<total> steps[, after N retries][; audit: <verdict>]
- Open: <follow-ups / advisories>            [omitted when empty]
- Learned: <memory item recorded this turn>  [omitted when empty]
```

## Deliverables

1. `orchestrator.md` — new **Activity digest** section: shape, sourcing rules, caps, per-intent applicability; synthesis-style rule updated so the digest is the sole surface for pipeline activity; retrospective and memory write-back sections reconciled (process stays silent, recorded outcome earns one `Learned:` line).
2. `auditor.md` — new `DIGEST:` output block (`changed` / `verified` / `open`) so the final gate hands the orchestrator pre-distilled, plain-English raw material; line cap raised 40 → 50.
3. `backend-engineer.md`, `frontend-engineer.md`, `test-engineer.md` — new leading `SUMMARY:` line in the output contract: one plain-English sentence of outcome ("the /orders endpoint now rejects duplicates"), not mechanics ("added a check in orders.py").
4. README — document what the user sees after a worked turn.

## Non-goals

- No hook or telemetry changes. The digest is composed from context the orchestrator already holds; the gate-state file schema is untouched.
- No digest for the librarian brief, gate-state maintenance, or retrospective mechanics — internals stay internal.
- No per-agent cost/token reporting in the digest; that remains `metrics.sh` territory.

## Acceptance criteria

- An implementation turn ends with a digest of ≤7 lines covering changes, tests, and review outcome, with `Open`/`Learned` present only when non-empty.
- A pure-question turn produces no digest.
- A turn where QA failed once then passed shows the retry in the `Review:` line.
- A session that records a memory item shows one `Learned:` line describing the fact, with no mention of the librarian or retrospective machinery.
