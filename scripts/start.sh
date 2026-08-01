#!/usr/bin/env bash
#
# Builds Chronicle.app (Debug) and launches it straight from the build directory,
# WITHOUT installing it into /Applications. Use this to test a worktree before
# it's merged: it never touches the "real" installed app, and it starts a new,
# independent instance so it can run side-by-side with the installed Chronicle
# (or another worktree's build).
#
# Pass --no-launch to build (and sign) without launching.
# Pass --reset-permissions to force-clear the Calendar permission (see below).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
DERIVED="$REPO_ROOT/.build-xcode"
BUILT_APP="$DERIVED/Build/Products/Debug/Chronicle.app"
# Debug builds use a dev-only bundle ID (see project.yml), so the permission
# reset below can never touch the installed /Applications/Chronicle.app.
BUNDLE_ID="com.chronicle.app.dev"

LAUNCH=true
FORCE_RESET_TCC=false
for arg in "$@"; do
	case "$arg" in
		--no-launch) LAUNCH=false ;;
		--reset-permissions) FORCE_RESET_TCC=true ;;
		*) echo "error: unknown option: $arg" >&2; exit 1 ;;
	esac
done

# A stable code-signing identity keeps the Calendar permission working across
# rebuilds. Ad-hoc signatures (Xcode's default without a Developer account)
# change every build, which invalidates the macOS TCC grant. Moving an app from
# ad-hoc to the stable identity below therefore needs its stale, cdhash-pinned
# grant cleared once — after that the stable identity's grant persists.
#
# Inspect the app left behind by the PREVIOUS run, *before* xcodebuild
# overwrites it: that copy still carries the signature this script last applied.
# Checking after the build instead would see ad-hoc nearly every time, because
# xcodebuild re-signs that way whenever it relinks, and would then reset the
# permission on most rebuilds rather than once.
#
# If the previous build is gone (a wiped .build-xcode, a fresh worktree) there
# is nothing to infer from, so leave the permission alone; --reset-permissions
# clears it by hand if a stale grant does turn out to be in the way.
RESET_TCC=$FORCE_RESET_TCC
if [[ "$RESET_TCC" == false && -d "$BUILT_APP" ]] \
	&& codesign -dvv "$BUILT_APP" 2>&1 | grep -q "Signature=adhoc"; then
	RESET_TCC=true
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

echo "==> Ensuring a stable code-signing identity…"
SIGN_IDENTITY="$("$SCRIPT_DIR/create-signing-cert.sh")"

echo "==> Signing with \"$SIGN_IDENTITY\"…"
codesign --force --options runtime \
	--entitlements "$REPO_ROOT/App/Chronicle.entitlements" \
	--sign "$SIGN_IDENTITY" "$BUILT_APP"
codesign --verify --strict "$BUILT_APP"

if [[ "$RESET_TCC" == true ]]; then
	# Dev builds have their own bundle ID (see project.yml), so this only
	# affects dev builds — the installed Chronicle.app's grant is untouched.
	echo "==> Clearing the stale ad-hoc Calendar permission for $BUNDLE_ID…"
	echo "    Re-grant in the dev app: Refresh in the toolbar → Allow."
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
