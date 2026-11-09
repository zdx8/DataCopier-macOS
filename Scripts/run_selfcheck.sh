#!/bin/bash
#
# 编译并运行引擎自检。不依赖 Xcode 工程，直接以源码方式编译核心模块。
#
# 用法：./Scripts/run_selfcheck.sh [组号…]
#   不带参数运行全部 6 组；带组号（1–6）则只跑指定分组。
#   改动通常只影响其中一组，按组运行可以把验证从十几分钟压到一两分钟。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Sources/DataCopier"
OUT="${TMPDIR:-/tmp}/datacopier-selfcheck"

XCODE_ROOT="$(xcode-select -p 2>/dev/null || true)"
CLT_ROOT="/Library/Developer/CommandLineTools"
SWIFTUI_MACROS="$XCODE_ROOT/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -n "$XCODE_ROOT" && -f "$SWIFTUI_MACROS" ]]; then
    export DEVELOPER_DIR="$XCODE_ROOT"
  elif [[ -d "$CLT_ROOT" ]]; then
    export DEVELOPER_DIR="$CLT_ROOT"
  fi
fi

if [[ -z "${SDKROOT:-}" ]]; then
  # 与 build_app.sh 同一规则：CLT 的默认 SDK 指向 27.x，缺 SwiftUI 宏插件，
  # 回退到 CLT 时必须优先选仍可用的旧 SDK。
  if [[ "${DEVELOPER_DIR:-}" == "$CLT_ROOT" ]]; then
    for candidate in MacOSX26.5 MacOSX26 MacOSX15.4 MacOSX14.4; do
      if [[ -d "$CLT_ROOT/SDKs/$candidate.sdk" ]]; then
        SDKROOT="$CLT_ROOT/SDKs/$candidate.sdk"
        break
      fi
    done
  fi
  if [[ -z "${SDKROOT:-}" ]]; then
    SDKROOT="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  fi
fi
if [[ -z "${SDKROOT:-}" || ! -d "$SDKROOT" ]]; then
  echo "错误：未能找到与当前 Swift 编译器匹配的 macOS SDK" >&2
  exit 1
fi
export DEVELOPER_DIR SDKROOT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/datacopier-clang-module-cache}"

echo "==> 编译自检程序"
echo "    DEVELOPER_DIR = ${DEVELOPER_DIR:-<系统默认>}"
echo "    SDKROOT = $SDKROOT"
mkdir -p "$OUT"

SOURCES=(
  "$SRC/Models/Models.swift"
  "$SRC/Engine/Cancellation.swift"
  "$SRC/Engine/Hashing.swift"
  "$SRC/Engine/SpeedMeter.swift"
  "$SRC/Engine/FilePlanner.swift"
  "$SRC/Engine/MediaMetadata.swift"
  "$SRC/Engine/MediaArchiver.swift"
  "$SRC/Engine/MetadataCopier.swift"
  "$SRC/Engine/FileCopier.swift"
  "$SRC/Engine/Verifier.swift"
  "$SRC/Engine/ChecksumManifest.swift"
  "$SRC/Engine/ReportExporter.swift"
  "$SRC/Engine/PDFReportRenderer.swift"
  "$SRC/Engine/TaskRunner.swift"
  "$SRC/Engine/TranscodePreset.swift"
  "$SRC/Engine/FFmpegRunner.swift"
  "$SRC/Engine/TranscodeService.swift"
  "$SRC/Support/Format.swift"
  "$SRC/Support/CorruptFileBackup.swift"
  "$SRC/Support/USBDevice.swift"
  "$SRC/Support/USBDeviceScanner.swift"
  "$ROOT/Scripts/selfcheck/main.swift"
)

swiftc -O -o "$OUT/selfcheck" "${SOURCES[@]}"

echo "==> 运行自检"
"$OUT/selfcheck" "$@"
