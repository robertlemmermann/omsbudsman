---
description: List recent mistake-prevention rules and forget one. Use when a wrongly-learned rule is polluting your memory.
allowed-tools: Task
---

You are deleting a learned mistake-prevention rule from the librarian's memory. The rule was probably wrong (false retrospective, project-specific quirk over-promoted, contradicted by a later session). Removal is soft: the entry is moved to `.archive/`, not destroyed.

## Step 1: list candidates

Spawn the librarian with `mode: list` to see the most recent N rules across both tiers:

```
mode: list
filter: recent
limit: 10
```

Show the user the returned bullets verbatim — each line is `- <id> | <label> | tier=... | recurrences=N | tags=...`. The `<id>` is what librarian's `mode: forget` accepts.

If the user supplied an argument with this command (`$ARGUMENTS`), pass it as `filter:` instead of `recent` so they can narrow by tag or substring (e.g. `/forget-rule auth` lists rules tagged `auth`).

## Step 2: ask which to forget

Wait for the user's choice. Accept either:
- A bare `<id>` from the list.
- A line number from the list (1-based).
- "cancel" / "abort" — exit without doing anything.

If the user says nothing actionable, ask one short clarifying question. Do not guess.

## Step 3: forget

Spawn the librarian with:
```
mode: forget
id: <chosen id>
```

The librarian moves the entry to `<tier>/.archive/forget-<UTC-date>.md` and reports `forgotten: <tier> <section> <label>`.

Confirm to the user with one sentence: which rule was archived and where to find the archive.

## Discipline

- One forget per invocation. If the user wants to remove several, run the command again.
- Do not narrate the librarian's intermediate output to the user. Synthesize.
- If `librarian` returns `BLOCKED`, surface the blocker directly and stop.
