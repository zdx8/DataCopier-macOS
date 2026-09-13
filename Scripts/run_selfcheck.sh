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

DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export DEVELOPER_DIR SDKROOT

echo "==> 编译自检程序"
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
