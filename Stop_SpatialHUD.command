#!/bin/bash
pkill -f SpatialHUD
rm -f /tmp/com.swikar.spatialhud.lock
osascript -e 'display notification "SpatialHUD cleanly stopped." with title "CortexGlass"' 2>/dev/null
osascript -e 'tell application "Terminal" to close (every window whose name contains "Stop_SpatialHUD")' &>/dev/null &
exit 0
