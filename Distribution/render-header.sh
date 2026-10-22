#!/bin/zsh
# Renders the App Store product page header (no text, so one image serves every language):
# the demo desktop, drawn at full resolution by the app's own DemoScreen, on the brand background.
# Output: Distribution/Header/header-5244x2950.png and header-3840x1646.png
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
{
  sed -n '/^\/\/ MARK: - Desktop model/,$p' KVMUI/Drivers/Demo/DemoDriver.swift
  # DemoScreen draws at 1920×1080; scale its context up instead of upscaling pixels.
  sed -e 's/guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),/guard let context = CGContext(data: nil, width: Int(size.width * renderScale), height: Int(size.height * renderScale),/' \
      -e 's/context.translateBy(x: 0, y: size.height)/context.translateBy(x: 0, y: size.height * renderScale); context.scaleBy(x: renderScale, y: renderScale)/' \
      KVMUI/Drivers/Demo/DemoScreen.swift
  cat Distribution/header-main.swift
} > "$work/header.swift"
swiftc -parse-as-library -O "$work/header.swift" -o "$work/header"
mkdir -p Distribution/Header
"$work/header" 5244 2950 Distribution/Header/header-5244x2950.png
"$work/header" 3840 1646 Distribution/Header/header-3840x1646.png
rm -rf "$work"
