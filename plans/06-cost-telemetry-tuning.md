# Phase 6 — Cost Telemetry + Tuning Pass

**Goal:** Measure what every agent costs per invocation, establish a baseline for typical task types, and tighten the cost-reduction mechanics where data shows waste. Without measurement, all the "hyper-efficient" claims are folklore — this phase makes them numbers.

## Deliverables

1. `SubagentStop` hook — appends per-invocation telemetry to `~/.claude/metrics/sessions.jsonl`.
2. `Stop` hook telemetry summary — appends per-session totals.
3. `claude-system/scripts/metrics.sh` (and `.ps1`) — reports baseline stats from the JSONL.
4. Tuning pass — adjust output caps, model tiers, prompt sizes based on collected data.
5. Documented baseline numbers in `metrics/BASELINE.md` (committed once stable).
6. Optional `/metrics` slash command for inline reports.

## Telemetry record format

`~/.claude/metrics/sessions.jsonl` — one JSON object per line, append-only.

**Per-subagent record (written by SubagentStop hook):**
```json
{
  "kind": "subagent",
  "ts": "2026-05-04T12:34:56Z",
  "session_id": "<id>",
  "project_root": "<path>",
  "agent": "researcher",
  "model": "claude-haiku-4-5",
  "input_tokens": 1234,
  "output_tokens": 234,
  "cache_read_tokens": 800,
  "cache_creation_tokens": 0,
  "duration_ms": 1850,
  "blocked": false,
  "outcome": "ok" | "blocked" | "error"
}
```

**Per-session record (written by Stop hook):**
```json
{
  "kind": "session",
  "ts": "2026-05-04T12:50:00Z",
  "session_id": "<id>",
  "project_root": "<path>",
  "task_class": "research" | "plan" | "implement" | "fix" | "question" | "other",
  "subagent_count": 5,
  "total_input_tokens": 12345,
  "total_output_tokens": 2345,
  "cache_hit_rate": 0.61,
  "duration_ms": 45000,
  "auditor_verdict": "approve" | "revise" | "escalate" | null,
  "qa_pass_rate": 0.83,
  "retro_triggered": false,
  "mistakes_recorded": 0
}
```

Token counts come from Claude Code's hook input payload (it provides usage stats for subagents). Where unavailable, the field is `null` rather than absent — keeps the schema stable for downstream tools.

## Hook implementations

### `subagent-stop.sh` / `.ps1`

Reads the hook payload from stdin (Claude Code passes JSON), extracts the relevant fields, appends one line to `~/.claude/metrics/sessions.jsonl`. Must be fast (<50ms) so it doesn't slow the session. No shell parsing of the JSON — use `jq` on Unix, `ConvertFrom-Json` on PowerShell, fall back to a tiny inline Python if neither.

### `stop.sh` / `.ps1` (extending phases 4 + 5)

After the existing gate checks pass, before exiting 0:
1. Read the session state file (`~/.claude/state/session-<id>.json`).
2. Aggregate the session's subagent records from the JSONL (filter by `session_id`).
3. Append the per-session summary record.
4. Exit 0.

## Reporting script (`scripts/metrics.sh`)

Single command:
```bash
~/.claude/scripts/metrics.sh                    # last 7 days summary
~/.claude/scripts/metrics.sh --agent researcher # per-agent breakdown
~/.claude/scripts/metrics.sh --session <id>     # one session's flow
~/.claude/scripts/metrics.sh --baseline         # writes/updates BASELINE.md
```

Reports include:
- Tokens per agent (mean, p50, p95).
- Cache hit rate per agent.
- BLOCKED rate per agent (tells us where pre-flight is too strict or too loose).
- Tokens per task class (research vs implement vs fix).
- Recurring-mistake counts.
- Cost per session (using current published Claude pricing; embedded as constants, easy to update).

Pure bash + jq on Unix. PowerShell + native JSON on Windows. No external deps.

## Tuning pass — what to look for in the baseline

Run for ~10 real sessions across varied task types, then read the metrics. Adjust based on signal:

| Signal | Action |
|---|---|
| Researcher avg output > 30 lines | Tighten cap in researcher prompt |
| Engineer avg output > 50 lines | Tighten cap, or split tasks more aggressively in planner |
| Cache hit rate < 40% on orchestrator | Stabilize orchestrator system prompt; stop varying boilerplate |
| Same agent BLOCKED > 20% of calls | Pre-flight too strict, or planner is dispatching it wrong |
| QA fail rate > 30% | Engineer prompts unclear, or planner steps too coarse |
| Auditor revise rate > 25% | Plans miss requirements; planner needs tighter input |
| Retro false-positive rate > 50% | Tighten correction-detection regex |
| Memory brief > 200 tokens | Librarian compact running too late, or 90-day window too lax |

Each adjustment is a one-line prompt edit + a re-measurement. Keep a `TUNING_LOG.md` so we don't churn.

## Optional `/metrics` slash command

`claude-system/skills/metrics/SKILL.md` — invokes the reporting script and pretty-prints the result inline. Useful for at-a-glance checks without leaving the session.

## Acceptance criteria

- [ ] Every subagent invocation produces a JSONL record.
- [ ] Every session produces a summary record.
- [ ] Records are valid JSON (one per line, parseable with `jq -c '.'`).
- [ ] Telemetry hooks add < 100ms overhead per session.
- [ ] `metrics.sh` produces a readable report from a populated JSONL.
- [ ] After 10 sessions, `metrics.sh --baseline` writes a `BASELINE.md` with the numbers.
- [ ] At least one tuning change is informed by the baseline (not by guesswork) and re-measured.
- [ ] Cost reduction visible: tokens per "implement" task class drop after tuning, ideally ≥20%.

## Dependencies / order

- Depends on phases 1–5 (needs the full system running to measure anything meaningful).
- **Blocks:** nothing — this is the closing phase.

## Risks / open notes

- Hook payload schema may differ slightly across Claude Code versions; the parser must tolerate missing fields rather than crash.
- JSONL grows unbounded. Add a rotation rule: if `sessions.jsonl` exceeds 10MB, rotate to `sessions.<date>.jsonl.gz` and start fresh. Keep last 4 archives.
- Cost-per-session calculation depends on hardcoded pricing — note in the script that prices need manual updates when Anthropic changes them.
- Telemetry creates a small privacy concern: project paths and task classes are recorded locally. Document this in README, offer an opt-out env var (`CLAUDE_MULTIAGENT_NO_METRICS=1`).
- The tuning pass is open-ended. Cap the first pass at 4 hours of measurement + adjustment to avoid endless polishing. Re-run quarterly thereafter, not continuously.
