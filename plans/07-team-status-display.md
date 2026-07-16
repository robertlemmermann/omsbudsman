# Phase 7 — Team status display

A live, in-chat status line that shows which agent is currently working, what
it's doing in one succinct phrase, and the recent flow of the team — with
emoji per role and color per status. Zero LLM cost; updated in real time.

## Goals

1. **Visibility.** The user can see at a glance whether the orchestrator is
   waiting on a researcher, a planner, or an engineer — and whether QA passed.
2. **Free.** No new agent calls. No librarian invocations. Hooks + a render
   script only.
3. **No persona drift.** The orchestrator's "never narrate which agents you
   used" rule stays intact. The harness shows the team state through a
   separate channel (`statusLine`), not the assistant's text.
4. **Cross-platform parity.** Bash + PowerShell renderers, identical output.

## Why not a new agent or expanded librarian?

Considered both; rejected.

- **A new "herald" agent** would need to summarize work the orchestrator
  already sees and would burn tokens on every dispatch. The summary line is
  derivable from data hooks already capture (the `Task` payload's
  `description` field is literally a one-line goal; the agent's response's
  first non-empty line is its punchline).
- **Expanding the librarian** mixes responsibilities. The librarian curates
  durable, slow, cross-session memory. A live status line is ephemeral,
  fast, and per-tool-call. Pushing it into the librarian would either
  multiply Haiku invocations or add a parallel "fast path" inside the
  librarian — both worse than a 50-line shell hook.

The right primitive is Claude Code's built-in `statusLine` config combined
with a `PreToolUse` hook scoped to the `Task` tool.

## Components

### 1. `hooks/pre-tool-use.sh` / `.ps1` (new)

Triggered on every `PreToolUse` event with `matcher: "Task"`. Reads the
incoming JSON payload, extracts:
- `tool_input.subagent_type` → which agent
- `tool_input.description` → one-sentence goal (the orchestrator's standard
  delegation payload's `TASK:` line, or the `description` arg)

Appends a new entry to `~/.claude/state/agents-<session_id>.json` with
`status: "active"`. Capped to the last 30 entries.

Always exits 0; never blocks the tool call.

### 2. `hooks/subagent-stop.sh` / `.ps1` (modified)

After the existing telemetry write, also updates the matching active entry
to `status: "done" | "blocked" | "failed"`, sets `ended_at`, captures the
first non-meta line of the agent's response as `summary` (≤100 chars), and
normalizes `outcome` for gate agents:

| Agent | Outcomes parsed |
|---|---|
| `qa-reviewer` | `pass` / `fail` |
| `auditor`     | `approve` / `revise` / `escalate` |
| (others)      | `ok` / `blocked` |

If the response shape is unfamiliar, the entry is still marked `done` with
an empty summary — the file format remains valid.

### 3. `scripts/statusline.sh` / `.ps1` (new)

Reads stdin (Claude Code passes session-id JSON), opens
`~/.claude/state/agents-<session_id>.json`, prints exactly one ANSI-colored
line:

```
<emoji> <agent>  <status-glyph>  <≤70-char description-or-summary>  │  <trail>
```

Where `<trail>` is a compact `<emoji><glyph>` sequence for the last 7
agents (e.g. `🔬✓ 📋✓ 🛡️✓ ⚙️●`).

### Color & emoji map

| Agent              | Emoji | Color (256)        |
|--------------------|-------|--------------------|
| orchestrator       | 🧭    | bright cyan (51)   |
| librarian          | 📚    | gold (220)         |
| researcher         | 🔬    | blue (75)          |
| planner            | 📋    | violet (177)       |
| backend-engineer   | ⚙️    | green (42)         |
| frontend-engineer  | 🎨    | orange (208)       |
| test-engineer      | 🧪    | pink (213)         |
| qa-reviewer        | 🛡️    | yellow (226)       |
| auditor            | 🔍    | red (196)          |
| retrospective      | 🪞    | gray (245)         |

| Status / Outcome | Glyph | Color           |
|------------------|-------|-----------------|
| active           | ●     | yellow (226)    |
| done / pass / approve | ✓ | green (42)    |
| blocked / failed / fail | ✗ | red (196)   |
| revise           | ↻     | orange (208)    |
| escalate         | !     | magenta (201)   |

### 4. `settings.fragment.json`

Adds two entries:

```json
{
  "statusLine": { "type": "command", "command": "<scripts/statusline>", "padding": 0 },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Task",
        "hooks": [{ "type": "command", "command": "<hooks/pre-tool-use>" }] }
    ]
  }
}
```

The installer's existing array-merge logic appends to existing arrays —
safe for users who already define `PreToolUse` hooks.

## State file

Location: `~/.claude/state/agents-<session_id>.json`

```json
{
  "session_id": "abc",
  "updated_at": "2026-05-06T07:14:51Z",
  "agents": [
    {
      "agent": "researcher",
      "description": "map the auth flow",
      "status": "done",
      "started_at": "2026-05-06T07:14:32Z",
      "ended_at":   "2026-05-06T07:14:50Z",
      "summary":    "FINDINGS: src/auth.py:42 contains the check.",
      "outcome":    "ok"
    }
  ]
}
```

The file lives under `~/.claude/state/`, which is already created by the
session-start hook and ignored by the rest of the system except the
gate-state file (`session-<id>.json`). The two filenames don't collide.

## Acceptance criteria

- Fresh install registers `statusLine` + `PreToolUse` hooks without
  clobbering an existing user `settings.json`.
- A session that dispatches researcher → planner → engineer → qa-reviewer
  → auditor produces exactly four `agents-<session>.json` updates per leg
  (one Pre, one Stop), and the rendered status reflects each transition.
- Uninstall removes both the hook entries and the `statusLine` setting,
  while preserving any user-authored entries.
- Setting `CLAUDE_MULTIAGENT_NO_METRICS=1` does **not** disable the status
  line — the status line is independent of telemetry.
- The orchestrator persona is unchanged; no agent file edits required.

## Out of scope

- Mobile / non-TTY rendering. The `statusLine` is a terminal feature; the
  Claude.ai web UI doesn't render it. (Future work could add a SessionStart
  `additionalContext` mirror for web sessions, but that re-introduces the
  narration concern.)
- Token-cost annotations on the status line. The `metrics.sh` CLI already
  covers post-hoc reporting; cluttering the live line trades information
  density for noise.
- Persistent cross-session history. Status state is per-session and disposable.
