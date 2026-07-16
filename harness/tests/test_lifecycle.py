"""Copy-over lifecycle test (plan §8.4 — the installerless adoption path,
and the Windows/macOS parity verification when run in the CI matrix).

1. Copy .claude/ into a temp fixture project (the documented adoption step).
2. Hooks resolve and execute under $CLAUDE_PROJECT_DIR-relative paths.
3. session_start emits valid additionalContext JSON from a synthetic payload.
4. Re-copy (update) is idempotent — no duplicate hooks, settings preserved.
5. No writes escape the fixture; the real user home is untouched.
6. Removing the package leaves the host project intact.
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
IGNORE = shutil.ignore_patterns("state", "metrics", "__pycache__", "eval-results")


def snapshot(path):
    entries = []
    path = Path(path)
    if not path.exists():
        return None
    for p in sorted(path.rglob("*")):
        try:
            entries.append((str(p.relative_to(path)),
                            p.stat().st_size if p.is_file() else -1))
        except OSError:
            continue
    return entries


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        # .resolve() matters on Windows: mkdtemp can return an 8.3 short path
        # while the hooks resolve to the long form — string comparisons on
        # paths must use one canonical spelling.
        self.tmp = str(Path(tempfile.mkdtemp(prefix="ombudsman-lifecycle-")).resolve())
        self.project = Path(self.tmp) / "adopting-project"
        self.project.mkdir()
        (self.project / "app.py").write_text("print('host project')\n",
                                             encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def copy_over(self):
        shutil.copytree(REPO / ".claude", self.project / ".claude",
                        ignore=IGNORE, dirs_exist_ok=True)

    def test_full_lifecycle(self):
        home_before = snapshot(Path.home() / ".claude")
        outside_before = snapshot(Path(self.tmp))

        # 1. adopt
        self.copy_over()
        settings = json.loads((self.project / ".claude" / "settings.json")
                              .read_text(encoding="utf-8"))

        # 2. every registered hook command resolves inside the fixture
        hook_files = []
        for event, entries in settings["hooks"].items():
            for entry in entries:
                for hook in entry["hooks"]:
                    cmd = hook["command"]
                    self.assertIn("$CLAUDE_PROJECT_DIR", cmd, event)
                    rel = cmd.split("$CLAUDE_PROJECT_DIR/", 1)[1].strip().strip('"')
                    resolved = self.project / rel
                    self.assertTrue(resolved.is_file(), event + " → " + rel)
                    hook_files.append(resolved)

        # 3. hooks actually execute in the adopted location
        payload = json.dumps({"session_id": "lifecycle01",
                              "cwd": str(self.project)})
        env = dict(os.environ)
        env["CLAUDE_PROJECT_DIR"] = str(self.project)
        for hook in hook_files:
            proc = subprocess.run(
                [sys.executable, str(hook)], input=payload, capture_output=True,
                text=True, timeout=60, env=env,
            )
            self.assertEqual(proc.returncode, 0, hook.name + ": " + proc.stderr)
        start_out = subprocess.run(
            [sys.executable, str(self.project / ".claude" / "hooks" / "session_start.py")],
            input=payload, capture_output=True, text=True, timeout=60, env=env,
        )
        ctx = json.loads(start_out.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn(str(self.project), ctx,
                      "persona must reference the ADOPTED location, not the source repo")

        # 4. re-copy is idempotent
        settings_before = (self.project / ".claude" / "settings.json").read_text(encoding="utf-8")
        agents_before = sorted(p.name for p in (self.project / ".claude" / "agents").glob("*"))
        self.copy_over()
        self.assertEqual(settings_before,
                         (self.project / ".claude" / "settings.json").read_text(encoding="utf-8"))
        self.assertEqual(agents_before,
                         sorted(p.name for p in (self.project / ".claude" / "agents").glob("*")))
        hooks_json = json.dumps(json.loads(settings_before)["hooks"])
        self.assertEqual(hooks_json.count("session_start.py"), 1,
                         "re-copy must not duplicate hook registrations")

        # 5. nothing escaped: user home untouched; nothing outside project dir
        self.assertEqual(snapshot(Path.home() / ".claude"), home_before,
                         "real ~/.claude was modified by the lifecycle")
        outside_after = [e for e in snapshot(Path(self.tmp))
                         if not e[0].startswith("adopting-project")]
        outside_expected = [e for e in (outside_before or [])
                            if not e[0].startswith("adopting-project")]
        self.assertEqual(outside_after, outside_expected)

        # 6. removal leaves the host project intact
        shutil.rmtree(self.project / ".claude")
        self.assertEqual((self.project / "app.py").read_text(encoding="utf-8"),
                         "print('host project')\n")

    def test_merge_rule_for_existing_settings(self):
        """Adopting project already has .claude/settings.json → jsonmerge
        combines hooks without losing the host's keys (README merge rule)."""
        host_claude = self.project / ".claude"
        host_claude.mkdir()
        host_settings = {"model": "opus",
                         "hooks": {"PostToolUse": [{"matcher": "*", "hooks": []}]}}
        (host_claude / "settings.json").write_text(json.dumps(host_settings),
                                                   encoding="utf-8")
        merged = subprocess.run(
            [sys.executable,
             str(REPO / ".claude" / "scripts" / "toolbelt" / "jsonmerge.py"),
             str(host_claude / "settings.json"),
             str(REPO / ".claude" / "settings.json")],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(merged.returncode, 0, merged.stderr)
        result = json.loads(merged.stdout)
        self.assertEqual(result["model"], "opus", "host settings preserved")
        self.assertIn("PostToolUse", result["hooks"])
        self.assertIn("SessionStart", result["hooks"])
        self.assertIn("Stop", result["hooks"])


if __name__ == "__main__":
    unittest.main()
