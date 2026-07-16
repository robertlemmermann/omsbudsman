# Stale-branch PR creation

> Last updated: 2026-07-16 · Entries: 1

## Stale-branch PR creation

- **What went wrong:** Opened a PR from a branch that had not been synced with the target base (`git fetch`/merge skipped); the base had undergone a major restructure since the branch point, making the PR unmergeable at creation and requiring a full re-port of the work after the human flagged merge conflicts.
- **Why it was missed:** Orchestrator agent did not validate branch sync status before opening PR.
- **Prevention rule:** Before pushing a branch and opening/updating a PR, run `git fetch origin` and merge/diff `origin/<base>` into the branch first; if materially behind (large divergence or known restructure), re-port onto the current base before opening the PR.
- **Tags:** `git`, `pr-workflow`, `stale-branch`, `orchestrator`
- **Projects:** `/home/user/omsbudsman`
- **First seen:** 2026-07-16 · **Recurrences:** 1 · **Last seen:** 2026-07-16
