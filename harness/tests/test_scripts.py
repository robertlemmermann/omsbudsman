"""Unit tests for the system scripts: transcript parser, verify gate,
lints (including that they catch deliberately broken inputs), memlint,
and the state helper's error paths.
"""
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / ".claude" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import agentlint      # noqa: E402
import hooklint       # noqa: E402
import memlint        # noqa: E402
import transcript     # noqa: E402
import verify         # noqa: E402


def stream_event(usage=None, model="claude-sonnet-5", content=None, etype="assistant"):
    event = {"type": etype}
    message = {}
    if usage:
        message["usage"] = usage
        message["model"] = model
    if content is not None:
        message["content"] = content
    if message:
        event["message"] = message
    return json.dumps(event)


class TranscriptTest(unittest.TestCase):
    def test_aggregates_usage_routing_and_blocked(self):
        lines = [
            stream_event(usage={"input_tokens": 100, "output_tokens": 50,
                                "cache_read_input_tokens": 400,
                                "cache_creation_input_tokens": 20},
                         content=[{"type": "tool_use", "name": "Task",
                                   "input": {"subagent_type": "researcher"}}]),
            stream_event(usage={"input_tokens": 10, "output_tokens": 5},
                         model="claude-haiku-4-5",
                         content=[{"type": "text",
                                   "text": "BLOCKED: needs narrower scope"}]),
            json.dumps({"type": "result", "num_turns": 4}),
            "not json at all",
            "",
        ]
        m = transcript.parse_lines(lines)
        self.assertEqual(m["input_tokens"], 110)
        self.assertEqual(m["output_tokens"], 55)
        self.assertEqual(m["cache_read_input_tokens"], 400)
        self.assertEqual(m["cache_hit_rate"], round(400 / 510, 3))
        self.assertEqual(m["task_dispatches"], ["researcher"])
        self.assertEqual(m["blocked_returns"], 1)
        self.assertEqual(m["num_turns"], 4)
        self.assertEqual(set(m["models"]),
                         {"claude-sonnet-5", "claude-haiku-4-5"})

    def test_empty_transcript(self):
        m = transcript.parse_lines([])
        self.assertEqual(m["input_tokens"], 0)
        self.assertIsNone(m["cache_hit_rate"])
        self.assertEqual(m["subagent_count"], 0)


class VerifyTest(unittest.TestCase):
    def test_discovers_and_passes_fixture(self):
        fixture = REPO / "harness" / "evals" / "fixtures" / "sample-project"
        cmd, reason = verify.discover(fixture)
        self.assertIsNotNone(cmd)
        self.assertIn("unittest", " ".join(cmd))
        buf = io.StringIO()
        with redirect_stdout(buf):
            status = verify.main(["--root", str(fixture)])
        self.assertEqual(status, 0)
        self.assertIn("VERIFY RESULT: pass", buf.getvalue())

    def test_skip_when_nothing_recognized(self):
        with tempfile.TemporaryDirectory() as tmp:
            buf = io.StringIO()
            with redirect_stdout(buf):
                status = verify.main(["--root", tmp])
            self.assertEqual(status, 3)
            self.assertIn("VERIFY RESULT: skip", buf.getvalue())

    def test_fail_on_red_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            tests = Path(tmp) / "tests"
            tests.mkdir()
            (tests / "test_red.py").write_text(
                "import unittest\n\nclass T(unittest.TestCase):\n"
                "    def test_red(self):\n        self.fail('seeded')\n",
                encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                status = verify.main(["--root", tmp])
            self.assertEqual(status, 1)
            self.assertIn("VERIFY RESULT: fail", buf.getvalue())


class LintCatchesBreakageTest(unittest.TestCase):
    """Acceptance criterion 4: a deliberately broken file is caught."""

    def test_agentlint_flags_broken_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "rogue.md"
            bad.write_text("---\nname: mismatch\nmodel: gpt-9000\n---\n\n"
                           "# Rogue\n\nNo caps here.\n", encoding="utf-8")
            findings = agentlint.lint_file(bad)
            self.assertTrue(any("!= filename" in f for f in findings))
            self.assertTrue(any("unknown model" in f for f in findings))
            self.assertTrue(any("tools" in f for f in findings))
            self.assertTrue(any("cap" in f.lower() for f in findings))

    def test_agentlint_passes_shipped_agents(self):
        for path in (REPO / ".claude" / "agents").glob("*.md"):
            self.assertEqual(agentlint.lint_file(path), [], path.name)

    def test_hooklint_flags_dangerous_hook(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "evil_hook.py"
            bad.write_text(
                "import subprocess, os\n"
                "subprocess.run('rm -rf /', shell=True)\n"
                "eval('1+1')\n",
                encoding="utf-8")
            findings = hooklint.lint_file(bad)
            self.assertTrue(any("shell=True" in f for f in findings))
            self.assertTrue(any("eval" in f for f in findings))
            self.assertTrue(any("no-fail" in f for f in findings))

    def test_hooklint_passes_shipped_hooks(self):
        for path in (REPO / ".claude" / "hooks").glob("*.py"):
            self.assertEqual(hooklint.lint_file(path), [], path.name)


class MemlintTest(unittest.TestCase):
    def test_clean_seed_memory(self):
        findings = memlint.lint(REPO / ".claude" / "memory", 64)
        self.assertEqual(findings, [])

    def test_flags_stale_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            mem = Path(tmp)
            (mem / "INDEX.md").write_text("# idx\n", encoding="utf-8")
            (mem / "facts.md").write_text(
                "# Facts\n\n- **old** — thing. Added 2020-01-01. "
                "Recurrences: 1. Last seen: 2020-01-01.\n", encoding="utf-8")
            findings = memlint.lint(mem, 64)
            self.assertTrue(any("archive candidate" in f for f in findings))


class StateHelperTest(unittest.TestCase):
    def test_bad_usage_exits_nonzero(self):
        proc = subprocess.run(
            [sys.executable, str(SCRIPTS / "state.py"), "--root", ".",
             "--session", "x", "set-qa", "maybe"],
            capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)

    def test_corrupt_state_file_recovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".claude" / "state"
            state_dir.mkdir(parents=True)
            (state_dir / "session-x.json").write_text("{corrupt", encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(SCRIPTS / "state.py"), "--root", tmp,
                 "--session", "x", "set-qa", "pass"],
                capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            state = json.loads((state_dir / "session-x.json").read_text(encoding="utf-8"))
            self.assertEqual(state["qa_verdicts"], ["pass"])


if __name__ == "__main__":
    unittest.main()
