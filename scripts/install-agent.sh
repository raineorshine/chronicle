#!/usr/bin/env bash
#
# Builds chronicle-extract, installs it under Application Support, and loads a
# LaunchAgent that runs it once daily. Re-run to update the installed binary.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
SUPPORT_DIR="$HOME/Library/Application Support/Chronicle"
BIN_DIR="$SUPPORT_DIR/bin"
LOG_DIR="$SUPPORT_DIR/logs"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.chronicle.extract"
PLIST_DST="$AGENT_DIR/$LABEL.plist"

echo "==> Building chronicle-extract (Release)…"
xcodebuild build \
	-project "$REPO_ROOT/Chronicle.xcodeproj" \
	-scheme chronicle-extract \
	-configuration Release \
	-destination 'platform=macOS' \
	-derivedDataPath "$REPO_ROOT/.build-xcode" \
	>/dev/null

BUILT_BIN="$REPO_ROOT/.build-xcode/Build/Products/Release/chronicle-extract"
if [[ ! -x "$BUILT_BIN" ]]; then
	echo "error: built binary not found at $BUILT_BIN" >&2
	exit 1
fi

echo "==> Installing binary and directories…"
mkdir -p "$BIN_DIR" "$LOG_DIR" "$AGENT_DIR"

# Match the app's stable code-signing identity so the extractor's Calendar grant
# also survives rebuilds. If the previously installed binary is ad-hoc signed,
# clear its stale (hash-pinned) grant once.
DEST_BIN="$BIN_DIR/chronicle-extract"
RESET_TCC=false
if [[ -f "$DEST_BIN" ]] && codesign -dvv "$DEST_BIN" 2>&1 | grep -q "Signature=adhoc"; then
	RESET_TCC=true
fi

echo "==> Ensuring a stable code-signing identity…"
SIGN_IDENTITY="$("$SCRIPT_DIR/create-signing-cert.sh")"

cp -f "$BUILT_BIN" "$DEST_BIN"

echo "==> Signing with \"$SIGN_IDENTITY\"…"
codesign --force --options runtime \
	--entitlements "$REPO_ROOT/Extractor/Extractor.entitlements" \
	--sign "$SIGN_IDENTITY" "$DEST_BIN"
codesign --verify --strict "$DEST_BIN"

if [[ "$RESET_TCC" == true ]]; then
	echo "==> Clearing the stale ad-hoc Calendar permission (one-time)…"
	tccutil reset Calendar "$LABEL" >/dev/null 2>&1 || true
fi

echo "==> Writing LaunchAgent to $PLIST_DST…"
sed \
	-e "s#__EXTRACT_BIN__#$BIN_DIR/chronicle-extract#g" \
	-e "s#__LOG_DIR__#$LOG_DIR#g" \
	"$REPO_ROOT/launchd/$LABEL.plist" > "$PLIST_DST"

echo "==> (Re)loading agent…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo
echo "Installed. The extractor will run daily at 02:00 and once at login."
echo "It just ran once now (RunAtLoad); grant Calendar access when prompted."
echo "Logs: $LOG_DIR/extract.log"
echo "Config (edit the calendar allowlist here): $SUPPORT_DIR/config.json"
