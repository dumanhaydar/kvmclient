#!/bin/zsh
# Stages the App Store screenshots in the iOS simulators with the demo device.
# Output: build/shots/<language>/*.png (Mac screenshots are taken separately, see AppStore.md).
#
#   Distribution/take-screenshots.sh [en fr]
set -euo pipefail
cd "$(dirname "$0")/.."

iphone="iPhone 17 Pro"   # 6.3", the size App Store Connect asks for
ipad="iPad Pro 13-inch (M5)"
app="build/sim/Build/Products/Debug-iphonesimulator/KVM Client.app"
if (( $# )); then languages=("$@"); else languages=(en fr); fi

xcodebuild -project KVMUI.xcodeproj -scheme KVMUI -configuration Debug -derivedDataPath build/sim \
  -destination "platform=iOS Simulator,name=$iphone" CODE_SIGNING_ALLOWED=NO build -quiet

shoot() {  # device name, output name, launch arguments...
  local device=$1 name=$2; shift 2
  local region=$([[ $lang == fr ]] && echo fr_BE || echo en_US)
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
    --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$device" "$app"
  xcrun simctl terminate "$device" com.aroneus.kvmclient 2>/dev/null || true
  xcrun simctl launch "$device" com.aroneus.kvmclient -screenshots "$@" \
    -AppleLanguages "($lang)" -AppleLocale $region >/dev/null
  sleep 7
  xcrun simctl io "$device" screenshot "build/shots/$lang/$name.png" >/dev/null 2>&1
  echo "✓ $lang/$name"
}

for lang in $languages; do
  mkdir -p build/shots/$lang
  shoot "$iphone" iphone-1-screen   -openDemo -orientation landscape
  shoot "$iphone" iphone-2-keyboard -openDemo -orientation landscape -keyboard -demoCommand neofetch
  shoot "$iphone" iphone-3-devices  -orientation portrait
  # iPad stays in portrait: simctl cannot rotate it and iPad windows ignore orientation requests.
  shoot "$ipad"   ipad-1-devices    -openDemo -sidebar
  shoot "$ipad"   ipad-2-keyboard   -openDemo -keyboard -demoCommand neofetch
done
