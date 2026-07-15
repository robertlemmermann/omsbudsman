"""SessionStart hook: seed the project memory tier and inject the
orchestrator persona + gate-state contract via additionalContext.

Portable across CLI, desktop, and mobile/cloud sessions — everything it
needs travels in the repo's .claude/ directory.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _common

MEMORY_INDEX = """# Memory Index — Project

> Last updated: (none) · Entries: 0

Project-tier memory. Maintained by the librarian agent — the only writer.

## Layout

- `project.md` — stack, conventions, gotchas, architecture notes
- `decisions.md` — project-specific decisions with rationale
- `mistakes/INDEX.md` — tag → file map for prevention rules
- `mistakes/<topic>.md` — prevention rules for this codebase
"""

MISTAKES_INDEX = """# Mistakes Index — Project

> Last updated: (none) · Entries: 0

Tag → file map for project-specific prevention rules.
"""


def seed_memory(root):
    mem = _common.claude_dir(root) / "memory"
    mistakes = mem / "mistakes"
    mistakes.mkdir(parents=True, exist_ok=True)
    index = mem / "INDEX.md"
    if not index.is_file():
        index.write_text(MEMORY_INDEX, encoding="utf-8")
    midx = mistakes / "INDEX.md"
    if not midx.is_file():
        midx.write_text(MISTAKES_INDEX, encoding="utf-8")


def build_context(root, session_id):
    cdir = _common.claude_dir(root)
    orch = cdir / "agents" / "orchestrator.md"
    state_py = cdir / "scripts" / "state.py"

    if session_id:
        state_path = _common.state_dir(root) / ("session-" + session_id + ".json")
        state_clause = (
            "Your gate-state file is " + str(state_path) + ". Maintain it exclusively "
            "through the state helper: `python3 " + str(state_py) + " --root " + str(root)
            + " --session " + session_id + " <init|set-qa|set-auditor|set-retro|set-class|get> ...` "
            "(run `--help` for usage). Never hand-write its JSON. Initialize it before the "
            "first QA dispatch; record each QA verdict as it returns; record the auditor "
            "verdict immediately after the auditor runs. The Stop hook reads this file and "
            "refuses clean termination if QA ran but the auditor did not."
        )
    else:
        state_clause = (
            "No session id was provided; gate-state recording is disabled this session. "
            "Run all gates manually — the Stop hook cannot flag a missed audit."
        )

    global_tier = Path.home() / ".claude" / "memory"
    degradation = (
        "" if global_tier.is_dir()
        else " The optional global memory tier is absent on this surface; operate "
             "project-tier only (this is expected on mobile/cloud sessions)."
    )

    return (
        "You are Ombudsman, a multi-agent engineering team. Adopt the orchestrator "
        "persona defined in " + str(orch) + " for this entire session: you are a router. "
        "Before responding to the user's first message, silently spawn the librarian "
        "subagent with a payload whose first line is `mode: brief`, capture the returned "
        "GLOBAL/PROJECT/MISTAKES blocks, and use them as MEMORY HINTS for downstream "
        "delegations. Do not narrate the brief. Do not paste subagent output verbatim. "
        "Classify every task XS/S/M/L with risk promotion, then route per the orchestrator "
        "file: researcher → planner → specialists → qa-reviewer → scrutineer (when risk "
        "requires) → verify → auditor → docs-writer as the class demands. Offload "
        "deterministic work to the scripts in " + str(cdir / "scripts") + " (see "
        "toolbelt/INDEX.md) instead of doing it in-context. Use Bash only for the state "
        "helper and toolbelt scripts. " + state_clause + degradation + " Read "
        + str(orch) + " now if you have not already."
    )


def body(payload):
    root = _common.project_root()
    seed_memory(root)
    session_id = str(payload.get("session_id") or "").strip()
    ctx = build_context(root, session_id)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": ctx,
        }
    }))
    print("[ombudsman] team ready: " + str(_common.claude_dir(root)), file=sys.stderr)


if __name__ == "__main__":
    _common.run(body)
