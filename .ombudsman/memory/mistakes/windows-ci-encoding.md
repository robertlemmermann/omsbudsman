# Windows CI Encoding

> Last updated: 2026-07-16 · Entries: 1

## Incomplete Windows-only encoding fixes (symptom-by-symptom)

- **What went wrong:** After a Windows-only CI failure due to text I/O encoding (e.g., UnicodeEncodeError from non-ASCII characters like '→' on cp1252), fixed only the immediate symptom without auditing other default-encoding text I/O in the same code path (stdout/stderr/log streams, subprocess pipes, hook stdin, tempfile/path handling).
- **Why it was missed:** Pressure to unblock CI; assumption that different I/O layers use different encoding handling; no systematic audit of all text I/O touched by the failing code path.
- **Prevention rule:** After any Windows-only CI encoding failure, audit all default-encoding text I/O (stdout/stderr/log streams, subprocess pipes, hook stdin, tempfile/path handling) touched by that code path and fix them together — do not push a single-symptom fix and wait for the next Windows-latest CI run to surface the next Windows-only encoding defect.
- **Tags:** `windows`, `ci`, `encoding`, `unicode`, `test-harness`
- **Projects:** `/home/user/omsbudsman`
- **First seen:** 2026-07-16 · **Recurrences:** 1 · **Last seen:** 2026-07-16
