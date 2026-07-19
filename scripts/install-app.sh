#!/usr/bin/env bash
#
# Builds Chronicle.app (Release) and installs it into /Applications so it shows
# up in Spotlight and Launchpad. Re-run any time to update the installed app.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO_ROOT/.build-xcode"
BUILT_APP="$DERIVED/Build/Products/Release/Chronicle.app"
DEST="/Applications/Chronicle.app"

echo "==> Generating Xcode project…"
if command -v xcodegen >/dev/null 2>&1; then
	(cd "$REPO_ROOT" && xcodegen generate >/dev/null)
else
	echo "warning: xcodegen not found; using the existing Chronicle.xcodeproj" >&2
fi

echo "==> Building Chronicle (Release)…"
xcodebuild build \
	-project "$REPO_ROOT/Chronicle.xcodeproj" \
	-scheme Chronicle \
	-configuration Release \
	-destination 'platform=macOS' \
	-derivedDataPath "$DERIVED" \
	>/dev/null

if [[ ! -d "$BUILT_APP" ]]; then
	echo "error: built app not found at $BUILT_APP" >&2
	exit 1
fi

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

echo
echo "Installed. Launch it from Spotlight (Cmd-Space → \"Chronicle\") or Launchpad."
echo "Pass --open to launch it now:  ./scripts/install-app.sh --open"

if [[ "${1:-}" == "--open" ]]; then
	echo "==> Launching…"
	open "$DEST"
fi
