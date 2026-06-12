#!/bin/zsh
set -euo pipefail

AGENT_ID="com.wendy.codex-quota-widget"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
LEGACY_INSTALL_BIN="$HOME/.codex-quota-widget/bin/CodexQuotaWidget"
APP_DIR="$HOME/Applications/Codex Quota Widget.app"

launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$LEGACY_INSTALL_BIN"

echo "Removed $PLIST_PATH"
echo "Removed legacy helper binary at $LEGACY_INSTALL_BIN"
echo "Kept app at $APP_DIR"
