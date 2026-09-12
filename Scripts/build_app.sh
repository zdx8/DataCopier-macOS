#!/bin/bash
#
# 把 SwiftPM 产物组装成可双击运行的 macOS 应用包。
#
# 用法：./Scripts/build_app.sh [debug|release]
#
# 关于工具链：本机仅安装了 Command Line Tools 且未接受 Xcode 许可协议，
# 因此显式指定 DEVELOPER_DIR，避免 xcrun 因许可检查而拒绝工作。
# 关于 SDK：CLT 默认使用 MacOSX27.x，该 SDK 中 SwiftUI 的 @State 已改为外部宏，
# 而对应宏插件不在 CLT 工具链内（属于 Xcode 27 范畴），会导致 SwiftUI 代码编译失败。
# 因此优先选用 MacOSX26.5 SDK。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_NAME="DataCopier"
BUNDLE_ID="com.genge.datacopier"

CLT_ROOT="/Library/Developer/CommandLineTools"

if [[ -z "${DEVELOPER_DIR:-}" && -d "$CLT_ROOT" ]]; then
  export DEVELOPER_DIR="$CLT_ROOT"
fi

if [[ -z "${SDKROOT:-}" ]]; then
  for candidate in MacOSX26.5 MacOSX26 MacOSX15.4 MacOSX14.4; do
    if [[ -d "${DEVELOPER_DIR:-}/SDKs/$candidate.sdk" ]]; then
      export SDKROOT="${DEVELOPER_DIR}/SDKs/$candidate.sdk"
      break
    fi
  done
fi

echo "==> 工具链"
echo "    DEVELOPER_DIR = ${DEVELOPER_DIR:-<系统默认>}"
echo "    SDKROOT       = ${SDKROOT:-<系统默认>}"

echo "==> 构建 ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --disable-sandbox --package-path "$ROOT"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path --package-path "$ROOT")"
EXECUTABLE="$BIN_PATH/$APP_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "错误：未找到可执行文件 $EXECUTABLE" >&2
  exit 1
fi

APP_DIR="$ROOT/dist/$APP_NAME.app"
echo "==> 组装应用包"
# 采用覆盖写入而非先删后建：既避免了批量删除操作，也保证签名流程不会因中间态失败。
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# 应用图标：源图与 icns 预先制作好放在 Scripts/assets/，
# 这里只做拷贝，避免每次打包都跑一遍 iconutil。
cp "$ROOT/Scripts/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DataCopier</string>
    <key>CFBundleDisplayName</key>
    <string>数据拷贝</string>
    <key>CFBundleIdentifier</key>
    <string>com.genge.datacopier</string>
    <key>CFBundleExecutable</key>
    <string>DataCopier</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>数据拷贝 DataCopier</string>
</dict>
</plist>
PLIST

echo "==> 临时签名"
if codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1; then
  echo "    已使用临时签名"
else
  echo "    提示：临时签名失败，首次打开可能需要在「系统设置 → 隐私与安全性」中放行。"
fi

cat > "$APP_DIR/Contents/Resources/README.txt" <<'TXT'
数据拷贝 DataCopier
===================

功能
  · 文件拷贝：并行分块搬运，中断不产生残缺文件（先写临时文件再原子重命名）
  · 文件校验：边拷贝边计算哈希，可选拷后复核；支持导出/复核 checksums 清单
  · 媒体归档：按拍摄时间重命名并分类归档照片与视频，适合相机卡导入
  · 视频转码：独立转码任务（扫描来源视频直接转码输出），拷贝任务也可在配置中开启拷后转码
  · 统计报告：吞吐、耗时、成功/失败/不一致明细、转码前后体积，可导出 Markdown / CSV / JSON / PDF
  · 自动 PDF 报告：任务完成后自动在报告目录生成一份 PDF 报表

新建任务
  · 新建时先选择类型：拷贝任务 或 转码任务，随后进入各自的配置表单
  · 两类任务共用同一份任务列表，列表中以图标区分

拷贝预设
  · 文件拷贝       完整拷贝来源目录，保留原始目录层级，全部文件类型，文件名不改动，适合整盘项目迁移
  · 媒体拷贝        照片视频，适合相机卡导入素材整理，支持主流照片视频格式

界面主题
  「设置 → 外观」中可在跟随系统 / 浅色 / 深色之间切换。

校验算法
  xxHash64（快速初筛）、SHA-256、MD5（强校验，生成 shasum 兼容清单）

转码预设
  · 原样重封装       只换容器为 MP4，码流直通，体积与画质不变
  · H.265 压缩 1080p 体积约为原片 20–35%，适合长期存档
  · H.264 兼容 1080p 兼容性最好，适合交付与剪辑
  · H.264 小体积 720p 适合网页、即时通讯与移动端分享
  · H.265 保持分辨率 不缩放，仅降码率，适合 4K 及以上素材
  · ProRes 422       剪辑友好的中间格式
  · 仅提取音频       输出 M4A
  · 自定义参数       自选编码、分辨率上限、码率、音轨与容器

转码安全性
  · 输出与拷贝结果同目录、文件名带预设后缀，不覆盖原始素材
  · 压缩类预设若输出未变小，自动丢弃输出并保留原文件
  · 转码成功后删除原始拷贝为可选开关，默认关闭
  · 任务中途取消会终止 FFmpeg 进程并清理半成品文件

使用
  打开应用 → 「新建拷贝任务」→ 选择来源与目标 → 配置选项与转码预设 → 开始

命令行复核（SHA-256 模式下）
  cd <目标目录> && shasum -a 256 -c "<任务名>.checksums.txt"

依赖
  转码功能需要 FFmpeg（含 ffprobe）。应用会依次查找随包资源、/opt/homebrew/bin、
  /usr/local/bin、/opt/local/bin、/usr/bin，也可在「设置」中手动指定路径。
TXT

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
