#!/usr/bin/env python3
"""Ombudsman self-testing harness (plan §8).

Layers:
  --static       free deterministic checks: lints, schema validation, unit
                 tests, script compilation. Runs everywhere, including CI on
                 Linux/macOS/Windows. (The copy-over lifecycle test lives in
                 harness/tests/test_lifecycle.py, discovered here.)
  --behavioral   golden cases executed headless via `claude -p` against a
                 temp copy of the fixture project with the repo's .claude/
                 installed — the exact adoption path, so every run
                 regression-tests mobile/cloud distribution. Requires the
                 claude CLI and credentials; on surfaces without them the
                 layer reports deferred-to-CI (visible degradation, plan §3.4).

Usage:
  run.py --static
  run.py --behavioral [--cases id1,id2] [--trials N] [--model M] [--timeout S]
  run.py             (both; behavioral skipped gracefully when impossible)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parent
REPO = HARNESS.parent
CLAUDE_DIR = REPO / ".claude"
SCRIPTS = CLAUDE_DIR / "scripts"
FIXTURE = HARNESS / "evals" / "fixtures" / "sample-project"

sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(HARNESS / "evals" / "graders"))
import transcript as transcript_mod          # noqa: E402
import deterministic as graders_mod          # noqa: E402


# --- static layer -------------------------------------------------------------

def check(name, fn, results):
    start = time.time()
    try:
        ok, note = fn()
    except Exception as exc:  # noqa: BLE001 — a crashing check is a failed check
        ok, note = False, type(exc).__name__ + ": " + str(exc)
    results.append((name, ok, note, round(time.time() - start, 2)))
    return ok


def run_lint(script, target):
    proc = subprocess.run(
        [sys.executable, str(SCRIPTS / script), str(target), "--quiet"],
        capture_output=True, text=True, timeout=120,
    )
    out = (proc.stdout + proc.stderr).strip()
    return proc.returncode == 0, out.splitlines()[-1] if out else "clean"


def validate_settings():
    settings = json.loads((CLAUDE_DIR / "settings.json").read_text(encoding="utf-8"))
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict) or not hooks:
        return False, "settings.json has no hooks"
    seen = set()
    for event, entries in hooks.items():
        for entry in entries:
            for hook in entry.get("hooks", []):
                cmd = hook.get("command", "")
                if "$CLAUDE_PROJECT_DIR" not in cmd:
                    return False, event + " hook not $CLAUDE_PROJECT_DIR-relative: " + cmd
                marker = cmd.split("$CLAUDE_PROJECT_DIR/", 1)[-1].strip().strip('"')
                script = REPO / marker
                if not script.is_file():
                    return False, event + " hook file missing: " + marker
                if (event, cmd) in seen:
                    return False, "duplicate hook registration: " + cmd
                seen.add((event, cmd))
    return True, str(len(seen)) + " hook registrations, all files present"


def validate_json_files():
    for rel in ("scripts/pricing.json",):
        json.loads((CLAUDE_DIR / rel).read_text(encoding="utf-8"))
    budgets = json.loads((HARNESS / "budgets.json").read_text(encoding="utf-8"))
    if "classes" not in budgets:
        return False, "budgets.json missing 'classes'"
    manifest = json.loads((HARNESS / "evals" / "evals.json").read_text(encoding="utf-8"))
    ids = [c["id"] for c in manifest["cases"]]
    if len(ids) != len(set(ids)):
        return False, "duplicate case ids in evals.json"
    for case in manifest["cases"]:
        for assertion in case["assertions"]:
            if assertion["grader"] not in graders_mod.GRADERS:
                return False, case["id"] + " names unknown grader " + assertion["grader"]
            if assertion.get("severity") not in ("critical", "gate", "soft", "budget"):
                return False, case["id"] + " has invalid severity"
    return True, "pricing/budgets/evals manifests valid (" + str(len(ids)) + " cases)"


def compile_all():
    import py_compile
    count = 0
    for base in (CLAUDE_DIR / "hooks", SCRIPTS, HARNESS):
        for path in base.rglob("*.py"):
            if "__pycache__" in path.parts:
                continue
            py_compile.compile(str(path), doraise=True)
            count += 1
    return True, str(count) + " python files compile"


def run_unittests():
    import io
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.discover(str(CLAUDE_DIR / "scripts" / "toolbelt" / "tests"),
                                   top_level_dir=str(CLAUDE_DIR / "scripts" / "toolbelt" / "tests")))
    suite.addTests(loader.discover(str(HARNESS / "tests"),
                                   top_level_dir=str(HARNESS / "tests")))
    # StringIO, not devnull: Windows consoles default to cp1252, and writing a
    # failure description containing non-latin chars would crash the reporter.
    runner = unittest.TextTestRunner(verbosity=0, stream=io.StringIO())
    result = runner.run(suite)
    ok = result.wasSuccessful()
    note = str(result.testsRun) + " tests"
    if not ok:
        first = (result.failures + result.errors)[0]
        note += "; first failure: " + str(first[0])
        # Surface the traceback for CI logs, encoded safely for any console.
        print(first[1].encode("ascii", "replace").decode("ascii"))
    return ok, note


def static_layer():
    results = []
    check("agentlint", lambda: run_lint("agentlint.py", CLAUDE_DIR / "agents"), results)
    check("hooklint", lambda: run_lint("hooklint.py", CLAUDE_DIR / "hooks"), results)
    check("settings", validate_settings, results)
    check("manifests", validate_json_files, results)
    check("compile", compile_all, results)
    check("unittests", run_unittests, results)
    return results


# --- behavioral layer ---------------------------------------------------------

def claude_available():
    return shutil.which("claude") is not None


def seed_memory_rule(fixture_data_dir, rule):
    topic = fixture_data_dir / "memory" / "mistakes" / "seeded.md"
    topic.parent.mkdir(parents=True, exist_ok=True)
    topic.write_text(
        "# Mistakes — seeded\n\n## seeded rule\n\n"
        "- **What went wrong:** seeded for eval\n"
        "- **Why it was missed:** n/a\n"
        "- **Prevention rule:** " + rule + "\n"
        "- **Tags:** `seeded`\n"
        "- **Projects:** `(fixture)`\n"
        "- **First seen:** 2026-01-01 · **Recurrences:** 2 · **Last seen:** 2026-01-01\n",
        encoding="utf-8",
    )


def run_trial(case, model, timeout, workdir, keep):
    fixture = Path(workdir) / ("fixture-" + case["id"])
    shutil.copytree(FIXTURE, fixture)
    # THE distribution path: copy the repo's .claude into the fixture.
    shutil.copytree(CLAUDE_DIR, fixture / ".claude",
                    ignore=shutil.ignore_patterns("state", "metrics", "__pycache__",
                                                  "eval-results"))
    setup = case.get("setup") or {}
    if setup.get("seed_memory_rule"):
        seed_memory_rule(fixture / ".ombudsman", setup["seed_memory_rule"])
    subprocess.run(["git", "init", "-q"], cwd=str(fixture), capture_output=True)

    baseline = graders_mod.snapshot_fixture(fixture)
    transcript_path = Path(workdir) / (case["id"] + ".stream.jsonl")

    home_before = snapshot_home()
    cmd = [
        "claude", "-p", case["prompt"],
        "--output-format", "stream-json", "--verbose",
        "--settings", str(HARNESS / "runner-settings.json"),
        "--permission-mode", "acceptEdits",
        "--max-turns", "60",
    ]
    if model:
        cmd += ["--model", model]
    env = dict(os.environ)
    env.pop("CLAUDE_CODE_SESSION_ID", None)  # nested run gets its own session
    # Isolate the CLI's own state from the developer's real ~/.claude; the
    # snapshot_home() check below then PROVES the redirect held (plan §8.2).
    config_dir = Path(workdir) / ("config-" + case["id"])
    config_dir.mkdir(exist_ok=True)
    env["CLAUDE_CONFIG_DIR"] = str(config_dir)
    try:
        with transcript_path.open("w", encoding="utf-8") as out:
            proc = subprocess.run(cmd, cwd=str(fixture), stdout=out,
                                  stderr=subprocess.PIPE, text=True,
                                  timeout=timeout, env=env)
        timed_out = False
        stderr = proc.stderr
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        stderr = str(exc)

    if snapshot_home() != home_before:
        return {"error": "ISOLATION VIOLATION: real ~/.claude changed during trial"}

    metrics = {}
    result_text = ""
    raw_text = ""
    if transcript_path.is_file():
        raw_text = transcript_path.read_text(encoding="utf-8")
        metrics = transcript_mod.parse_lines(raw_text.splitlines())
        for line in raw_text.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict) and event.get("type") == "result":
                result_text = str(event.get("result") or "")
    metrics["_raw_text"] = raw_text

    ctx = graders_mod.TrialContext(fixture, metrics, result_text, baseline)
    assertions = []
    for assertion in case["assertions"]:
        passed, note = graders_mod.run_grader(assertion["grader"], ctx,
                                              assertion.get("args"))
        assertions.append({
            "grader": assertion["grader"],
            "severity": assertion.get("severity", "gate"),
            "passed": bool(passed),
            "note": note,
        })
    trial = {
        "timed_out": timed_out,
        "result_text": result_text,
        "stderr_tail": (stderr or "").strip().splitlines()[-3:],
        "assertions": assertions,
        "tokens": {k: metrics.get(k) for k in
                   ("input_tokens", "output_tokens", "cache_read_input_tokens",
                    "cache_creation_input_tokens")},
        "subagents": metrics.get("task_dispatches", []),
        "num_turns": metrics.get("num_turns"),
    }
    if not keep:
        shutil.rmtree(fixture, ignore_errors=True)
    return trial


def snapshot_home():
    """Snapshot the SENSITIVE parts of the real ~/.claude.

    The isolation claim (plan §8.2) is that the system under test never
    touches the developer's agents/config/memory. The CLI's own session
    bookkeeping (projects/, history, statsig, todos) is redirected via
    CLAUDE_CONFIG_DIR — and a concurrently-running host session (e.g. the
    harness itself launched from inside Claude Code) legitimately writes
    there, so only the sensitive subset is watched.
    """
    real = Path.home() / ".claude"
    if not real.exists():
        return None
    sensitive = ["settings.json", "CLAUDE.md", "agents", "commands",
                 "hooks", "memory", "skills"]
    entries = []
    for name in sensitive:
        target = real / name
        if not target.exists():
            continue
        paths = [target] if target.is_file() else sorted(target.rglob("*"))
        for path in paths:
            try:
                stat = path.stat()
                entries.append((str(path), stat.st_mtime_ns if path.is_file() else 0,
                                stat.st_size if path.is_file() else 0))
            except OSError:
                continue
    return tuple(entries)


def case_verdict(case, trials):
    ok_trials = [t for t in trials if not t.get("error") and not t["timed_out"]]
    if not ok_trials:
        return "FAIL", "all trials errored or timed out"
    for severity in ("critical",):
        for trial in ok_trials:
            for assertion in trial["assertions"]:
                if assertion["severity"] == severity and not assertion["passed"]:
                    return "FAIL", assertion["grader"] + ": " + assertion["note"]
    gate_names = {a["grader"] for t in ok_trials for a in t["assertions"]
                  if a["severity"] == "gate"}
    for name in gate_names:
        passes = sum(1 for t in ok_trials
                     for a in t["assertions"]
                     if a["grader"] == name and a["passed"])
        if passes * 2 <= len(ok_trials):  # strict majority required
            return "FAIL", "gate assertion " + name + " passed only " \
                + str(passes) + "/" + str(len(ok_trials)) + " trials"
    return "PASS", str(len(ok_trials)) + " trial(s) clean"


def behavioral_layer(case_ids, trials_n, model, timeout, keep):
    manifest = json.loads((HARNESS / "evals" / "evals.json").read_text(encoding="utf-8"))
    cases = manifest["cases"]
    if case_ids:
        wanted = set(case_ids)
        cases = [c for c in cases if c["id"] in wanted]
        missing = wanted - {c["id"] for c in cases}
        if missing:
            raise SystemExit("unknown case ids: " + ", ".join(sorted(missing)))

    results = []
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = HARNESS / "eval-results" / stamp
    out_dir.mkdir(parents=True, exist_ok=True)
    for case in cases:
        trials = []
        with tempfile.TemporaryDirectory(prefix="ombudsman-eval-") as workdir:
            for i in range(trials_n):
                trials.append(run_trial(case, model, timeout, workdir, keep))
                src = Path(workdir) / (case["id"] + ".stream.jsonl")
                if src.is_file():  # failed-assertion evidence artifact
                    shutil.copy(src, out_dir / (case["id"] + ".trial" + str(i)
                                                + ".stream.jsonl"))
        verdict, note = case_verdict(case, trials)
        results.append({"id": case["id"], "class": case["class"],
                        "verdict": verdict, "note": note, "trials": trials})
        print(case["id"] + ": " + verdict + " — " + note)

    (out_dir / "results.json").write_text(json.dumps(results, indent=2),
                                          encoding="utf-8")
    lines = ["# Ombudsman behavioral results — " + stamp, "",
             "| case | class | verdict | note |", "|---|---|---|---|"]
    for r in results:
        lines.append("| " + r["id"] + " | " + r["class"] + " | " + r["verdict"]
                     + " | " + r["note"].replace("|", "\\|") + " |")
    (out_dir / "benchmark.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("results: " + str(out_dir))
    return all(r["verdict"] == "PASS" for r in results)


# --- entrypoint ---------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--static", action="store_true")
    parser.add_argument("--behavioral", action="store_true")
    parser.add_argument("--cases", help="comma-separated case ids")
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--model", default=None)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--keep", action="store_true",
                        help="keep per-trial fixture dirs for debugging")
    args = parser.parse_args(argv)

    run_static = args.static or not args.behavioral
    run_behavioral = args.behavioral or not args.static

    ok = True
    if run_static:
        results = static_layer()
        width = max(len(name) for name, *_ in results)
        for name, passed, note, secs in results:
            print(("PASS" if passed else "FAIL") + "  " + name.ljust(width)
                  + "  " + note + "  (" + str(secs) + "s)")
        ok = all(passed for _, passed, _, _ in results)
        print("static layer: " + ("PASS" if ok else "FAIL"))

    if run_behavioral:
        if not claude_available():
            # Visible degradation, never silent (plan §3.4).
            print("behavioral layer: deferred-to-CI (claude CLI not available "
                  "on this surface)")
            if args.behavioral:
                return 1 if not ok else 0
        else:
            case_ids = args.cases.split(",") if args.cases else None
            ok = behavioral_layer(case_ids, args.trials, args.model,
                                  args.timeout, args.keep) and ok

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
