#!/bin/zsh
# Build, notarize, package as dmg, and publish a GitHub release.
# Usage: ./release.sh 0.1.0 [notes.md]
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?version, e.g. 0.1.0}"
NOTES_FILE="${2:-}"

./build.sh

# Notarize when the app carries a Developer ID signature and notary
# credentials are stored (one-time: `xcrun notarytool store-credentials
# appletree-notary --key <AuthKey.p8> --key-id <id> --issuer <uuid>`).
# The app is stapled before packaging so it opens offline once copied out
# of the dmg; the dmg is then signed, notarized and stapled itself.
# (-dvv: plain -dv never prints the Authority lines.)
NOTARIZE=0
DEVID=$(codesign -dvv build/AppleTree.app 2>&1 | awk -F= '/^Authority=Developer ID Application/ && !n++ {print $2}')
if [[ -n "$DEVID" ]]; then
    NOTARIZE=1
    echo "==> Notarizing app"
    ZIP=$(mktemp -d)/AppleTree.zip
    ditto -c -k --keepParent build/AppleTree.app "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile appletree-notary --wait
    xcrun stapler staple build/AppleTree.app
    rm -f "$ZIP"
fi

STAGE=$(mktemp -d)
cp -R build/AppleTree.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "AppleTree.dmg"
hdiutil create -volname AppleTree -srcfolder "$STAGE" -ov -format UDZO -quiet AppleTree.dmg
rm -rf "$STAGE"

if (( NOTARIZE )); then
    echo "==> Notarizing dmg"
    codesign --force --timestamp --sign "$DEVID" AppleTree.dmg
    xcrun notarytool submit AppleTree.dmg --keychain-profile appletree-notary --wait
    xcrun stapler staple AppleTree.dmg
    spctl --assess --type open --context context:primary-signature -v AppleTree.dmg
    NOTES="Download AppleTree.dmg and drag it to Applications, then grant Full Disk Access when asked and relaunch."
else
    NOTES="Download AppleTree.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch."
fi
[[ -n "$NOTES_FILE" ]] && NOTES=$(<"$NOTES_FILE")

shasum -a 256 AppleTree.dmg > SHA256SUMS.txt
if gh release view "v$V" >/dev/null 2>&1; then
    # Re-running over an existing (e.g. draft) release replaces its files.
    gh release upload "v$V" AppleTree.dmg SHA256SUMS.txt --clobber
    gh release edit "v$V" --title "AppleTree $V" --notes "$NOTES" --draft=false --latest
else
    gh release create "v$V" AppleTree.dmg SHA256SUMS.txt \
        --title "AppleTree $V" \
        --notes "$NOTES"
fi
rm -f SHA256SUMS.txt
echo "==> released v$V"
