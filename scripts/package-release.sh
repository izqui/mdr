#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MDR_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/mdr.app/Contents/Info.plist)"
if [ "${1:-v$MDR_VERSION}" != "v$MDR_VERSION" ]; then
  echo 'Release tag and app version must match.' >&2; exit 1
fi
codesign --verify --deep --strict dist/mdr.app
lipo dist/mdr.app/Contents/MacOS/mdr -verify_arch arm64 x86_64
mkdir -p dist/release work
MDR_PACKAGE_STAGE="$(mktemp -d "$PWD/work/release-stage.XXXXXX")"
trap 'rm -rf "$MDR_PACKAGE_STAGE"' EXIT
ditto dist/mdr.app "$MDR_PACKAGE_STAGE/mdr.app"
ln -s /Applications "$MDR_PACKAGE_STAGE/Applications"
cp docs/INSTALL.txt "$MDR_PACKAGE_STAGE/Read me.txt"
COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent dist/mdr.app "dist/release/mdr-$MDR_VERSION-macos-universal.zip"
hdiutil create -volname "mdr $MDR_VERSION" -srcfolder "$MDR_PACKAGE_STAGE" \
  -ov -format UDZO "dist/release/mdr-$MDR_VERSION-macos-universal.dmg"
COPYFILE_DISABLE=1 ditto -c -k --keepParent skills/mdr "dist/release/mdr-skill.zip"
(
  cd dist/release
  shasum -a 256 "mdr-$MDR_VERSION-macos-universal.zip" "mdr-$MDR_VERSION-macos-universal.dmg" mdr-skill.zip > SHA256SUMS
)
echo "Packaged mdr $MDR_VERSION in dist/release"
