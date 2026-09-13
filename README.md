# DataCopier-macOS

macOS 原生数据拷贝工具，使用 **SwiftUI** 构建（SwiftPM 手工打包，无 Xcode 工程文件依赖）。

不同于「复制粘贴」的是，DataCopier 面向**大批量、有校验需求**的文件搬运场景：逐文件记录处理结果、逐文件校验哈希，并自动生成统计报告。

## 功能

- **文件拷贝**——完整拷贝来源目录结构，适合整盘项目迁移；拷贝后逐文件 SHA-256 校验，确保数据无损。
- **媒体拷贝**——只拷贝照片和视频，按设备 / 年月日分类归档，支持按拍摄时间重命名（含自定义前缀 + 时间戳）；照片视频分别统计。
- **视频转码**——独立任务类型，基于 ffmpeg 重编码视频（可选预设、CRF 等），支持查看硬件编码器能力；产物大于源文件时自动丢弃保护。
- **PDF 报告**——任务完成自动生成 PDF 统计报告（环形图 / 明细 / 校验值），也可导出 Markdown / CSV。
- **USB 自动感知**——插入相机卡、U 盘等移动设备时自动弹出新建拷贝任务并预填来源（可在设置中关闭）。
- **菜单栏常驻**——关闭窗口可最小化到菜单栏，随时唤回。
- **外观**——浅色 / 深色 / 跟随系统，工具栏一键切换。

## 下载

| 机型 | 安装包 |
| --- | --- |
| Apple Silicon（M 系列） | [DataCopier-v1.0.1-arm64.dmg](https://github.com/zdx8/DataCopier-macOS/releases/download/v1.0.1/DataCopier-v1.0.1-arm64.dmg) |
| Intel（x86_64） | [DataCopier-v1.0.1-x86_64.dmg](https://github.com/zdx8/DataCopier-macOS/releases/download/v1.0.1/DataCopier-v1.0.1-x86_64.dmg) |

均为临时签名的未公证版本，首次打开若被 Gatekeeper 拦截，请在「系统设置 → 隐私与安全性」中放行。
全部版本见 [Releases](https://github.com/zdx8/DataCopier-macOS/releases)。

## 环境要求

- macOS 14+
- Swift 6（Command Line Tools 或完整 Xcode）
- 转码功能需要 **ffmpeg / ffprobe**（不随应用分发）：

  ```bash
  brew install ffmpeg
  ```

  应用会自动在常见路径（`/opt/homebrew/bin` 等）查找，也可在「设置 → 运行环境」中手动指定。

## 构建

```bash
# 运行自检（414 项断言，覆盖拷贝 / 校验 / 归档 / 转码 / 报告渲染 / 序列化往返）
./Scripts/run_selfcheck.sh

# 打包 dist/DataCopier.app
./Scripts/build_app.sh release

# 打成 DMG 安装包（版本号取自 build_app.sh 的 APP_VERSION）
./Scripts/make_dmg.sh 1.0.1 arm64
./Scripts/make_dmg.sh 1.0.1 x86_64
```

> 脚本使用固定的 `DEVELOPER_DIR` / `SDKROOT`，在仅有 Command Line Tools 的机器上即可构建，无需完整 Xcode。

## 目录结构

```
Sources/DataCopier/
  App/          # 应用入口、菜单栏常驻、关闭行为
  ViewModels/   # AppModel：任务状态、进度、持久化
  Views/        # 任务列表 / 详情 / 新建任务 / 设置等界面
  Engine/       # 拷贝、校验、媒体归档、转码、PDF 报告渲染
  Models/       # 数据模型（宽容解码，兼容旧配置文件）
  Support/      # 文件面板等工具
Scripts/        # 构建、打包与自检脚本、图标素材
website/        # 官网静态页（发布内容同步至 gh-pages 分支）
```

## 许可证

[MIT](LICENSE) © 2026 DataCopier-macOS Contributors

转码能力依赖系统安装的 [FFmpeg](https://ffmpeg.org)，本项目不包含、不分发 FFmpeg 二进制。
