#!/usr/bin/env bash
#
# Builds Chronicle.app (Debug) and launches it straight from the build directory,
# WITHOUT installing it into /Applications. Use this to test a worktree before
# it's merged: it never touches the "real" installed app, and it starts a new,
# independent instance so it can run side-by-side with the installed Chronicle
# (or another worktree's build).
#
# Pass --no-launch to build (and sign) without launching.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
DERIVED="$REPO_ROOT/.build-xcode"
BUILT_APP="$DERIVED/Build/Products/Debug/Chronicle.app"
BUNDLE_ID="com.chronicle.app"

LAUNCH=true
if [[ "${1:-}" == "--no-launch" ]]; then
	LAUNCH=false
fi

echo "==> Generating Xcode project…"
if command -v xcodegen >/dev/null 2>&1; then
	(cd "$REPO_ROOT" && xcodegen generate >/dev/null)
else
	echo "warning: xcodegen not found; using the existing Chronicle.xcodeproj" >&2
fi

echo "==> Building Chronicle (Debug)…"
# ENABLE_DEBUG_DYLIB=NO keeps everything in the main executable. Xcode 16's
# default Debug build emits a separate Chronicle.debug.dylib; re-signing only the
# app bundle below would leave that dylib on its original (ad-hoc) signature, and
# dyld then aborts at launch with a Team ID mismatch. Disabling it makes the
# Debug build sign and load exactly like Release.
xcodebuild build \
	-project "$REPO_ROOT/Chronicle.xcodeproj" \
	-scheme Chronicle \
	-configuration Debug \
	-destination 'platform=macOS' \
	-derivedDataPath "$DERIVED" \
	ENABLE_DEBUG_DYLIB=NO \
	>/dev/null

if [[ ! -d "$BUILT_APP" ]]; then
	echo "error: built app not found at $BUILT_APP" >&2
	exit 1
fi

# A stable code-signing identity keeps the Calendar permission working across
# rebuilds. Ad-hoc signatures (Xcode's default without a Developer account)
# change every build, which invalidates the macOS TCC grant. If the built app is
# currently ad-hoc signed, its stale grant is pinned to a throwaway hash and must
# be cleared once, after which the stable identity's grant persists.
RESET_TCC=false
if codesign -dvv "$BUILT_APP" 2>&1 | grep -q "Signature=adhoc"; then
	RESET_TCC=true
fi

echo "==> Ensuring a stable code-signing identity…"
SIGN_IDENTITY="$("$SCRIPT_DIR/create-signing-cert.sh")"

echo "==> Signing with \"$SIGN_IDENTITY\"…"
codesign --force --options runtime \
	--entitlements "$REPO_ROOT/App/Chronicle.entitlements" \
	--sign "$SIGN_IDENTITY" "$BUILT_APP"
codesign --verify --strict "$BUILT_APP"

if [[ "$RESET_TCC" == true ]]; then
	echo "==> Clearing the stale ad-hoc Calendar permission (one-time)…"
	tccutil reset Calendar "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo
echo "Built: $BUILT_APP"

if [[ "$LAUNCH" == true ]]; then
	echo "==> Launching a new instance…"
	# `open -n` starts a fresh, independent instance instead of reactivating an
	# already-running one, so this worktree build can run alongside the installed
	# Chronicle (or another worktree's build). We deliberately do NOT quit any
	# running instance.
	open -n "$BUILT_APP"
else
	echo "Run it with:  open -n \"$BUILT_APP\""
fi
