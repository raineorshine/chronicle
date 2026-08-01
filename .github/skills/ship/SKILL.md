---
name: ship
description: 'Finish a feature branch in a worktree: run quality gates, commit, push, open a PR, squash-merge it, and update the main checkout. Use when done with a change and want it on main.'
---

# Ship (finish feature → merge to main)

Workflow for Chronicle (a Swift/macOS app built with XcodeGen + `xcodebuild`). Take the current feature branch (usually in a worktree), verify it, and land it on `main` as a single commit via a squash-merged PR.

Nothing here writes to the main checkout or to `main` except the final `pull`, so parallel worktree sessions don't interfere: bringing `main` into your branch is a local operation, and GitHub serializes the merges.

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

Generate a commit message from the diff. Match the repo's history style (short imperative subject, e.g. `Sync hover highlight across chart, legend, and sidebar`). End the message with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

The branch's individual commits don't need tidying — the PR is squashed on merge, so only the PR title and body reach `main`.

### 3. Bring `main` into the branch

Only needed if `main` has moved since the branch started, which is common with several worktrees in flight:

```bash
git fetch origin main && git rebase origin/main
```

Purely local to this branch — it cannot disturb another worktree. If it hits conflicts, resolve them (prefer the branch's changes only where the two are genuinely alternatives; when the other side added something separate, **keep both**), `git add` the resolved files, `git rebase --continue`, and repeat.

After resolving, re-run step 1: a clean textual merge can still break the build, and this is where a conflict silently drops someone else's feature.

### 4. Push the branch and open a PR

```bash
git push -u origin HEAD
gh pr create --title "Subject line" --body "..."
```

The **PR title becomes the squashed commit subject** on `main`, so write it as the commit subject: short and imperative. Give the body the same detail the commit message would have carried, ending with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Only push and open the PR when the user has asked to ship.

### 5. Wait for CI, then squash-merge

`.github/workflows/tests.yml` runs on every PR. Let it finish:

```bash
gh pr checks --watch
gh pr merge --squash --delete-branch
```

Squash is what gives `main` its one-commit-per-feature history with the `(#NN)` suffix. Don't use `--merge` or `--rebase`.

If the merge is refused because the branch is behind, go back to **step 3**, push again, and retry — GitHub is doing the same serialization the fast-forward used to, and losing the race costs only a rebase.

### 6. Update the main checkout

```bash
MAIN=$(git worktree list | head -1 | awk '{print $1}') && git -C "$MAIN" pull --ff-only origin main
```

A fast-forward pull is the only thing this flow does to the main checkout. If it refuses, local `main` has commits the remote doesn't — something landed outside this flow. Stop and ask rather than reconciling it here.

### 7. Install

Run ./scripts/install-app.sh to install the new build to /Applications.

This replaces the shared `/Applications/Chronicle.app`, so another session testing the installed app will be testing this build afterwards. When the fresh build is ad-hoc signed the script also resets the app's Calendar permission (it prints a line saying so) — expect to re-grant access on the next launch.

### 8. Clean up

The branch is merged and `--delete-branch` removed it from the remote. If this worktree is finished with, remove it and the local branch from the main checkout:

```bash
BRANCH=$(git branch --show-current) && MAIN=$(git worktree list | head -1 | awk '{print $1}')
git -C "$MAIN" worktree remove <this-worktree-path> && git -C "$MAIN" branch -D "$BRANCH"
```

Only do this when the user confirms the worktree is no longer needed. (`-D`, not `-d`: after a squash merge the branch's commits aren't ancestors of `main`, so git doesn't consider it merged.)
