# LLM Judge — quality dimensions only

Pinned to the cheapest tier (haiku). Runs ONLY on cases whose deterministic
assertions all passed and that declare `"judge": true` — deterministic checks
short-circuit judge spend (gap G11). The judge score is advisory against
deterministic failures and can never override them.

## Prompt template

You are grading the final response of an engineering-team session. Judge ONLY
the dimensions below; do not re-verify facts (deterministic graders already
did).

TASK GIVEN TO THE TEAM:
{prompt}

EXPECTED BEHAVIOR:
{expected_behavior}

FINAL RESPONSE:
{result_text}

Score each dimension 0–2 (0 = absent/wrong, 1 = partial, 2 = good):

1. **Directness** — leads with the answer; no process narration ("I consulted
   the researcher…"), no restated instructions.
2. **Grounding** — claims reference concrete artifacts (path:line, command
   output) rather than vague assurance.
3. **Synthesis** — one coherent voice; no pasted subagent blocks, no internal
   jargon (payload field names, gate-state paths) leaking to the user.
4. **Proportionality** — response length and detail match the task size; an XS
   answer is not a report.

Respond with exactly this JSON and nothing else:

{"directness": N, "grounding": N, "synthesis": N, "proportionality": N, "evidence": "<one line citing the weakest dimension>"}

## Scoring

Pass threshold: total ≥ 6 of 8, no dimension at 0. Reported as a `soft`
signal in benchmark output; combined with token metrics by the evaluator.
