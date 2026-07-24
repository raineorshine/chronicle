---
name: ship
description: 'Finish a feature branch in a worktree: run quality gates, commit, rebase on main, squash, fast-forward merge into main, and push. Use when done with a change in this solo repo and want it on main without opening a PR.'
---

# Ship (finish feature → merge to main)

Solo-developer workflow for Chronicle (a Swift/macOS app built with XcodeGen + `xcodebuild`). Take the current feature branch (usually in a worktree), verify it, land it on `main` as a single commit via fast-forward merge, and push. No PR.

## Procedure

### 1. Quality gates (must pass before committing)

Run in order, stop on the first failure, fix, then re-run before proceeding:

```bash
xcodegen generate
xcodebuild build -scheme Chronicle         -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme chronicle-extract -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme ChronicleCore     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- `xcodegen generate` — regenerate the (gitignored) `.xcodeproj` from `project.yml` so any project changes are reflected before building.
- The two `build` commands compile the app and the `chronicle-extract` CLI tool — the whole codebase type-checks and links.
- `xcodebuild test -scheme ChronicleCore` — the unit test suite, matching CI (`.github/workflows/tests.yml`).
- `CODE_SIGNING_ALLOWED=NO` matches CI and avoids local signing prompts. There is no separate format/lint step in this repo.

### 2. Commit all staged and unstaged changes

Generate a commit message from the diff. Match the repo's history style (short imperative subject, e.g. `Sync hover highlight across chart, legend, and sidebar`).

### 3. Rebase on main

Local only:

```bash
git rebase main
```

If the rebase hits conflicts: resolve them (prefer the branch changes unless clearly wrong), `git add` the resolved files, `git rebase --continue`, and repeat until it completes.

### 4. Squash all commits into one

```bash
git reset --soft main && git commit -m "subject" -m "body"
```

Use a single message that describes the overall diff.

### 5. Fast-forward merge into main

Use this exactly — it resolves the branch and main-worktree paths, so nothing is hardcoded:

```bash
BRANCH=$(git branch --show-current) && MAIN=$(git worktree list | head -1 | awk '{print $1}') && git -C "$MAIN" merge --ff-only "$BRANCH"
```

**If `--ff-only` fails with "Not possible to fast-forward":** another worktree merged into `main` in the meantime, so this branch is no longer a direct descendant. This is expected when running parallel worktree sessions and is safe — nothing was merged or lost. Recover by re-integrating on the new `main`:

1. Go back to **step 3** (`git rebase main`) — this replays this branch's single squashed commit onto the updated `main`, surfacing any genuine conflict with the work that landed first. Resolve conflicts the same way.
2. Redo **step 4** (`git reset --soft main && git commit`) to re-squash onto the new base.
3. Retry **step 5**.

Repeat until the fast-forward succeeds. Because `main`'s ref only advances via this atomic `--ff-only` step, at most one worktree wins each round and the others simply rebase and retry — no merge commits, no clobbering.

### 6. Install

Run ./scripts/install-app.sh to install the new build to /Applications.

### 7. Post-merge

- Push `main` to the remote from the main worktree:

  ```bash
  git -C "$MAIN" push origin main
  ```

- The branch is now merged into `main`. If this worktree is finished with, it and the branch can be cleaned up from the main checkout:

  ```bash
  git -C "$MAIN" worktree remove <this-worktree-path> && git -C "$MAIN" branch -d "$BRANCH"
  ```

  Only do this when the user confirms the worktree is no longer needed.
