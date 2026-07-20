---
description: Rebuild and install Chronicle.app from the main checkout, then launch it.
---

Rebuild and (re)install the Chronicle app from the main checkout, then open it.

Run these commands as a single sequence, stopping if any step fails. Use the
hardcoded main-checkout path so this works even when invoked from a git worktree
(where the current directory is not the main checkout):

```bash
cd /Users/raine/projects/chronicle
git pull --ff-only
./scripts/install-app.sh --open
```

Notes:
- Always operate on `/Users/raine/projects/chronicle`, not the current worktree.
- `git pull --ff-only` will refuse to merge if `main` has diverged; if it fails,
  report the failure instead of forcing a merge.
- `install-app.sh` builds the Release configuration, installs to
  `/Applications/Chronicle.app`, and `--open` relaunches it.
