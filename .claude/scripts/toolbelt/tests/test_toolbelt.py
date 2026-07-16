"""Unit tests for every toolbelt script. Stdlib unittest only — runs on any
surface with `python3 -m unittest discover`.
"""
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

TOOLBELT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLBELT))

import count            # noqa: E402
import csvstat          # noqa: E402
import diffstat         # noqa: E402
import jsonmerge        # noqa: E402
import todo_scan        # noqa: E402


class CountTest(unittest.TestCase):
    def test_count_text(self):
        counts = count.count_text("one two\nthree\n")
        self.assertEqual(counts["lines"], 2)
        self.assertEqual(counts["words"], 3)
        self.assertEqual(counts["chars"], 14)
        self.assertEqual(counts["tokens_est"], 4)  # ceil(14/4)

    def test_empty(self):
        counts = count.count_text("")
        self.assertEqual(counts, {"lines": 0, "words": 0, "chars": 0, "tokens_est": 0})

    def test_file_main(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sample.txt"
            path.write_text("hello world\n", encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                status = count.main([str(path)])
            self.assertEqual(status, 0)
            self.assertIn("words=2", buf.getvalue())

    def test_missing_file(self):
        self.assertEqual(count.main(["/nonexistent/nope.txt"]), 1)


class JsonMergeTest(unittest.TestCase):
    def test_scalar_overlay_wins(self):
        self.assertEqual(jsonmerge.deep_merge({"a": 1}, {"a": 2}), {"a": 2})

    def test_dicts_merge_recursively(self):
        merged = jsonmerge.deep_merge(
            {"hooks": {"Stop": [1], "SessionStart": [2]}},
            {"hooks": {"Stop": [3]}, "permissions": {"deny": []}},
        )
        self.assertEqual(merged["hooks"]["Stop"], [1, 3])
        self.assertEqual(merged["hooks"]["SessionStart"], [2])
        self.assertIn("permissions", merged)

    def test_lists_dedupe_exact(self):
        self.assertEqual(jsonmerge.deep_merge([1, 2], [2, 3]), [1, 2, 3])

    def test_settings_merge_is_idempotent(self):
        base = {"hooks": {"Stop": [{"matcher": "*"}]}}
        once = jsonmerge.deep_merge(base, base)
        twice = jsonmerge.deep_merge(once, base)
        self.assertEqual(once, twice)
        self.assertEqual(once["hooks"]["Stop"], base["hooks"]["Stop"])

    def test_main_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            a = Path(tmp) / "a.json"
            b = Path(tmp) / "b.json"
            out = Path(tmp) / "out.json"
            a.write_text(json.dumps({"x": {"y": 1}}), encoding="utf-8")
            b.write_text(json.dumps({"x": {"z": 2}}), encoding="utf-8")
            status = jsonmerge.main([str(a), str(b), "-o", str(out)])
            self.assertEqual(status, 0)
            merged = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(merged, {"x": {"y": 1, "z": 2}})


class DiffstatTest(unittest.TestCase):
    DIFF = """\
diff --git a/foo.py b/foo.py
--- a/foo.py
+++ b/foo.py
@@ -1,2 +1,3 @@
-old line
+new line
+another line
diff --git a/bar.py b/bar.py
--- /dev/null
+++ b/bar.py
@@ -0,0 +1,1 @@
+created
"""

    def test_parse(self):
        files = diffstat.parse_diff(self.DIFF.splitlines())
        self.assertEqual(files["foo.py"], {"added": 2, "removed": 1})
        self.assertEqual(files["bar.py"], {"added": 1, "removed": 0})

    def test_deleted_file_target_skipped(self):
        diff = "--- a/gone.py\n+++ /dev/null\n-was here\n"
        files = diffstat.parse_diff(diff.splitlines())
        self.assertEqual(files, {})


class CsvstatTest(unittest.TestCase):
    def _write(self, tmp):
        path = Path(tmp) / "data.csv"
        path.write_text("name,score\na,1\nb,3\na,\n", encoding="utf-8")
        return path

    def test_numeric_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp)
            buf = io.StringIO()
            with redirect_stdout(buf):
                status = csvstat.main([str(path), "--column", "score"])
            self.assertEqual(status, 0)
            out = buf.getvalue()
            self.assertIn("count=2", out)
            self.assertIn("mean=2.0", out)

    def test_text_column_no_numeric_stats(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp)
            buf = io.StringIO()
            with redirect_stdout(buf):
                csvstat.main([str(path), "--column", "name"])
            out = buf.getvalue()
            self.assertIn("distinct=2", out)
            self.assertNotIn("mean=", out)

    def test_unknown_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp)
            self.assertEqual(csvstat.main([str(path), "--column", "nope"]), 1)


class TodoScanTest(unittest.TestCase):
    def test_finds_markers_and_skips_junk_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "app.py").write_text("x = 1  # TODO fix\n", encoding="utf-8")
            junk = root / "node_modules"
            junk.mkdir()
            (junk / "dep.js").write_text("// FIXME ignore me\n", encoding="utf-8")
            hits = todo_scan.scan(root, ["TODO", "FIXME"])
            self.assertEqual(len(hits), 1)
            self.assertTrue(hits[0][0].endswith("app.py"))
            self.assertEqual(hits[0][2], "TODO")


class ScriptsAreExecutableAsProcessesTest(unittest.TestCase):
    """Each toolbelt script must run as a subprocess (agents call them via
    Bash), not just as an importable module."""

    def test_help_runs(self):
        for name in ("count.py", "jsonmerge.py", "diffstat.py",
                     "csvstat.py", "todo_scan.py"):
            proc = subprocess.run(
                [sys.executable, str(TOOLBELT / name), "--help"],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(proc.returncode, 0, name + ": " + proc.stderr)


if __name__ == "__main__":
    unittest.main()
