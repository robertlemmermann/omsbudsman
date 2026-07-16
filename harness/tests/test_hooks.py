"""End-to-end hook tests: drive every hook exactly as Claude Code does —
a subprocess with a JSON payload on stdin — against a temp copy of the
package, simulating a full session (start → prompt → dispatch → subagent
return → stop gate).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SESSION = "testsession01"


def hook_env(project):
    """Environment for a hook subprocess. Inherit the real environment —
    Windows Python needs SYSTEMROOT etc. — and point CLAUDE_PROJECT_DIR at
    the temp project, exactly as Claude Code does."""
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = str(project)
    return env


def run_hook(project, name, payload):
    """Invoke a hook as Claude Code would: python3 <hook> with JSON stdin."""
    proc = subprocess.run(
        [sys.executable, str(project / ".claude" / "hooks" / name)],
        input=payload if isinstance(payload, str) else json.dumps(payload),
        capture_output=True, text=True, timeout=60,
        env=hook_env(project),
    )
    return proc


class HookSessionTest(unittest.TestCase):
    """One simulated session, in order, sharing a temp project."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ombudsman-hooktest-")
        cls.project = Path(cls.tmp) / "proj"
        cls.project.mkdir()
        shutil.copytree(REPO / ".claude", cls.project / ".claude",
                        ignore=shutil.ignore_patterns("state", "metrics",
                                                      "__pycache__"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def state_file(self):
        return self.project / ".ombudsman" / "state" / ("session-" + SESSION + ".json")

    def test_01_session_start_injects_context_and_seeds_memory(self):
        proc = run_hook(self.project, "session_start.py",
                        {"session_id": SESSION, "cwd": str(self.project)})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertIn("orchestrator.md", ctx)
        self.assertIn("session-" + SESSION + ".json", ctx)
        self.assertIn("state.py", ctx)
        self.assertTrue((self.project / ".ombudsman" / "memory" / "INDEX.md").is_file())
        self.assertTrue((self.project / ".ombudsman" / "memory" / "mistakes"
                         / "INDEX.md").is_file())

    def test_02_user_prompt_submit_flags_corrections_only(self):
        proc = run_hook(self.project, "user_prompt_submit.py",
                        {"session_id": SESSION, "prompt": "please add a login page"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(self.state_file().is_file(),
                         "benign prompt must not create retro state")

        proc = run_hook(self.project, "user_prompt_submit.py",
                        {"session_id": SESSION,
                         "prompt": "no, that's wrong — you broke the tests"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        state = json.loads(self.state_file().read_text(encoding="utf-8"))
        self.assertTrue(state["retro_needed"])
        self.assertEqual(len(state["retro_prompts"]), 1)

    def test_03_state_helper_records_gates(self):
        script = self.project / ".claude" / "scripts" / "state.py"
        base = [sys.executable, str(script), "--root", str(self.project),
                "--session", SESSION]
        for args in (["init", "--task-class", "implement", "--diff"],
                     ["set-qa", "pass"], ["set-qa", "fail"], ["set-qa", "pass"]):
            proc = subprocess.run(base + args, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        state = json.loads(self.state_file().read_text(encoding="utf-8"))
        self.assertEqual(state["task_class"], "implement")
        self.assertEqual(state["qa_verdicts"], ["pass", "fail", "pass"])
        self.assertTrue(state["diff_produced"])
        self.assertTrue(state["retro_needed"], "init must not clobber retro flags")

    def test_04_pre_tool_use_tracks_dispatch(self):
        proc = run_hook(self.project, "pre_tool_use.py", {
            "session_id": SESSION, "tool_name": "Task",
            "tool_input": {"subagent_type": "researcher",
                           "prompt": "TASK: map the calculator module"},
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        agents = json.loads((self.project / ".ombudsman" / "state"
                             / ("agents-" + SESSION + ".json")).read_text(encoding="utf-8"))
        self.assertEqual(agents["agents"][-1]["agent"], "researcher")
        self.assertEqual(agents["agents"][-1]["status"], "active")
        self.assertIn("map the calculator", agents["agents"][-1]["description"])

    def test_05_subagent_stop_records_descoped_telemetry(self):
        proc = run_hook(self.project, "subagent_stop.py", {
            "session_id": SESSION, "subagent_type": "researcher",
            "last_assistant_message": "FINDINGS:\n- average: calculator.py:21",
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        jsonl = self.project / ".ombudsman" / "metrics" / "sessions.jsonl"
        records = [json.loads(l) for l in jsonl.read_text(encoding="utf-8").splitlines()]
        rec = records[-1]
        self.assertEqual(rec["kind"], "subagent")
        self.assertEqual(rec["agent"], "researcher")
        self.assertFalse(rec["blocked"])
        # Descoped by design: no invented usage fields (plan §7).
        for forbidden in ("input_tokens", "output_tokens", "model"):
            self.assertNotIn(forbidden, rec)
        agents = json.loads((self.project / ".ombudsman" / "state"
                             / ("agents-" + SESSION + ".json")).read_text(encoding="utf-8"))
        self.assertEqual(agents["agents"][-1]["status"], "done")

    def test_06_stop_blocks_until_auditor_and_retro_clear(self):
        proc = run_hook(self.project, "stop.py", {"session_id": SESSION})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        decision = json.loads(proc.stdout)
        self.assertEqual(decision["decision"], "block")
        self.assertIn("auditor not run", decision["reason"])
        self.assertIn("corrections happened", decision["reason"])

        script = self.project / ".claude" / "scripts" / "state.py"
        base = [sys.executable, str(script), "--root", str(self.project),
                "--session", SESSION]
        subprocess.run(base + ["set-auditor", "approve"], capture_output=True)
        subprocess.run(base + ["set-retro", "false"], capture_output=True)

        proc = run_hook(self.project, "stop.py", {"session_id": SESSION})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "", "gates cleared — no block expected")
        jsonl = self.project / ".ombudsman" / "metrics" / "sessions.jsonl"
        records = [json.loads(l) for l in jsonl.read_text(encoding="utf-8").splitlines()]
        summary = records[-1]
        self.assertEqual(summary["kind"], "session")
        self.assertEqual(summary["task_class"], "implement")
        self.assertEqual(summary["auditor_verdict"], "approve")
        self.assertEqual(summary["qa_pass_rate"], round(2 / 3, 3))
        self.assertTrue(summary["retro_triggered"])

    def test_07_stop_respects_stop_hook_active(self):
        proc = run_hook(self.project, "stop.py",
                        {"session_id": SESSION, "stop_hook_active": True})
        self.assertEqual(proc.stdout.strip(), "")


class HookRobustnessTest(unittest.TestCase):
    """No-fail contract: hooks exit 0 on any input (plan §3.2 rule 3)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ombudsman-robust-")
        cls.project = Path(cls.tmp) / "proj"
        cls.project.mkdir()
        shutil.copytree(REPO / ".claude", cls.project / ".claude",
                        ignore=shutil.ignore_patterns("state", "metrics",
                                                      "__pycache__"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    HOOKS = ("session_start.py", "user_prompt_submit.py", "pre_tool_use.py",
             "subagent_stop.py", "stop.py")

    def test_empty_stdin(self):
        for hook in self.HOOKS:
            proc = run_hook(self.project, hook, "")
            self.assertEqual(proc.returncode, 0, hook + ": " + proc.stderr)

    def test_garbage_stdin(self):
        for hook in self.HOOKS:
            proc = run_hook(self.project, hook, "{not json!!!")
            self.assertEqual(proc.returncode, 0, hook + ": " + proc.stderr)

    def test_wrong_types(self):
        payload = {"session_id": ["not", "a", "string"], "prompt": 42,
                   "tool_input": "nope"}
        for hook in self.HOOKS:
            proc = run_hook(self.project, hook, payload)
            self.assertEqual(proc.returncode, 0, hook + ": " + proc.stderr)


if __name__ == "__main__":
    unittest.main()
