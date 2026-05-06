# Plan Audit — 2026-05-05

Independent audit of `00-master-plan.md` and phases 1–6. Goal: poke holes, surface cost/correctness risks, propose concrete improvements. Citations use `plans/<file>.md:<line>`.

---

## Executive summary

The plans are coherent and the agent split is sensible, but three structural problems will hurt cost and execution success in practice:

1. **Review surface is self-reported, not actual.** QA and auditor inspect the engineer's *summary* of changes, not the diff or the files. The 50-line cap on engineer output (`04:32`) means real diffs cannot fit. Engineers can lie, hallucinate, or omit, and neither gate has ground truth. This is the single largest correctness risk.
2. **Floor cost per task is too high.** Even a "trivial" request must traverse orchestrator → librarian (brief) → engineer → QA → auditor (`03:39-41`, `04:39 implies`). That's a minimum of 5 model calls — most on Sonnet — to change a typo. The per-call dispatch payload (`TASK / CONTEXT / MEMORY HINTS / DELIVERABLE / CAP`) repeats memory hints on every call, defeating the cache benefit it claims (`00:136`).
3. **Telemetry is phase 6.** Phases 1–5 ship un-instrumented. The plan itself admits "without measurement, all the 'hyper-efficient' claims are folklore" (`06:4`), then proceeds to build five phases on folklore. Tuning targets in `06:96-107` are guesses, not data.

Fixing these three changes the system from "expensive and hopeful" to "measurable and tight."

---

## Master plan (`00-master-plan.md`)

### M1 — Orchestrator on `inherit` is the tax that eats everything else
`00:18` and `03:14` set the orchestrator to `inherit`. The risk note (`03:131`) acknowledges this but the mitigation ("keep output terse") is insufficient. The orchestrator is the **most-frequently-invoked** node — every user turn passes through it — and on Opus pricing, every routing decision is ~15× a Haiku call. Cache hits help, but the orchestrator's output is non-cacheable and grows with conversation.

**Recommendation:** make orchestrator's *thinking and routing* run on a fixed model independent of session, e.g. Sonnet pinned. Use `inherit` only for the user-facing synthesis turn. Or, more aggressively: split orchestrator into a deterministic Python "router" (Skill / hook) for classification, and a tiny LLM "synthesizer" only at the final turn.

### M2 — Auditor is mandatory even when there is nothing to audit
`00:107-108` and orchestrator's hard rule "trivial requests may skip researcher/planner; never skip auditor" (`claude-system/agents/orchestrator.md:39`) means a one-word answer drags the auditor in. Cost: ≥1 Sonnet call per turn for zero correctness gain on conversational/clarifying turns.

**Recommendation:** make auditor mandatory only when at least one `engineer` produced changes. Conversational, pure-question, and BLOCKED-research outcomes should skip it. Update the Stop hook gate to require `auditor_verdict` only if `qa_verdicts` is non-empty *and* a diff was produced (the hook already conditions on `qa_verdicts`; tighten it further).

### M3 — `MEMORY HINTS` injected per-call kills prompt cache
`00:136` claims "Stable system prompt — maximize prompt-cache hits." But `MEMORY HINTS` is recomputed and varies per delegation (different hints by tags). Inserted into the per-call payload, it breaks suffix-cache reuse for the agent system prompt prefix.

**Recommendation:** put `MEMORY HINTS` *after* the agent's stable system prompt (in the user message), and put the most-stable global rules **inside** the system prompt where they belong. Document the cache-friendly ordering: `[stable system] | [stable user-message header] | [variable hints] | [task]`. Verify with `cache_read_tokens` in telemetry.

### M4 — "Subagents are stateless" + 5-step plans = 5× re-dispatch cost
`00:104` and `03:23` hold subagents stateless. For a 5-step plan, the orchestrator re-sends plan context, memory hints, and step dependencies on every call. With 5 engineers + 5 QA + 1 auditor that's 11 dispatches each carrying redundant context.

**Recommendation:** write the canonical plan + context once to `~/.claude/state/session-<id>/plan.md` and pass *only the path + step number* to each subagent. Subagents read the plan once (cacheable across the cohort). This trades one Read tool call per agent for an order-of-magnitude reduction in input tokens. Combine with prompt caching of the plan file.

### M5 — Cost-reduction list (`00:128-138`) has no measurement
Ten claimed mechanics, zero numbers attached. This list will rot the moment Anthropic changes prices or model behavior.

**Recommendation:** every entry on that list becomes an assertion in `metrics.sh` that prints PASS/FAIL against the baseline. E.g. "researcher avg output ≤ 30 lines" → measured. "Cache hit rate on orchestrator ≥ 50%" → measured. Move telemetry stub into Phase 1 so every later phase is measured-on-build.

### M6 — No fast-path for the cheapest request type
The flowchart (`00:95-114`) has a single hot path. There's no shortcut for "where is X defined?" — which an agent dispatch system makes *more* expensive than just answering directly.

**Recommendation:** orchestrator gets a "direct answer" intent class (already partially present at `claude-system/agents/orchestrator.md:40-41`), but tighten it: any request that can be answered from the librarian brief alone bypasses researcher entirely. Telemetry the bypass rate.

---

## Phase 1 — Skeleton + installer (`01-skeleton-and-installer.md`)

### P1.1 — ISO8601 backup names break on Windows
`01:54` says "back up to `~/.claude.backup-<ISO8601>/`". ISO8601 with colons (`2026-05-04T12:34:56Z`) is **invalid as a directory name on NTFS**. The PowerShell installer will throw silently or produce a mangled name.

**Fix:** use a Windows-safe variant: `backup-20260504T123456Z` (no colons, no hyphens between time components) consistently across both installers.

### P1.2 — `jq` not always present, fallback chain undefined
`01:59` casually says "Use `jq` on Unix, `ConvertFrom-Json`/`ConvertTo-Json` on PowerShell" then `01:127` admits jq is "not always available on bare macOS; fall back to a small Python or Node JSON merger if absent."

**Fix:** the actual stop.sh implementation already uses Python3 — standardize on Python3 (which is on every modern macOS and Windows-with-Python). Remove the jq path entirely; one parser, one bug surface. Add an early "python3 missing" guard with a clear error.

### P1.3 — Re-running the installer overwrites user-modified agents silently
`01:55` "Files with the same name are overwritten (the user is replacing the team)." There's no detection of user edits. A user who tweaks `frontend-engineer.md` for their stack loses it on the next `git pull && ./install.sh`.

**Fix:** before overwrite, hash the current file vs the file shipped in the *previous* version of the installer (record SHA in `~/.claude/.install-manifest.json`). If hash differs from the previous-shipped hash, save the user's version to `~/.claude/agents/<name>.user-<date>.md` and warn.

### P1.4 — No live-session detection
Installing while a Claude Code session is running can corrupt that session's hook resolution.

**Fix:** check for running `claude` processes (`pgrep -f claude` / `Get-Process claude`). Warn and require `--force` to proceed.

### P1.5 — Settings merge has no JSONC tolerance
Some Claude Code distributions allow comments in `settings.json`. `01:59` mandates a strict JSON parse.

**Fix:** strip `//` and `/* */` comments before parsing during merge; preserve them on write by working with a comment-aware library *or* refuse to merge with an explicit warning instead of silently corrupting.

### P1.6 — Unsign installer is a supply-chain risk
A compromised commit on `main` would push hooks to every user's machine. The README likely says "curl | bash" or similar.

**Fix:** publish a signed tag. Installer verifies the manifest signature before copying. Even a SHA256SUMS file signed with one maintainer key is better than nothing.

---

## Phase 2 — Librarian + memory (`02-librarian-and-memory.md`)

### P2.1 — Token jaccard at threshold 0.6 is unmeasured folklore
`02:155` admits "naive string match misses paraphrases, semantic match is expensive." 0.6 is a guess. There's no test corpus.

**Fix:** add `tests/dedup-corpus.jsonl` with hand-labeled duplicate/non-duplicate pairs. Measure precision/recall of the dedup logic on each tweak. Combine token jaccard with **path-presence**: any two memory entries that mention the same `path:line` token should auto-merge regardless of jaccard score (huge precision boost, free).

### P2.2 — Compact runs every Stop hook
`02:130-136` runs compact at session end. For a session that wrote zero memory, this is wasted Haiku cost.

**Fix:** Stop hook reads the session state's `memory_writes` count (must be added). If 0, skip compact. Run compact at most once per project per day, gated by a timestamp file.

### P2.3 — Project root via git rev-parse fragments memory for non-git users
`02:101` falls back to `pwd` if no git repo. A user `cd`-ing around a non-git workspace gets a different "project" each session.

**Fix:** if not in a git repo, look for explicit markers (`.claude/memory/`, `package.json`, `pyproject.toml`, `Cargo.toml`) walking up. If still not found, refuse to create per-project memory; only global. Never let `pwd` define project identity.

### P2.4 — `mode: append` payload format is ambiguous
`02:117-124` calls it "JSON-ish" then shows YAML-like syntax. Parser brittleness.

**Fix:** make it strict JSON. Document one format. Reject anything else with a clear error (and log to a "librarian-rejects.log" so we can spot orchestrator misformats).

### P2.5 — 90-day prune deletes silently
`02:134` drops entries last seen >90 days unless `permanent`. Users will lose hard-won memory they forgot to tag.

**Fix:** soft-delete to `~/.claude/memory/.archive/<date>.md` instead of hard-delete. Keep last 4 archives. Cheap insurance.

### P2.6 — Two concurrent sessions corrupt memory
`02:157` ack'd, dismissed. Acceptable for v1, but the failure mode is silent. A flock or lockfile is 5 lines of code.

**Fix:** `flock` on Unix, `Mutex` on PowerShell, around any memory file write. On contention, wait up to 2s then bail with `BLOCKED: memory locked`. Visible failure beats silent corruption.

### P2.7 — Brief is computed from scratch every session
Even when memory hasn't changed, the librarian regenerates. With a Haiku call ~50ms+200 tokens.

**Fix:** cache the brief at `~/.claude/memory/.brief-cache.md` keyed by `(global mtime, project mtime)`. Regenerate only on mtime change. Free 95%+ of the time.

---

## Phase 3 — Orchestrator + researcher + planner (`03-orchestrator-research-planner.md`)

### P3.1 — Orchestrator file-read prohibition enforced by prompt only — partially fixed
`03:130-131` notes the discipline is hard to enforce. Good news: the actual implementation gives orchestrator only `Task, Bash` tools (`claude-system/agents/orchestrator.md:4`). Bad news: Bash is unconstrained — the orchestrator could `cat` a file. The "Bash is permitted only for the gate-state file" rule (orchestrator.md:15) is also prompt-only.

**Fix:** ship a wrapper script `~/.claude/scripts/state-write.sh` that takes JSON on stdin and writes the state file safely. Restrict orchestrator's Bash to that script via the permission layer (allowlist, not prompt). Eliminates the entire class of "orchestrator cheated and read a file" bug.

### P3.2 — Researcher 30-line cap forces multiple calls for any non-trivial investigation
`03:64`, `03:88`. A real codebase question often needs 50+ findings. The orchestrator will re-dispatch the researcher with narrower scopes, multiplying invocation count.

**Fix:** lift cap to 60 lines for findings, keep the GAPS/CONFIDENCE shape. Or split: `researcher-broad` (overview, 30 lines) and `researcher-deep` (single-file, no cap). Measure which is cheaper before locking in.

### P3.3 — Planner cap of 30 lines is mathematically tight
`03:87`. A 10-step plan with parallel groups, risks, and exit criteria cannot fit in 30 lines. Either steps get truncated or sections get dropped.

**Fix:** raise to 60 lines, OR — better — let planner emit to a file (`<state>/plan.md`) and return only the path + summary in 10 lines. Engineers and QA read the plan file. Bonus: removes the plan re-injection on every dispatch (M4).

### P3.4 — "One owning agent per step" forces awkward splits
`03:88` and risk note `03:133`. A "rename a function across FE+BE" task naturally crosses scopes.

**Fix:** allow a `coordinator` step that names two agents and explicitly splits the file list. Orchestrator dispatches them in parallel and merges. Cleaner than the "multi: <agents>" escape valve.

### P3.5 — Researcher must declare CONFIDENCE — but with what calibration?
`03:60`. With no calibration data, "high/medium/low" is vibes. Planner gates on it (`03:90`).

**Fix:** define CONFIDENCE operationally — `high` = every claim has a path:line ref, `medium` = some refs missing, `low` = inferential. Make it auditable post-hoc from the FINDINGS block.

---

## Phase 4 — Engineers + QA + auditor (`04-engineers-qa-auditor.md`)

### P4.1 — **CRITICAL: Auditor never opens files, reviews summaries**
`04:100`: "The auditor never opens files itself — it works from the structured inputs." Combined with the engineer's 50-line CHANGES cap (`04:32`), the auditor is reviewing a self-graded summary. An engineer that mis-applied a refactor, left debug prints, or silently broke an unrelated file will pass the auditor every time.

**Fix:** auditor MUST run `git diff <base>` (or whatever VCS context applies) and verify diff matches the CHANGES list. This is the highest-impact correctness change in the audit. Same applies to QA. Both gates need ground truth; without it the system grades its own homework.

### P4.2 — **CRITICAL: No mandatory test/build/lint at gate boundary**
`04:32`: engineers self-report "TESTS RUN: <command + result, or 'none'>". An engineer can claim tests pass or skip them entirely. QA and auditor can't verify.

**Fix:** orchestrator's gate code (or a `gatekeeper` Skill) runs the project's test+lint commands and writes results to session state. QA reads the *real* results, not the engineer's report. If no test command is configured, the gate logs "no tests configured" once per project to memory and proceeds.

### P4.3 — 50-line engineer cap hides large diffs from review
`04:33`. Real refactors easily exceed 50 lines of diff context.

**Fix:** engineers emit a structured diff *or* a path to the actual diff (engineers already wrote real files; a `git diff` is the source of truth). Drop the 50-line cap on CHANGES; replace with "must reference exact file paths and line ranges, no inline contents." Diff itself lives on disk.

### P4.4 — No rollback policy on QA fail
If 3 of 5 step engineers commit edits to disk and step 4 fails QA, what reverts? `04:73` says "loop back" but does not specify whether prior changes stay.

**Fix:** every engineering step starts with an explicit `git stash create` (or branch-from-HEAD). On QA fail-and-give-up, orchestrator reverts to the saved ref. Document the policy explicitly in the orchestrator prompt and Stop hook.

### P4.5 — "Allowed languages" lists become stale
`04:39`, `04:42`. JS, Python, Rust enumerated. New languages every year.

**Fix:** flip from allowlist to "scope by directory" — frontend = `apps/web/**`, `packages/ui/**` (project-defined); backend = everything else. The list of allowed paths lives in `<project>/.claude/memory/project.md` set by librarian on first session.

### P4.6 — Pre-flight checks pass on wrong information
`04:36`: "confirm all dependencies named in the step exist in the codebase." Existence ≠ correctness. The agent can confirm a function exists and still misuse it.

**Fix:** keep the existence check (cheap), but add a "post-flight" — engineer's last action before returning is a 5-line self-review: "I changed X. The risks are Y. Tests for Y exist at Z, run them." Forces concrete verification language.

### P4.7 — Two-retry cap on QA, no learning capture
`04:73`, `04:137`. Two cycles then escalate. Those failed cycles have signal — they're examples of what the engineer got wrong — but nothing captures them unless the user explicitly corrects.

**Fix:** if QA rejects twice, *automatically* flag `RETRO_NEEDED` so phase 5 learns from the QA-loop failure even when the user moved on. Cheap; fixes a learning gap.

### P4.8 — Stop hook bypass is buried
`04:139`: "make sure the bypass message tells the user how to skip." Currently `CLAUDE_SKIP_AUDIT=1` (`claude-system/hooks/stop.sh:11`).

**Fix:** the bypass message itself should print the env var and a one-line example. Don't make the user grep docs.

---

## Phase 5 — Retrospective + mistake learning (`05-retrospective-mistake-learning.md`)

### P5.1 — **HIGH: Regex correction detection has unbounded false-positive cost**
`05:18-25` lists six regexes including `\b(no|nope|wrong|...)\b`. False positives in normal English ("no problem", "no worries", "I think we should fix the typo first") will fire constantly. Each false positive costs:
- Stop hook gate (cheap)
- + retrospective Sonnet call (~1k tokens)
- + librarian append Haiku call

`05:128` claims the retrospective itself filters: "if it can't identify a concrete WHAT WENT WRONG, returns NO RETRO NEEDED." But the Sonnet call already happened.

**Fix:** add a Haiku-priced classifier *between* the regex and the retrospective. Input: triggering prompt + last assistant turn. Output: `RETRO_YES` or `RETRO_NO` + one-line reason. Cuts false-positive cost by ~10× (Haiku < Sonnet) without losing recall. Telemetry the precision after a week.

### P5.2 — Retrospective receives "recent assistant turns" with no token budget
`05:36-40`. Recent = how many? On a long session, this can be thousands of tokens.

**Fix:** cap retrospective input at 2k tokens of conversation history. If overflow, give it the last user turn + the failing agent's output + the prior assistant turn. That's enough.

### P5.3 — Tier promotion at 3 recurrences over-promotes single-project quirks
`05:82-83`, `05:130`. A user who works on one repo will see the same project-specific quirk hit 3× and incorrectly promote it to global.

**Fix:** require recurrence across **distinct project roots** for promotion, not just count. Track unique projects in the mistake entry. Three project-roots = global. One project = stays project. Free signal already on hand.

### P5.4 — No way to delete a wrongly-learned rule
A bad retrospective writes a wrong rule. It now lives 90 days minimum, polluting every dispatch.

**Fix:** add a `librarian forget <id>` mode and document a slash command (`/forget-rule <id>`) that surfaces the most recent N rules and lets the user nuke one. 30 lines of code; large user-trust win.

### P5.5 — `MEMORY HINTS` cap of 5 is arbitrary
`05:95-96`. Some agents will accumulate >5 relevant rules. Cap at 5 means oldest-by-recurrence drops.

**Fix:** weight by recency × recurrence × confidence. Or: telemetry the hint-hit rate (how often did an agent's output reference the hint?), drop hints with 0 hits over 30 days from injection.

### P5.6 — No detection of contradictory rules
Two retrospectives can write rules that contradict. Nothing catches it.

**Fix:** during compact, librarian runs a pairwise contradiction check (cheap with Haiku). Flag pairs for user review via a `MEMORY-CONFLICTS.md` file. Don't auto-resolve.

### P5.7 — "Sharpening" by replacing existing rules can degrade memory
`05:81`: "replace with the more concrete of (existing rule, new rule)." Judging concreteness by an LLM is fuzzy and can lose nuance.

**Fix:** never overwrite. Append the new rule as a sub-bullet under the existing entry, increment recurrences. Compact pass merges *only* if both bullets are clearly the same rule. Preserve original wording always.

---

## Phase 6 — Cost telemetry + tuning (`06-cost-telemetry-tuning.md`)

### P6.1 — **STRUCTURAL: Telemetry shipped last means phases 1–5 are unmeasured**
`06:127`: "Depends on phases 1–5." This is backwards. Every architectural decision in phases 1–5 needs measurement to validate. Without it, those phases ship with prompt caps and model choices that are essentially aesthetic.

**Fix:** move the SubagentStop telemetry hook to **phase 1**. It's a single bash script that appends JSON. No dependency on any agent. Then phases 2–5 ship with metrics from day one. Keep the *tuning pass* and *baseline analysis* in phase 6 — that's the right place. The data collection should start with the installer.

### P6.2 — Hook payload schema assumed without version pinning
`06:132`: "Hook payload schema may differ slightly across Claude Code versions; the parser must tolerate missing fields."

**Fix:** the JSONL records include `schema_version: "1.0"` and `claude_code_version: "<from env or stdin>"`. Reporter filters by version. When schema breaks, baselines aren't silently corrupted by new fields.

### P6.3 — Pricing constants embedded, will rot
`06:90`, `06:134`. Hardcoded price table.

**Fix:** put prices in a single YAML/JSON file `~/.claude/metrics/pricing.json` with a `last_updated` field. Reporter warns if the file is >90 days old. User can update without touching script.

### P6.4 — Task class auto-detection is hand-waved
`06:42` has the field; how it's populated is unspecified. If it requires an agent call, it's expensive per-session.

**Fix:** orchestrator writes `task_class` into session state at intent-classification time (which it already does logically). Stop hook reads the state file. No extra LLM call needed.

### P6.5 — `metrics.sh` reports averages but not distributions
`06:84` mentions p50/p95 — good. But a single tail outlier (one bad session) skews means.

**Fix:** add `--exclude-outliers` flag (drops top/bottom 5%). Add per-agent histograms (text-mode 10-bucket bar chart). Cheap; far more useful than means.

### P6.6 — Tuning targets in `06:96-107` are arithmetic guesses
"Researcher avg output > 30 lines → tighten cap." But what if the cap is wrong, not the agent?

**Fix:** every threshold in that table needs a counter-test. "If tightening cap raises BLOCKED rate >10%, revert." Tuning becomes hill-climbing with a guard rail, not unilateral squeeze.

### P6.7 — JSONL rotation rule is size-only
`06:133`: rotate at 10MB, keep last 4.

**Fix:** also rotate by date (monthly). Easier to reason about "show me April's costs." Use `sessions-2026-04.jsonl.gz`. Both triggers (size OR month boundary) rotate.

### P6.8 — No cost regression alarm
After tuning to drop tokens by 20%, nothing prevents future drift up.

**Fix:** `metrics.sh --check` exits non-zero if last-7-days tokens-per-task is >20% above the BASELINE. Wire into the SessionStart hook (silent unless tripped) to surface drift early.

---

## Cross-cutting recommendations (priority order)

| # | Change | Phase touched | Estimated cost win | Estimated correctness win |
|---|---|---|---|---|
| 1 | Move telemetry to phase 1; instrument from day one | 1, 6 | enables all others | n/a |
| 2 | QA + auditor read actual `git diff`, not engineer self-report | 4 | neutral | **very high** |
| 3 | Mandatory test/lint at gate (real exec, not self-report) | 4 | small cost | **very high** |
| 4 | Plan + context written to file; subagents read by path | 3, 4 | high | medium |
| 5 | Haiku classifier between correction-regex and retrospective | 5 | high | n/a |
| 6 | Skip auditor when no diffs produced | 4 | high (per-turn) | none |
| 7 | Cache brief at `~/.claude/memory/.brief-cache.md` | 2 | medium | n/a |
| 8 | `MEMORY HINTS` placed in user message, not system prompt | all | medium (cache hits) | n/a |
| 9 | Soft-delete on prune; archive instead of hard-drop | 2 | none | trust |
| 10 | Path-presence dedup (auto-merge entries sharing `path:line`) | 2 | none | medium |
| 11 | Tool allowlist for orchestrator's Bash (single wrapper script) | 3 | none | medium |
| 12 | Auto `RETRO_NEEDED` on 2nd QA fail | 4, 5 | none | learning rate |
| 13 | Promotion to global requires distinct project roots | 5 | none | rule quality |
| 14 | `/forget-rule` slash command | 5 | small | trust |
| 15 | Windows-safe backup filenames (no colons) | 1 | none | install reliability |

---

## Suggested re-sequenced phase plan

The current 1→6 ordering is "build everything, measure last." Proposed:

- **Phase 0 (new):** telemetry hook + state directory + `metrics.sh` skeleton. ~1 day.
- **Phase 1:** installer, with all measurement hooks live but most agents stubbed.
- **Phase 2:** librarian + memory, **measured** dedup, brief cache, soft-delete archive.
- **Phase 3:** orchestrator with tool-allowlisted Bash; researcher; planner-writes-to-file; cache-aware payload ordering.
- **Phase 4:** engineers + QA + auditor with **diff-reading gates** and **mandatory test execution**. This is the correctness phase; do not ship without it.
- **Phase 5:** retrospective with Haiku pre-filter, project-root-aware promotion, `/forget-rule`.
- **Phase 6:** tuning pass + baseline lock + cost-regression alarm.

Each phase still ends with verification, but verification now has numbers to point at.

---

## Open questions for the user

1. **Is offline ground truth (running tests/lint) acceptable in QA?** It's a behavior change — gates do real work now, not just review summaries. Cost is one extra subprocess per gate; correctness gain is large. (Recommend yes.)
2. **Is the orchestrator's `inherit` model tier negotiable?** Pinning to Sonnet caps cost per turn but means the user can't escalate to Opus by changing their session. Could expose `CLAUDE_ORCHESTRATOR_MODEL` env var as opt-in escalation. (Recommend pin + env override.)
3. **Should mistake memory have an explicit "owner" field separate from tags?** Currently `Owning agent` is in the entry text (`05:58`). Promoting it to a structured field would make hint selection deterministic instead of regex-based. (Recommend yes; small schema change.)
4. **Is per-project memory committable by default?** Plan says project chooses (`00:75`, `02:158`). A default of **gitignored, with a one-line opt-in** is safer for multi-developer repos where Claude memory could leak personal preferences. (Recommend gitignored default.)

---

End of audit.
