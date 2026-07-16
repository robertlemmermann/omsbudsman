# Windows Subprocess Environment

> Last updated: 2026-07-16 · Entries: 1

## Unix-only subprocess env dict in harness hook tests

- **What went wrong:** Hand-crafted Unix-only subprocess env dict (PATH=/usr/bin:/bin:/usr/local/bin, only CLAUDE_PROJECT_DIR set) for hook tests; verified green on Linux but broke on Windows CI.
- **Why it was missed:** Windows Python subprocesses need SYSTEMROOT and other platform env vars; implementation.plan.md §3.2 rule 6 had flagged Windows hook invocation as a verified-by-CI open risk.
- **Prevention rule:** When building subprocess `env=` for hook/harness tests, start from `os.environ.copy()` and override only the specific keys under test (e.g., CLAUDE_PROJECT_DIR) — never hand-craft a full env dict with hardcoded Unix PATH.
- **Tags:** `windows`, `ci`, `subprocess-env`, `test-harness`, `test-engineer`
- **Projects:** `/home/user/omsbudsman`
- **First seen:** 2026-07-16 · **Recurrences:** 1 · **Last seen:** 2026-07-16
