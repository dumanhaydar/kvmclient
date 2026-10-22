#!/bin/zsh
# Builds the full (non-sandboxed) macOS app for GitHub releases: Developer ID signature,
# notarization and stapling, packaged as a DMG.
#
# One-time setup: a "Developer ID Application" certificate (Xcode › Settings › Accounts ›
# Manage Certificates) and notarization credentials stored in the keychain:
#   xcrun notarytool store-credentials kvmclient-notary --apple-id <apple id> --team-id 7UFR9PD47M
#
#   Distribution/release-mac-direct.sh
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(xcodebuild -project KVMUI.xcodeproj -scheme KVMUI -showBuildSettings 2>/dev/null \
  | awk '/ MARKETING_VERSION/ { print $3; exit }')
build=$(git rev-list --count HEAD)   # monotonic build number: commit count
out=build/direct
archive="$out/KVMClient.xcarchive"
dmg="$out/KVM-Client-$version.dmg"
rm -rf "$out"

echo "▸ Archiving $version ($build)"
xcodebuild archive -project KVMUI.xcodeproj -scheme KVMUI -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$archive" \
  CODE_SIGN_ENTITLEMENTS=Config/KVMUI-Direct.entitlements \
  CURRENT_PROJECT_VERSION=$build -allowProvisioningUpdates -quiet

echo "▸ Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
  -exportOptionsPlist Distribution/ExportOptions-DeveloperID.plist -allowProvisioningUpdates

echo "▸ Packaging"
staging="$out/dmg"
mkdir -p "$staging"
cp -R "$out/export/KVM Client.app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "KVM Client" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg" -quiet
codesign --sign "Developer ID Application" --timestamp "$dmg"

echo "▸ Notarizing"
xcrun notarytool submit "$dmg" --keychain-profile kvmclient-notary --wait
xcrun stapler staple "$dmg"

echo "✓ $dmg"
