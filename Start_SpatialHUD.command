#!/bin/bash
pkill -f SpatialHUD 2>/dev/null
rm -f /tmp/com.swikar.spatialhud.lock 2>/dev/null
open -a /Applications/SpatialHUD.app
osascript -e 'tell application "Terminal" to close (every window whose name contains "Start_SpatialHUD")' &>/dev/null &
exit 0
