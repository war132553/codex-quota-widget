#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_ID="com.wendy.codex-quota-widget"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
APP_HOME="$HOME/.codex-quota-widget"
APP_NAME="Codex Quota Widget"
APP_DIR="$HOME/Applications/$APP_NAME.app"
LEGACY_INSTALL_BIN="$APP_HOME/bin/CodexQuotaWidget"

"$SCRIPT_DIR/build_app.sh"
mkdir -p "$APP_HOME"

launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$LEGACY_INSTALL_BIN"

echo "Installed app at $APP_DIR"
echo "Removed LaunchAgent autostart. Start or quit the app manually from Finder or the app panel."
