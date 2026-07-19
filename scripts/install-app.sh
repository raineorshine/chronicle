#!/usr/bin/env bash
#
# Builds Chronicle.app (Release) and installs it into /Applications so it shows
# up in Spotlight and Launchpad. Re-run any time to update the installed app.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
DERIVED="$REPO_ROOT/.build-xcode"
BUILT_APP="$DERIVED/Build/Products/Release/Chronicle.app"
DEST="/Applications/Chronicle.app"
BUNDLE_ID="com.chronicle.app"

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

# A stable code-signing identity keeps the Calendar permission working across
# rebuilds. Ad-hoc signatures (Xcode's default without a Developer account)
# change every build, which invalidates the macOS TCC grant. If the currently
# installed app is ad-hoc signed, its stale grant is pinned to a throwaway hash
# and must be cleared once, after which the stable identity's grant persists.
RESET_TCC=false
if [[ -d "$DEST" ]] && codesign -dvv "$DEST" 2>&1 | grep -q "Signature=adhoc"; then
	RESET_TCC=true
fi

echo "==> Ensuring a stable code-signing identity…"
SIGN_IDENTITY="$("$SCRIPT_DIR/create-signing-cert.sh")"

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

echo "==> Signing with \"$SIGN_IDENTITY\"…"
codesign --force --options runtime \
	--entitlements "$REPO_ROOT/App/Chronicle.entitlements" \
	--sign "$SIGN_IDENTITY" "$DEST"
codesign --verify --strict "$DEST"

if [[ "$RESET_TCC" == true ]]; then
	echo "==> Clearing the stale ad-hoc Calendar permission (one-time)…"
	tccutil reset Calendar "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo
echo "Installed. Launch it from Spotlight (Cmd-Space → \"Chronicle\") or Launchpad."
echo "Pass --open to launch it now:  ./scripts/install-app.sh --open"

if [[ "${1:-}" == "--open" ]]; then
	echo "==> Launching…"
	# `open "$DEST"` only reactivates an already-running instance, so a stale
	# copy would stay on screen. Quit any running instance first, force-kill if
	# it doesn't exit, then start the freshly-installed bundle with `open -n`.
	osascript -e 'quit app "Chronicle"' >/dev/null 2>&1 || true
	for _ in $(seq 1 20); do
		pids=$(pgrep -f "Chronicle.app/Contents/MacOS/Chronicle" || true)
		[[ -z "$pids" ]] && break
		sleep 0.25
	done
	pids=$(pgrep -f "Chronicle.app/Contents/MacOS/Chronicle" || true)
	[[ -n "$pids" ]] && kill $pids 2>/dev/null || true
	open -n "$DEST"
fi
