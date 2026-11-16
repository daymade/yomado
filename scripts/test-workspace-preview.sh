#!/bin/bash
set -euo pipefail

ym_preview_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_preview_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-preview-tests.XXXXXX")"
trap 'rm -rf "$ym_preview_stage"' EXIT
ym_preview_developer="${YOMADO_DEVELOPER_DIR:-$(xcode-select -p)}"
ym_preview_clang="$(DEVELOPER_DIR="$ym_preview_developer" /usr/bin/xcrun --find clang)"
ym_preview_sdk="$(DEVELOPER_DIR="$ym_preview_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

"$ym_preview_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_preview_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_preview_root"=. -fmacro-prefix-map="$ym_preview_root"=. \
  -I "$ym_preview_root/app" -I "$ym_preview_root/bridge" \
  "$ym_preview_root/tests/WorkspacePreviewTests.m" "$ym_preview_root/app/WorkspacePreview.m" \
  "$ym_preview_root/bridge/VDVirtualDisplay.m" \
  -framework AppKit -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
  -framework IOSurface -framework QuartzCore -framework ScreenCaptureKit \
  -o "$ym_preview_stage/WorkspacePreviewTests"
"$ym_preview_stage/WorkspacePreviewTests"
