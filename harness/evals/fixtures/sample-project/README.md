# Sample Project (harness fixture)

A tiny, deterministic Python project used as the system-under-test fixture for
Ombudsman behavioral evals. The Ombudsman `.claude/` package is copied in here
per trial — exactly the same mechanism adopters use, so every harness run
regression-tests the mobile/cloud distribution path.

- `calculator.py` — the "product" code. Contains one **seeded latent bug**
  (documented in `SEEDED-BUG.md`) used by the correction/retrospective case.
- `tests/` — stdlib unittest suite (passing; the seeded bug is deliberately
  uncovered).

Run tests: `python3 -m unittest discover -s tests`
