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

# --- Orchestrator direct-write violation detector ---
# SubagentStop chosen over Stop: fires after every Task return, enabling early
# detection within the same session rather than only at clean exit.
python3 - "$PROJECT_ROOT" "$INPUT" <<'PYDETECT'
import json, sys, pathlib, datetime, re

project_root = pathlib.Path(sys.argv[1])
raw = sys.argv[2]

WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

session_id = payload.get("session_id") or "unknown"
transcript_path_str = payload.get("transcript_path") or ""

if not transcript_path_str:
    print("orchestrator-direct-write detector: no transcript_path in payload", file=sys.stderr)
    sys.exit(0)

transcript_path = pathlib.Path(transcript_path_str)
if not transcript_path.is_file():
    print(f"orchestrator-direct-write detector: transcript not readable: {transcript_path}", file=sys.stderr)
    sys.exit(0)

# Parse top-level transcript for tool_use entries from the main session.
# Subagent tool_use entries live in separate tasks/*.output files, NOT in the
# main transcript_path. Every tool_use in transcript_path is a main-session
# action, so no per-entry filtering is needed.
violations = []
try:
    with transcript_path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = entry.get("message") or {}
            role = message.get("role") or entry.get("role") or ""
            if role != "assistant":
                continue
            content = message.get("content") or entry.get("content") or []
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "tool_use":
                    continue
                tool_name = block.get("name") or ""
                if tool_name not in WRITE_TOOLS:
                    continue
                inp = block.get("input") or {}
                file_path = (
                    inp.get("file_path")
                    or inp.get("path")
                    or inp.get("notebook_path")
                    or ""
                )
                excerpt = str(file_path)[-80:] if file_path else "(no path)"
                violations.append((tool_name, excerpt))
except OSError as exc:
    print(f"orchestrator-direct-write detector: read error: {exc}", file=sys.stderr)
    sys.exit(0)

if not violations:
    sys.exit(0)

mistakes_dir = project_root / ".claude" / "memory" / "mistakes"
mistakes_dir.mkdir(parents=True, exist_ok=True)
mistakes_file = mistakes_dir / "orchestrator-direct-write.md"
global_index  = pathlib.Path.home() / ".claude" / "memory" / "mistakes" / "INDEX.md"

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

seen = {}
for tool_name, excerpt in violations:
    seen[(tool_name, excerpt)] = (tool_name, excerpt)
unique_violations = list(seen.values())

if mistakes_file.is_file():
    existing = mistakes_file.read_text()
else:
    existing = ""

# Idempotency: skip if this session_id is already recorded.
if session_id != "unknown" and session_id in existing:
    sys.exit(0)

recurrence_match = re.search(r'\*\*Recurrences:\*\*\s*(\d+)', existing)
if recurrence_match:
    new_count = int(recurrence_match.group(1)) + 1
    existing = (
        existing[:recurrence_match.start()]
        + f"**Recurrences:** {new_count}"
        + existing[recurrence_match.end():]
    )
    existing = re.sub(r'\*\*Last seen:\*\*\s*[\d\-]+', f"**Last seen:** {ts[:10]}", existing)
    existing = re.sub(r'Entries:\s*(\d+)', lambda m: f"Entries: {int(m.group(1)) + 1}", existing)
    tools_block = "\n".join(f"  - `{t}` on `{e}`" for t, e in unique_violations)
    append_block = (
        f"\n### Recurrence — {ts}\n"
        f"- **Session:** `{session_id}`\n"
        f"- **Violations:**\n{tools_block}\n"
    )
    mistakes_file.write_text(existing + append_block)
else:
    tools_block = "\n".join(f"  - `{t}` on `{e}`" for t, e in unique_violations)
    content = (
        f"# Mistakes — orchestrator-direct-write\n\n"
        f"> Last updated: {ts[:10]} · Entries: 1\n\n"
        f"## Orchestrator used Edit/Write tools directly, bypassing engineer dispatch\n\n"
        f"- **What went wrong:** The main orchestrator session called a file-write tool "
        f"({', '.join(sorted(WRITE_TOOLS))}) directly instead of dispatching the "
        f"backend-engineer or frontend-engineer subagent.\n"
        f"- **Why it was missed:** No runtime enforcement exists; only post-hoc detection.\n"
        f"- **Prevention rule:** Before any code or config change, dispatch researcher → "
        f"planner → engineers → qa → auditor in sequence; the main session must never "
        f"write files directly.\n"
        f"- **Tags:** `orchestrator-direct-write`, `orchestrator`, `protocol-enforcement`\n"
        f"- **First seen:** {ts[:10]} · **Recurrences:** 1 · **Last seen:** {ts[:10]}\n\n"
        f"### Initial detection — {ts}\n"
        f"- **Session:** `{session_id}`\n"
        f"- **Violations:**\n{tools_block}\n"
    )
    mistakes_file.write_text(content)

try:
    global_index.parent.mkdir(parents=True, exist_ok=True)
    tag_line = "- `orchestrator-direct-write`: see `mistakes/orchestrator-direct-write.md`"
    if global_index.is_file():
        idx_text = global_index.read_text()
        if "orchestrator-direct-write" not in idx_text:
            global_index.write_text(idx_text.rstrip() + "\n" + tag_line + "\n")
    else:
        global_index.write_text(
            "# Mistakes Index — Global\n\nTag → file map for prevention rules.\n\n"
            + tag_line + "\n"
        )
except OSError as exc:
    print(f"orchestrator-direct-write detector: index update failed: {exc}", file=sys.stderr)
PYDETECT

exit 0
