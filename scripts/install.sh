#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MDR_INSTALL_DIR="${MDR_APPLICATIONS_DIR:-$HOME/Applications}"
MDR_COMMAND_DIR="${MDR_BIN_DIR:-$HOME/.local/bin}"
MDR_INSTALL_APP="$MDR_INSTALL_DIR/mdr.app"
if [ ! -d dist/mdr.app ]; then echo 'Run npm run build first.' >&2; exit 1; fi
codesign --verify --deep --strict dist/mdr.app
if [ -e "$MDR_INSTALL_APP" ] || [ -L "$MDR_INSTALL_APP" ]; then
  if [ -L "$MDR_INSTALL_APP" ] || [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$MDR_INSTALL_APP/Contents/Info.plist" 2>/dev/null || true)" != "app.mdr.reader" ]; then
    echo "Refusing to replace a different app at $MDR_INSTALL_APP" >&2
    exit 1
  fi
fi
mkdir -p "$MDR_INSTALL_DIR"
MDR_INSTALL_STAGE="$(mktemp -d "$MDR_INSTALL_DIR/.mdr-install.XXXXXX")"
trap 'rm -rf "$MDR_INSTALL_STAGE"' EXIT
ditto dist/mdr.app "$MDR_INSTALL_STAGE/mdr.app"
codesign --verify --deep --strict "$MDR_INSTALL_STAGE/mdr.app"
# Rename whole bundles so a running app can continue reading its old files.
python3 - "$MDR_INSTALL_STAGE/mdr.app" "$MDR_INSTALL_APP" "$MDR_INSTALL_STAGE/previous.app" <<'PY'
import os, sys
new, destination, previous = sys.argv[1:]
existed = os.path.exists(destination)
if existed:
    os.rename(destination, previous)
try:
    os.rename(new, destination)
except Exception:
    if existed:
        os.rename(previous, destination)
    raise
PY
# Keep the previous bundle for a running reader until it is closed.
if [ -d "$MDR_INSTALL_STAGE/previous.app" ]; then
  mkdir -p work/previous-installations
  mv "$MDR_INSTALL_STAGE/previous.app" "work/previous-installations/$(basename "$MDR_INSTALL_STAGE").app"
fi
"$MDR_INSTALL_APP/Contents/MacOS/mdr" --install-cli "$MDR_COMMAND_DIR"
echo "Installed $MDR_INSTALL_APP. Quit and reopen mdr to use the new version."
