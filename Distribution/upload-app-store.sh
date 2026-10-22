#!/bin/zsh
# Archives the iOS and macOS (sandboxed) builds and uploads them to App Store Connect.
# Uses the Apple ID signed in under Xcode › Settings › Accounts.
#
#   Distribution/upload-app-store.sh [ios|macos]     (both when omitted)
set -euo pipefail
cd "$(dirname "$0")/.."

build=$(git rev-list --count HEAD)   # monotonic build number: commit count
out=build/appstore
platforms=(${1:-ios macos})

for platform in $platforms; do
  case $platform in
    ios)   destination="generic/platform=iOS" ;;
    macos) destination="generic/platform=macOS" ;;
    *) echo "unknown platform: $platform" >&2; exit 1 ;;
  esac
  archive="$out/KVMClient-$platform.xcarchive"
  echo "▸ Archiving $platform (build $build)"
  xcodebuild archive -project KVMUI.xcodeproj -scheme KVMUI -configuration Release \
    -destination "$destination" -archivePath "$archive" \
    CURRENT_PROJECT_VERSION=$build -allowProvisioningUpdates -quiet
  echo "▸ Uploading $platform"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/$platform" \
    -exportOptionsPlist Distribution/ExportOptions-AppStore.plist -allowProvisioningUpdates
done
echo "✓ Uploaded. The builds appear in App Store Connect › TestFlight after processing."
