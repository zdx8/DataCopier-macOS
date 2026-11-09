# DataCopier 交接文档

> 更新：2026-11-09（v1.1.0：修复批次归档 + bencho 视觉系统重构）

## 1. 一句话结论

DataCopier（显示名「数据拷贝」）是一个面向「大批量、有校验需求」文件搬运的 macOS 原生工具：逐文件拷贝 + SHA-256 校验 + 媒体按拍摄时间归档 + FFmpeg 转码 + PDF/Markdown/CSV/JSON 报告。当前版本 **v1.1.0**，界面按 [bencho](https://github.com/cabralorenzo/bencho)（MIT）的设计令牌重构为原生 SwiftUI 实现，状态为**可交付**。

仓库根目录即项目根（`Package.swift` 与 `dist/` 同级，不存在嵌套的 `DataCopier/DataCopier`）。

## 2. 交付物与位置

| 交付物 | 路径 | 版本 | 校验 |
|---|---|---|---|
| Apple Silicon 安装包 | `dist/DataCopier-v1.1.0-arm64.dmg` | 1.1.0 | 3,509,703 B，SHA-256 `d21886ed44d5fab511ccb1aa911a70550952a79714fcb4da74e1c236014fddc0` |
| Intel 安装包 | `dist/DataCopier-v1.1.0-x86_64.dmg` | 1.1.0 | 3,603,718 B，SHA-256 `4069bc3e5f9d540e674d3744b81b6157db89dbae01c0d484b2403075db3023ad` |
| 应用包 | `dist/DataCopier.app` | `CFBundleShortVersionString` = 1.1.0 | 6.2 MB，ad-hoc 签名，arm64 |
| 源码 | `main` 分支 | — | `git log -1` |
| 历史版本 | `dist/DataCopier-v1.0.0-*.dmg`、`v1.0.1-*.dmg` | 1.0.0 / 1.0.1 | 保留备查 |

远程：GitHub `zdx8/DataCopier-macOS`（公开）；另有私有镜像，地址不入库。

**发布状态**：v1.1.0 **尚未发布**。README 与 `website/index.html` 已指向 v1.1.0 的 Release 链接，推送前必须先建 tag 与 Release，否则下载链接 404。

## 3. 怎么跑起来

```bash
cd ~/AiWork/SoftwareDevelopment/DataCopier

./Scripts/run_selfcheck.sh              # 引擎自检：433 项
./Scripts/build_app.sh release          # 组装 dist/DataCopier.app
./Scripts/make_dmg.sh 1.1.0 arm64       # 打 DMG
./Scripts/make_dmg.sh 1.1.0 x86_64
open dist/DataCopier.app
```

工具链（两个脚本都会自动探测，无需手工设环境变量）：

1. 若 `xcode-select -p` 指向的 Xcode 内含 `libSwiftUIMacros.dylib`，用 Xcode 及其 SDK（27.x 亦可）。
2. 否则回退 Command Line Tools，并**优先选 26.5 / 26 / 15.4 / 14.4 的 SDK**——CLT 的默认 `MacOSX.sdk` 指向 27.x，该 SDK 把 SwiftUI `@State` 改成外部宏而 CLT 不含宏插件，直接用会编译失败。
3. 找不到可用 SDK 时脚本以退出码 1 中止，不会产出半成品。

前置条件：转码需系统装有 `ffmpeg` / `ffprobe`（应用查 `/opt/homebrew/bin`、`/usr/local/bin`、`/opt/local/bin`、`/usr/bin`，也可在「设置 → 运行环境」指定）；不装只影响转码。

## 4. 架构与关键设计

```
DataCopierApp(@main, @StateObject AppModel)
├─ App/            AppDelegate · MenuBarController · MainWindowCloseDelegate
├─ ViewModels/     AppModel：任务状态/进度/持久化/导出/USB 监听
├─ DesignSystem/   Bencho：色板/圆角/字阶/动效 + 原生组件
│   ├─ BenchoPanel / BenchoSection / BenchoForm        纸面容器
│   ├─ BenchoButtonStyle（slab/wash/quiet/destructive） 胶囊按钮
│   ├─ BenchoSegmented / BenchoToggleStyle / BenchoTextFieldStyle
│   ├─ RollingNumber（逐位滚动数字）/ BenchoMeter（胶囊进度条）
│   └─ SlideToConfirm（滑块确认）/ BenchoToast（提示条）
├─ Views/          ContentView → TaskList + TaskDetail；NewTaskSheet / Settings
├─ Engine/         无 UI 依赖，自检主要覆盖区
│   ├─ FilePlanner → TaskRunner(并发编排) → FileCopier(原子落盘) → Verifier(复核)
│   ├─ MediaMetadata / MediaArchiver   拍摄时间五级回退、七档归档
│   ├─ TranscodeService / FFmpegRunner 能力探测、转码、产物复核
│   └─ PDFReportRenderer / ReportExporter
├─ Models/         宽容解码（逐字段 decodeIfPresent）
└─ Support/        FilePanels · Format · USBDevice · CorruptFileBackup
```

规模实测：`Sources/` 36 个 Swift 文件；`Scripts/selfcheck/main.swift` 2,915 行。

关键决策：

- **零第三方依赖 + SwiftPM 手工拼 .app** → 构建可复现，不需要 Xcode 工程 → 代价是 Info.plist、图标、签名手写，`-parse-as-library` 使本包不能被其它包消费 → 若上架 App Store 或需要 Sparkle 更新，应改 Xcode 工程。
- **临时文件 + `fsync` + `rename(2)` 原子替换**（v1.1.0 起临时名带 UUID 且 `O_EXCL` 创建）→ 并发任务不会争用同一临时路径，目标目录不会出现「看着完整、实际残缺」的文件。
- **拷贝与转码两阶段串行** → 各自独占磁盘与编码器，避免转码读半成品 → 代价是总耗时不可重叠。
- **bencho 令牌在 SwiftUI 侧重实现，而不是嵌 WebView** → 原生交互、无 Web 运行时、包体不膨胀 → 代价是 bencho 的 47 个 React block 只能挑设计语言与少数交互（滚动数字、滑块确认、toast）移植，动画细节不可能逐帧一致。
- **自检用 `swiftc` 直编源码** → 无需 GUI 即可跑引擎断言 → 代价是 `SOURCES` 手写、覆盖面不含 App/Views，且「自检绿」不等于 `swift build` 能过。

## 5. 已完成 / 未完成 / 已知问题

**v1.1.0 相对 v1.0.1 的实质修复**

| 类别 | 内容 |
|---|---|
| 安全 | 归档目录名走 `MediaArchiver.sanitize`，并拒绝 `.` / `..`——修掉可路径逃逸写出目标目录的问题 |
| 并发 | 拷贝临时文件改 `.<UUID>.datacopier-tmp` + `O_EXCL` + `rename(2)`；来源枚举按真实路径去重 |
| 线程安全 | `Format` 的 `ByteCountFormatter` / `DateFormatter` 加锁，后台 PDF 渲染不再与主线程争用 |
| 数据正确 | 批量删除一次性提交（原先逐条删除会把多选收缩成一项，只删掉第一个） |
| 设备识别 | DMG 挂载不再被当成 USB（`hdiutil info -plist` 取挂载点，且放后台查询） |
| 转码 | 硬件编码首次失败自动回退软件编码并记录原因 |
| 交互 | 删除任务改为滑块确认；报告导出、清单复核移入后台并互斥 |
| 构建 | codesign 失败即中止；SDK/工具链自动探测；CLT 回退优先旧 SDK |
| 界面 | 全量按 bencho 令牌重构（见第 4 节）；去掉原生工具栏，顶栏与主界面同色 |

**未完成**：无本地化（0 处 `NSLocalizedString`）；无无障碍标注；无公证流水线；bencho 的 24 个界面音效未移植（Web Audio 无原生等价物，文件拷贝工具也不需要点击音）。

**仍存在的已知问题**

- **边缘｜多窗口 delegate 串台**：`AppDelegate` 单实例 `MainWindowCloseDelegate` 被多个候选窗口复用，`forwardee` 会被后一个窗口覆盖；当前「新建窗口」入口已移除，难触发。
- **边缘｜保留参数**：bencho 组件里有若干只为调用点稳定而保留的参数（如 `ToolbarActionLabel.tint`），不参与视觉。
- **文档｜截图缺失**：官网仍是 v1.0.1 时期的截图，未随改版更新。
- **验证盲区**：本次无法截屏（终端未获屏幕录制权限），界面观感未经像素级核验，仅通过编译、自检与代码走查确认。

## 6. 外部依赖与凭据

- SwiftPM 依赖：**无**。实际 import：SwiftUI / AppKit / AVFoundation / VideoToolbox / CryptoKit / CoreText / CoreGraphics / ImageIO / UniformTypeIdentifiers / Foundation。
- 外部可执行文件：`ffmpeg` / `ffprobe`，子进程调用，**不随包分发**。用户自装的 FFmpeg 可能含 GPL 组件，本项目自身不链接 libav*，故按 MIT 分发。
- 第三方设计来源：bencho（MIT, © 2026 Lorenzo Cabra）——只借用 `tokens.css` 的色值与组件规格，未复制其代码，README 已注明。
- 许可证：MIT（`LICENSE`）。
- 凭据：应用不保存任何服务账号；托管凭据在钥匙串/SSH 私钥，文档不记录口令。

## 7. 数据与配置在哪

- 任务与选项：`~/Library/Application Support/DataCopier/tasks.json`、`default-options.json`
- 报告：`~/Library/Application Support/DataCopier/reports/`
- 配置损坏留档：同目录 `*.corrupt-<时间戳>`
- 偏好：`UserDefaults`，域 `com.genge.datacopier`
- 清单：随任务输出到目标目录，`<任务名>.checksums.txt`

重置（先退出；用 `mv` 留备份）：

```bash
osascript -e 'quit app "数据拷贝"' 2>/dev/null
mv ~/Library/Application\ Support/DataCopier ~/Desktop/DataCopier-backup-$(date +%Y%m%d-%H%M)
defaults delete com.genge.datacopier
```

## 8. 维护手册

| 现象 | 排查步骤 | 日志位置 |
|---|---|---|
| 双击无反应 / 被 Gatekeeper 拦 | `codesign -dv dist/DataCopier.app` 看是否 `Signature=adhoc`；右键 → 打开；或 `xattr -dr com.apple.quarantine` | 系统「隐私与安全性」 |
| 构建报 `missing required module 'SwiftShims'` | `.build/ClangModuleCache` 里是搬迁前的绝对路径 → 把该目录移走后重编 | — |
| 顶栏比主界面亮一档 | 原生工具栏/标题栏叠了系统玻璃。已用 `titlebarAppearsTransparent` + 内容内动作区解决；若复发先查 `AppDelegate.applyWindowChrome` 是否被 SwiftUI 重置 | — |
| 构建报 SwiftUI 宏插件缺失 | 用的是 CLT 27.x SDK → 让脚本选 26.5，或装 Xcode | — |
| 转码页找不到 ffmpeg | `which -a ffmpeg ffprobe`；「设置 → 运行环境」指定；`FFmpegLocator.probe()` 有进程内缓存，改路径需重开窗口 | — |
| 关窗后进程残留 | 查 `MainWindowCloseDelegate` 是否挂上（窗口标题是单个空格，不能按标题匹配） | Console 过滤 DataCopier |
| 拷贝后校验失败 | 目标目录 `shasum -a 256 -c "<任务名>.checksums.txt"`；失败文件另存 `*.corrupt-*` | 详情页 + `reports/` |
| 任务列表变空 | 查 `tasks.json` 是否被改坏、同目录有无 `*.corrupt-*` | `~/Library/Application Support/DataCopier/` |

## 9. 复现与验证清单

```bash
cd ~/AiWork/SoftwareDevelopment/DataCopier

# 1. 版本与 bundle id
plutil -p dist/DataCopier.app/Contents/Info.plist | grep -E "ShortVersion|Identifier"
# 预期："1.1.0" / "com.genge.datacopier"

# 2. 自检
./Scripts/run_selfcheck.sh
# 预期：共 433 项检查，失败 0 项

# 3. 产物体积与架构
du -sh dist/DataCopier.app && lipo -archs dist/DataCopier.app/Contents/MacOS/DataCopier

# 4. DMG 校验
shasum -a 256 dist/DataCopier-v1.1.0-arm64.dmg dist/DataCopier-v1.1.0-x86_64.dmg

# 5. 源码规模
find Sources -name "*.swift" | wc -l

# 6. 启动冒烟
open dist/DataCopier.app
```

## 10. 下一步建议

1. **发布 v1.1.0**：打 tag → 建 Release → 上传双架构 DMG → 同步 `gh-pages` 的 `index.html`。README 已指向 v1.1.0，不发布就是死链。
2. **换官网截图**：首屏与功能图仍是旧 UI，改版后应重拍。
3. **补 v1.0.1 tag 的历史债**：v1.0.1 只有提交没有 tag。
4. **无障碍**：至少给主操作按钮与状态徽标补 `accessibilityLabel`。
5. **自检 `SOURCES` 自动化**：改为按目录枚举，避免新增 Engine 文件静默漏测。

## 11. 变更历史

| 日期 | 版本 | 改了什么 |
|---|---|---|
| 2026-09-12 | — | `734b726` Initial release |
| 2026-09-13 | v1.0.0 | `71edd2d` 媒体归档七档规则（tag `v1.0.0`）；`934640f`/`17f5a26`/`592c520` 打包脚本与双架构；`5a88281` 修 17 项缺陷，自检 362 → 414 |
| 2026-09-13 | v1.0.1 | `c802c99` 版本号 1.0.1 + DMG 脚本；`5d7ea2a` 官网跟进 |
| 2026-11-02 | — | 修复批次：路径逃逸、Format 跨线程、并发临时文件、来源去重、DMG 误判 USB、转码软回退、批量删除、后台导出（自检 414 → 433） |
| 2026-11-09 | v1.1.0 | 去掉原生工具栏与标题栏玻璃，动作入口移入内容（侧栏 + 详情头部），顶栏与主界面同色 |
| 2026-11-09 | v1.1.0 | 项目体检：修构建脚本 SDK 回退与 codesign 失败静默；`.gitignore` 收纳生成图与本地记忆；断言数同步为 433；按 bencho 令牌重构全部界面（新增 `DesignSystem/`）；版本升至 1.1.0 |
