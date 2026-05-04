# Phase 5 — Retrospective + Mistake Learning

**Goal:** The team learns from every mistake and never repeats one silently. Corrections during a session are detected automatically, post-mortemed at session end, and turned into prevention rules that surface to the right agent at the start of the next session. Repeat mistakes are flagged loudly and amplified into stronger rules.

## Deliverables

1. `retrospective.md` — the post-mortem agent.
2. `UserPromptSubmit` hook — broad correction detection, sets `RETRO_NEEDED` state.
3. Stop hook update — when `RETRO_NEEDED`, run retrospective before letting the session end.
4. Repeat-detection logic in librarian — incoming mistakes matched against existing prevention rules; matches increment recurrence and amplify the rule.
5. Prevention-rule injection — orchestrator's pre-flight on each subagent dispatch includes relevant prevention rules.
6. End-to-end test: simulate a correction → verify a mistake file is created → start a new session → verify the rule is surfaced.

## Correction signal detection (`UserPromptSubmit` hook)

**Sensitivity:** broad. The user wants to learn from any mistake, especially repeats. False positives are acceptable cost.

**Detection method (in the hook script):** regex against the user's incoming prompt. Match if any of:
- `\b(no|nope|wrong|incorrect|broken|fail(ed|ing)?|bug)\b`
- `\b(actually|instead|rather|but)\b.*\b(should|shouldn'?t|need(s|ed)?)\b`
- `\b(you|claude|the agent)\b.*\b(missed|forgot|didn'?t|should have|were supposed)\b`
- `\b(fix|revert|undo|rollback|redo)\b`
- `\b(why|how come)\b.*\b(did|didn'?t)\b`
- explicit: `\b(retrospective|post-?mortem|learn from this)\b`

If any match → write `RETRO_NEEDED=1` plus the prompt text to `~/.claude/state/session-<id>.json`.

The hook also passes through to the orchestrator — it never blocks the prompt.

**Hook output:** silent on no match. On match: writes state, prints nothing (so it doesn't pollute the user-facing transcript).

## Retrospective agent (`agents/retrospective.md`)

**Model:** sonnet.

**Triggered by:** Stop hook when `RETRO_NEEDED=1`. Receives:
- The triggering user prompt(s).
- The recent assistant turns leading up to the correction.
- The relevant agent outputs (QA verdicts, engineer changes, auditor verdict) for the failed sequence.
- Current memory brief (so it knows what was already learned).

**Output format:**
```
RETROSPECTIVE:

WHAT WENT WRONG: <one paragraph, concrete>

ROOT CAUSE: <which agent/check failed and why>
- Agent: <name>
- Failure mode: <missed-edge-case | wrong-assumption | scope-violation | tool-misuse | memory-not-consulted | other>

WAS THIS A REPEAT?: yes | no
- If yes: matches existing rule "<rule label>" in <file>; recurrence count now <N>.

PREVENTION RULE:
- New rule (or amplified rule): "<imperative one-liner>"
- Tags: <tag1>, <tag2>
- Owning agent: <which agent's pre-flight should include this>
- Tier: project | global

LIBRARIAN APPEND PAYLOAD:
{
  "tier": "<project|global>",
  "section": "<topic file name>",
  "entry": "<full mistake entry per the standard format>"
}
```

After the retrospective produces the payload, the orchestrator dispatches librarian with `mode: append` to commit it.

**Caps:** 40 lines.

## Repeat detection (in librarian's append mode)

When librarian receives an `append` payload for a `mistake/` file:
1. Load the target `mistakes/<topic>.md` file.
2. For each existing entry, compute similarity (normalized lowercase + token jaccard, threshold ~0.6) against the incoming `What went wrong` line.
3. **Match found** → amplify:
   - Increment `Recurrences` counter.
   - Update `Last seen`.
   - **Sharpen the rule**: replace with the more concrete of (existing rule, new rule). If they're complementary, concatenate as a numbered list.
   - Promote tier: if recurrence count crosses 3 AND the rule is currently `project` tier, copy to `global` tier and mark with `[promoted from project]`.
   - Return `recurrence: <N> (rule sharpened)` to retrospective.
4. **No match** → standard append.

Repeat amplification is the system's main self-improvement mechanism. The harder a mistake repeats, the louder its rule becomes.

## Prevention-rule injection (orchestrator behavior)

Already specified in phase 3, made concrete here:

When orchestrator dispatches any subagent, its delegation payload's `MEMORY HINTS` field is populated by selecting from the librarian brief:
- All mistakes tagged with the target agent's name.
- All mistakes tagged with any tag matching the current task's keywords.
- Capped at 5 hints; if more match, the highest-recurrence ones win.

Subagents are prompted to read MEMORY HINTS first and either explicitly satisfy each one in their output or explicitly justify why one doesn't apply.

## Stop hook update

`stop.sh` / `stop.ps1` (extending phase 4 version):
1. Read `~/.claude/state/session-<id>.json`.
2. If `auditor_verdict` is null AND work was done → block (existing behavior).
3. If `RETRO_NEEDED=1` → block with message: `corrections happened this session — run retrospective before exiting`.
4. Once both are satisfied → run librarian compact (silent), then exit 0.

The orchestrator's prompt (updated this phase) handles both blockers: on receiving a Stop nag, runs the missing step (auditor and/or retrospective), then completes.

## Acceptance criteria

- [ ] Saying "no, that's wrong, you missed X" in a session sets `RETRO_NEEDED=1`.
- [ ] Saying "actually let me think" alone does NOT trigger (regex tuned to need either negation or correction context).
- [ ] At session end with `RETRO_NEEDED=1`, retrospective runs and produces a structured payload.
- [ ] Librarian appends a new `mistakes/<topic>.md` entry on first occurrence.
- [ ] Repeating the same mistake in a later session → recurrence counter increments, rule is sharpened.
- [ ] After 3 recurrences of a project-tier mistake, it appears in global memory with promotion note.
- [ ] Next session, the relevant agent's MEMORY HINTS includes the rule.
- [ ] Subagent output references the prevention rule (either satisfies it or justifies skipping).
- [ ] False-positive rate measurable: count of `RETRO_NEEDED` triggers vs actual mistakes recorded; reviewable in metrics (phase 6).

## Dependencies / order

- Depends on phases 1, 2, 3, 4 (needs hooks, librarian, orchestrator, gates all working).
- **Blocks:** none functionally, but phase 6 telemetry uses retrospective signals to compute "learning rate."

## Risks / open notes

- Broad regex will fire on benign prompts ("no, let's do X first"). The retrospective itself filters these out: if it can't identify a concrete `WHAT WENT WRONG`, it returns `NO RETRO NEEDED: false positive` and clears the flag without writing anything. This is deliberately a second filter — broad detection, narrow learning.
- Repeat detection by token jaccard will miss paraphrases. Acceptable for v1; revisit with semantic similarity later if recurrences go undercounted.
- Tier promotion (project → global at 3 recurrences) might over-promote project-specific noise. Mitigation: retrospective can override by tagging an entry `keep-local`.
- Prevention-rule injection adds tokens to every subagent dispatch. Cap at 5 hints prevents bloat; phase 6 telemetry will measure the cost.
- A mistake recorded once and never repeated still pays for itself by being injected into future agents — but if the rule is too narrow it bloats prompts. Librarian's compact pass should drop never-recurring rules after the 90-day window unless tagged `permanent`.
