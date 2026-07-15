# Toolbelt Index

One line per script. Agents invoke these instead of doing deterministic work
in-context (plan §5 hard rules: arithmetic beyond one operation → script;
exhaustive enumeration → script; format conversion → script; verbatim
transformation of >20 lines → script).

| Script | Purpose | Usage |
|---|---|---|
| `count.py` | Line/word/char/token-estimate counts for files or stdin | `python3 count.py <file...>` or `... \| python3 count.py -` |
| `jsonmerge.py` | Deep JSON merge (also documents the settings-merge rule) | `python3 jsonmerge.py base.json overlay.json [-o out.json]` |
| `diffstat.py` | Summarize a git diff without pasting it | `git diff \| python3 diffstat.py -` or `python3 diffstat.py --git [ref]` |
| `csvstat.py` | Column stats (count/min/max/mean/distinct) for a CSV | `python3 csvstat.py <file.csv> [--column NAME]` |
| `todo_scan.py` | TODO/FIXME/HACK markers with path:line refs | `python3 todo_scan.py <dir>` |

Every script ships with a test in `tests/` (run by the harness and CI).
Token estimates use the stated `ceil(len/4)` proxy for reproducibility.
