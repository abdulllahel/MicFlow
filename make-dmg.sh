#!/bin/bash
# Builds the app, then packs it with the BlackHole installers and instructions into
# dist/MicFlow <version>.dmg for sharing. Needs the BlackHole installers that
# `brew install blackhole-2ch blackhole-16ch` left in Homebrew's Caskroom.
set -euo pipefail
cd "$(dirname "$0")"

# The public download is always the visitor edition: no Admin/ code in it.
MICFLOW_EDITION=visitor ./build.sh
if strings build/MicFlow.app/Contents/MacOS/MicFlow | grep -q "ContentAdminView\|ContentPublisher\|ADMIN BUILD"; then
    echo "Stopped: admin code found in the build." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
ditto "build/MicFlow.app" "$STAGE/MicFlow.app"
ln -s /Applications "$STAGE/Applications"
cp "Packaging/Read Me First.txt" "$STAGE/"
# The BlackHole sound helpers are no longer in the disk image: MicFlow downloads them when the
# person turns on mic or speaker boost (see Sources/SoundHelperInstaller.swift).
# "Start Here" opens the install guide on the website, which the first-launch warning needs.
cat > "$STAGE/Start Here - Install Guide.webloc" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>URL</key><string>https://micflow.abdullahel.com/guide.html</string></dict></plist>
XML

DMG="dist/MicFlow $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "MicFlow" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Created $DMG"
