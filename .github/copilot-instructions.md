# Copilot instructions

- There is no PR template.
- `Chronicle.xcodeproj` is already gitignored (regenerate with `xcodegen generate`).
- To locate build products (e.g. `Chronicle.app` or the `chronicle-extract` binary),
  ask xcodebuild for the exact directory it uses for this checkout — never glob
  `~/Library/Developer/Xcode/DerivedData/Chronicle-*` and take `head -1`/`ls`. Many
  worktrees each create their own `Chronicle-<hash>` DerivedData dir, so the first
  glob match is usually a stale build from a different worktree. Instead:

  ```bash
  BUILT_PRODUCTS_DIR=$(xcodebuild -showBuildSettings -scheme Chronicle -destination 'platform=macOS' 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
  # then use "$BUILT_PRODUCTS_DIR/Chronicle.app"
  ```

  Swap the scheme (e.g. `chronicle-extract`) to resolve a different target's products
  dir. `BUILT_PRODUCTS_DIR` already encodes the configuration, so no `/Debug` suffix
  is needed. Run `xcodegen generate` first if the `.xcodeproj` is missing.
