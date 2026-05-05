#!/usr/bin/env bash
# Phase 6: per-subagent telemetry. Append one JSONL record per Task return
# to ~/.claude/metrics/sessions.jsonl. Must exit 0 fast — never blocks.
#
# Opt out by setting CLAUDE_MULTIAGENT_NO_METRICS=1.
set -e

if [ "${CLAUDE_MULTIAGENT_NO_METRICS:-0}" = "1" ]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
PROJECT_ROOT="${LIBRARIAN_PROJECT_ROOT:-$(pwd)}"
METRICS_DIR="$GLOBAL_ROOT/metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || true

JSONL="$METRICS_DIR/sessions.jsonl"

python3 - "$JSONL" "$PROJECT_ROOT" "$INPUT" <<'PY'
import json, sys, datetime, pathlib

jsonl_path = pathlib.Path(sys.argv[1])
project_root = sys.argv[2]
raw = sys.argv[3]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

# Claude Code's SubagentStop payload shape can vary across versions; tolerate
# missing fields. The schema we record is stable regardless.
def get(obj, *path, default=None):
    cur = obj
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur

usage = get(payload, "usage") or get(payload, "subagent", "usage") or {}

record = {
    "kind": "subagent",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "session_id": payload.get("session_id"),
    "project_root": project_root,
    "agent": (
        get(payload, "subagent_type")
        or get(payload, "subagent", "type")
        or get(payload, "agent")
    ),
    "model": get(payload, "model") or get(payload, "subagent", "model"),
    "input_tokens": usage.get("input_tokens"),
    "output_tokens": usage.get("output_tokens"),
    "cache_read_tokens": usage.get("cache_read_input_tokens") or usage.get("cache_read_tokens"),
    "cache_creation_tokens": usage.get("cache_creation_input_tokens") or usage.get("cache_creation_tokens"),
    "duration_ms": payload.get("duration_ms") or get(payload, "subagent", "duration_ms"),
    "blocked": bool(payload.get("blocked")),
    "outcome": payload.get("outcome") or ("blocked" if payload.get("blocked") else "ok"),
}

# Rotate if the active file exceeds 10 MB. Keep the last 4 archives.
try:
    if jsonl_path.is_file() and jsonl_path.stat().st_size > 10 * 1024 * 1024:
        import gzip, shutil, glob, os
        date_tag = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
        archive = jsonl_path.parent / f"sessions.{date_tag}.jsonl.gz"
        with jsonl_path.open("rb") as src, gzip.open(archive, "wb") as dst:
            shutil.copyfileobj(src, dst)
        jsonl_path.write_text("")
        archives = sorted(glob.glob(str(jsonl_path.parent / "sessions.*.jsonl.gz")))
        for old in archives[:-4]:
            try: os.remove(old)
            except OSError: pass
except OSError:
    pass

try:
    with jsonl_path.open("a") as f:
        f.write(json.dumps(record) + "\n")
except OSError:
    pass
PY

exit 0
