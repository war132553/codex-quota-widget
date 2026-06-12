#!/bin/zsh
set -euo pipefail

AGENT_ID="com.wendy.codex-quota-widget"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
APP_DIR="$HOME/Applications/Codex Quota Widget.app"

launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App not found: $APP_DIR"
  echo "Run scripts/install_launch_agent.sh first."
  exit 1
fi

pkill -f "$APP_DIR/Contents/MacOS/CodexQuotaWidget" >/dev/null 2>&1 || true
open "$APP_DIR"

echo "Restarted app manually. LaunchAgent autostart remains disabled."
