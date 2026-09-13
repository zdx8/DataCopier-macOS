#!/bin/bash
#
# 把应用包打成可分发的 DMG 安装包。
#
# 用法：./Scripts/make_dmg.sh [版本号] [native|arm64|x86_64|universal]
#   版本号缺省时从 build_app.sh 的 APP_VERSION 读取，避免两处维护。
#   产物：dist/DataCopier-v<版本号>-<架构>.dmg
#
# 说明：镜像内只放 DataCopier.app（与历史发布保持一致），卷名固定 DataCopier，
#       压缩格式 UDZO。发布双架构时依次执行：
#         ./Scripts/make_dmg.sh 1.0.1 arm64
#         ./Scripts/make_dmg.sh 1.0.1 x86_64
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${2:-native}"

DEFAULT_VERSION="$(sed -n 's/^APP_VERSION="\(.*\)"/\1/p' "$ROOT/Scripts/build_app.sh" | head -1)"
VERSION="${1:-$DEFAULT_VERSION}"

if [[ -z "$VERSION" ]]; then
  echo "错误：未能确定版本号，请显式传入，例如 ./Scripts/make_dmg.sh 1.0.1 arm64" >&2
  exit 1
fi

# native 下用机器架构标注文件名，与历史产物命名（-arm64 / -x86_64）一致。
if [[ "$ARCH" == "native" ]]; then
  LABEL="$(uname -m)"
else
  LABEL="$ARCH"
fi

APP_DIR="$ROOT/dist/DataCopier.app"
OUT="$ROOT/dist/DataCopier-v${VERSION}-${LABEL}.dmg"

echo "==> 构建 release 应用包（架构 $ARCH）"
"$ROOT/Scripts/build_app.sh" release "$ARCH"

if [[ ! -d "$APP_DIR" ]]; then
  echo "错误：未找到 $APP_DIR" >&2
  exit 1
fi

echo "==> 打包 DMG"
# 同名旧产物先移除：hdiutil 覆盖已存在镜像时行为不直观，显式清理更可控。
rm -f "$OUT"
hdiutil create -volname "DataCopier" -srcfolder "$APP_DIR" -ov -format UDZO "$OUT" >/dev/null

echo "==> 完成：$OUT"
echo "    大小：$(du -h "$OUT" | cut -f1)"
echo "    卷内：$(hdiutil imageinfo "$OUT" 2>/dev/null | awk '/Format Description/{getline; print}' | tr -d ' ')"
