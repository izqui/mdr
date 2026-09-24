#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm run build:web
swift build -c release --arch arm64 --arch x86_64
MDR_BUILD_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
mkdir -p "$PWD/work" "$PWD/dist"
MDR_STAGE_PATH="$(mktemp -d "$PWD/work/build-stage.XXXXXX")"
MDR_APP_PATH="$MDR_STAGE_PATH/mdr.app"
mkdir -p "$MDR_APP_PATH/Contents/MacOS" "$MDR_APP_PATH/Contents/Resources"
cp "$MDR_BUILD_PATH/mdr" "$MDR_APP_PATH/Contents/MacOS/mdr"
ditto "$MDR_BUILD_PATH/mdr_MDRApp.bundle" "$MDR_APP_PATH/Contents/Resources/mdr_MDRApp.bundle"
cp scripts/Info.plist "$MDR_APP_PATH/Contents/Info.plist"
cp bin/mdr "$MDR_APP_PATH/Contents/Resources/mdr"
chmod +x "$MDR_APP_PATH/Contents/Resources/mdr"
cp LICENSE "$MDR_APP_PATH/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$MDR_STAGE_PATH/MDRIcon.iconset" "$MDR_STAGE_PATH/MDRIcon.icon"
xcrun actool "$MDR_STAGE_PATH/MDRIcon.icon" \
  --compile "$MDR_APP_PATH/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon MDRIcon --output-format human-readable-text \
  --output-partial-info-plist "$MDR_STAGE_PATH/icon-info.plist"
# Keep every Retina size for macOS versions using the flattened fallback.
iconutil -c icns "$MDR_STAGE_PATH/MDRIcon.iconset" -o "$MDR_APP_PATH/Contents/Resources/MDRIcon.icns"
codesign --force --deep --sign - "$MDR_APP_PATH"
codesign --verify --deep --strict "$MDR_APP_PATH"
lipo "$MDR_APP_PATH/Contents/MacOS/mdr" -verify_arch arm64 x86_64
python3 - "$MDR_APP_PATH" "$PWD/dist/mdr.app" "$MDR_STAGE_PATH/previous.app" <<'PY'
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
echo "Built $PWD/dist/mdr.app"
