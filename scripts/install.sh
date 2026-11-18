#!/usr/bin/env bash
# Builds Jarvis and installs the app, the hook binary and the Claude Code hook entries.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app_dst="$HOME/Applications/Jarvis.app"
hook_dir="$HOME/.jarvis/bin"
hook_dst="$hook_dir/jarvis-hook"
settings="$HOME/.claude/settings.json"

# 1. Build
scripts/build-app.sh

# 2. Install the hook binary
install -d -m 700 "$hook_dir"
install -m 755 build/jarvis-hook "$hook_dst"

# 3. Merge hook entries into the global settings (prints the backup path). Done before the running
#    app is touched: if the merge fails, the installed Jarvis keeps working.
backup_line="$("$hook_dst" install-settings --hook-binary "$hook_dst" "$settings")"

# 4. Quit a running Jarvis (wait up to 5 s)
pkill -x JarvisApp || true
for _ in $(seq 1 50); do
  pgrep -x JarvisApp >/dev/null || break
  sleep 0.1
done
if pgrep -x JarvisApp >/dev/null; then
  echo "error: JarvisApp is still running after 5 s; aborting" >&2
  exit 1
fi

# 5. Install the app bundle
mkdir -p "$HOME/Applications"
rm -rf "$app_dst"
cp -R build/Jarvis.app "$app_dst"

# 6. Launch
open "$app_dst"

# 7. Summary
echo "Jarvis installed."
echo "  App:    $app_dst"
echo "  Hook:   $hook_dst"
echo "  Backup: $backup_line"
echo "Requires macOS Dictation ON with Turkish (System Settings → Keyboard → Dictation)"
