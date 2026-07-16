"""Shared helpers for Ombudsman hooks.

Rules (see implementation.plan.md §3.2):
- Python 3 standard library only.
- Paths are self-derived; never assume ~/.claude or inherited env vars.
- Callers wrap their body in run() so a hook can never hard-fail a session.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def project_root():
    """Derive the project root without trusting inherited env vars.

    Priority: this file's location (<root>/.claude/hooks/_common.py), then
    $CLAUDE_PROJECT_DIR (set by Claude Code for the hook process itself),
    then git toplevel, then cwd.
    """
    here = Path(__file__).resolve()
    if len(here.parents) >= 3:
        candidate = here.parents[2]
        if (candidate / ".claude").is_dir():
            return candidate
    env = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if env:
        p = Path(env)
        if p.is_dir():
            return p.resolve()
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip()).resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd()


def claude_dir(root=None):
    return (root or project_root()) / ".claude"


def data_dir(root=None):
    """Writable runtime home. Lives OUTSIDE .claude/ because Claude Code's
    sensitive-file protection blocks agent writes under .claude/ in headless
    sessions (verified platform behavior; allow-rules cannot override it).
    .claude/ therefore stays read-only config; everything the team writes at
    runtime — memory, gate state, metrics — lives here."""
    d = (root or project_root()) / ".ombudsman"
    d.mkdir(parents=True, exist_ok=True)
    gitignore = d / ".gitignore"
    if not gitignore.is_file():
        try:
            gitignore.write_text("# Ephemeral runtime data (memory/ is committed).\n"
                                 "state/\nmetrics/\n", encoding="utf-8")
        except OSError:
            pass
    return d


def state_dir(root=None):
    d = data_dir(root) / "state"
    d.mkdir(parents=True, exist_ok=True)
    return d


def metrics_dir(root=None):
    d = data_dir(root) / "metrics"
    d.mkdir(parents=True, exist_ok=True)
    return d


def read_payload(stdin=None):
    """Parse the hook JSON payload from stdin. Returns {} on any problem.

    Reads bytes and decodes as UTF-8 explicitly: on Windows, text-mode stdin
    defaults to cp1252, which would corrupt or reject non-latin payload text.
    """
    try:
        if stdin is None and hasattr(sys.stdin, "buffer"):
            raw = sys.stdin.buffer.read().decode("utf-8", "replace")
        else:
            raw = (stdin or sys.stdin).read()
    except (OSError, ValueError):
        return {}
    if not raw or not raw.strip():
        return {}
    try:
        obj = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return {}
    return obj if isinstance(obj, dict) else {}


def read_json(path):
    """Read a JSON file; None on any problem."""
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError):
        return None


def atomic_write_json(path, obj):
    """Write JSON atomically (temp file + replace). Returns True on success."""
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
                json.dump(obj, f, indent=2)
                f.write("\n")
            os.replace(tmp, str(path))
        finally:
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        return True
    except (OSError, TypeError, ValueError):
        return False


def append_jsonl(path, obj):
    """Append one JSON line. Returns True on success."""
    try:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(obj) + "\n")
        return True
    except (OSError, TypeError, ValueError):
        return False


def utc_now():
    import datetime
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def run(body):
    """No-fail hook wrapper: an exception must never block a session."""
    try:
        body(read_payload())
    except SystemExit:
        pass
    except Exception:  # noqa: BLE001 — deliberate catch-all (plan §3.2 rule 3)
        pass
    sys.exit(0)
