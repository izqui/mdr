#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm run build:web
swift build
mkdir -p work/demo docs/images
swift scripts/make-icon.swift work/demo/MDRIcon.iconset work/demo/MDRIcon.icon
cp work/demo/MDRIcon.iconset/icon_256x256@2x.png docs/images/icon.png
MDR_DEMO_DIR="$PWD/work/demo" .build/debug/mdr
