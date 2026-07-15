"""Deterministic graders — no model calls (plan §8 gap G11: deterministic
assertions short-circuit before any judge spend).

Each grader takes a TrialContext and optional args, returning (passed, note).
"""
import json
import re
import subprocess
import sys
from pathlib import Path


class TrialContext:
    """Everything a grader may inspect for one trial."""

    def __init__(self, fixture_dir, transcript_metrics, result_text,
                 baseline_manifest):
        self.fixture_dir = Path(fixture_dir)
        self.metrics = transcript_metrics or {}
        self.result_text = result_text or ""
        self.baseline_manifest = baseline_manifest or {}

    def current_manifest(self):
        return snapshot_fixture(self.fixture_dir)


def snapshot_fixture(fixture_dir):
    """Map of product-file → content hash, excluding .claude runtime dirs."""
    import hashlib
    manifest = {}
    for path in sorted(Path(fixture_dir).rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(fixture_dir)
        parts = rel.parts
        if ".claude" in parts or ".ombudsman" in parts or ".git" in parts \
                or "__pycache__" in parts:
            continue
        manifest[str(rel)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return manifest


# --- graders -----------------------------------------------------------------

def answer_mentions(ctx, needles):
    text = ctx.result_text.lower()
    missing = [n for n in needles if n.lower() not in text]
    if missing:
        return False, "final answer missing: " + ", ".join(missing)
    return True, "all needles present"


def max_task_dispatches(ctx, n):
    count = ctx.metrics.get("subagent_count", 0)
    if count > n:
        return False, str(count) + " Task dispatches (max " + str(n) + "): " \
            + ", ".join(ctx.metrics.get("task_dispatches", []))
    return True, str(count) + " dispatches"


def requires_task_dispatch(ctx, agents):
    dispatched = set(ctx.metrics.get("task_dispatches", []))
    missing = [a for a in agents if a not in dispatched]
    if missing:
        return False, "never dispatched: " + ", ".join(missing)
    return True, "required agents dispatched"


def no_file_changes(ctx):
    current = ctx.current_manifest()
    if current != ctx.baseline_manifest:
        changed = sorted(
            set(current) ^ set(ctx.baseline_manifest)
            | {k for k in set(current) & set(ctx.baseline_manifest)
               if current[k] != ctx.baseline_manifest[k]}
        )
        return False, "product files changed: " + ", ".join(changed[:5])
    return True, "no product-file changes"


def file_contains(ctx, path, needle):
    target = ctx.fixture_dir / path
    if not target.is_file():
        return False, path + " does not exist"
    if needle not in target.read_text(encoding="utf-8"):
        return False, path + " lacks '" + needle + "'"
    return True, needle + " present in " + path


def fixture_tests_pass(ctx):
    proc = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests"],
        cwd=str(ctx.fixture_dir), capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout).strip().splitlines()[-3:]
        return False, "fixture tests fail: " + " / ".join(tail)
    return True, "fixture tests pass"


def seeded_bug_fixed(ctx):
    calc = ctx.fixture_dir / "calculator.py"
    if not calc.is_file():
        return False, "calculator.py missing"
    code = compile(calc.read_text(encoding="utf-8"), "calculator.py", "exec")
    namespace = {}
    exec(code, namespace)  # noqa: S102 — fixture code under harness control
    try:
        namespace["average"]([])
    except ZeroDivisionError:
        return False, "average([]) still raises ZeroDivisionError"
    except Exception:
        return True, "average([]) no longer hits the seeded ZeroDivisionError"
    return True, "average([]) handled"


def gate_state_complete(ctx):
    state_dir = ctx.fixture_dir / ".ombudsman" / "state"
    for path in state_dir.glob("session-*.json"):
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if state.get("qa_verdicts") and state.get("auditor_verdict"):
            return True, "qa=" + ",".join(state["qa_verdicts"]) \
                + " auditor=" + str(state["auditor_verdict"])
    return False, "no session state with both QA verdicts and an auditor verdict"


def memory_rule_recorded(ctx):
    mistakes = ctx.fixture_dir / ".ombudsman" / "memory" / "mistakes"
    for path in mistakes.glob("*.md"):
        if path.name == "INDEX.md":
            continue
        if re.search(r"Prevention rule:", path.read_text(encoding="utf-8")):
            return True, "prevention rule in " + path.name
    return False, "no prevention rule recorded under .ombudsman/memory/mistakes/"


def toolbelt_invoked(ctx, script):
    # Bash tool invocations appear in the transcript's tool_use blocks; the
    # runner records raw transcript text lines for this check.
    raw = ctx.metrics.get("_raw_text", "")
    if "toolbelt/" + script in raw:
        return True, script + " invoked"
    return False, "no invocation of toolbelt/" + script + " found in transcript"


def tokens_nonnull(ctx):
    total = (ctx.metrics.get("input_tokens") or 0) \
        + (ctx.metrics.get("output_tokens") or 0) \
        + (ctx.metrics.get("cache_read_input_tokens") or 0)
    if total <= 0:
        return False, "transcript yielded zero token usage — instrumentation failure"
    return True, "usage present (" + str(total) + " tokens observed)"


GRADERS = {
    "answer_mentions": answer_mentions,
    "max_task_dispatches": max_task_dispatches,
    "requires_task_dispatch": requires_task_dispatch,
    "no_file_changes": no_file_changes,
    "file_contains": file_contains,
    "fixture_tests_pass": fixture_tests_pass,
    "seeded_bug_fixed": seeded_bug_fixed,
    "gate_state_complete": gate_state_complete,
    "memory_rule_recorded": memory_rule_recorded,
    "toolbelt_invoked": toolbelt_invoked,
    "tokens_nonnull": tokens_nonnull,
}


def run_grader(name, ctx, args=None):
    if name not in GRADERS:
        return False, "unknown grader: " + name
    try:
        return GRADERS[name](ctx, **(args or {}))
    except Exception as exc:  # noqa: BLE001 — a crashing grader is a failed assertion
        return False, "grader error: " + type(exc).__name__ + ": " + str(exc)
